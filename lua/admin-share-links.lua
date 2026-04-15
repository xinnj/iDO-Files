local cjson = require "cjson.safe"
local redis_conn = require "redis_conn"
local keycloak = require "keycloak"

local _M = {}

local function send_response(status, data)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(data))
    ngx.exit(status)
end

local function has_permission()
    local ADMIN_GROUP = os.getenv("ADMIN_GROUP")
    if not ADMIN_GROUP then
        ngx.log(ngx.ERR, "ADMIN_GROUP environment variable not set")
        return false
    end

    local groups = ngx.req.get_headers()["X-USER-GROUPS"]
    if not groups then
        ngx.log(ngx.WARN, "No group header provided")
        return false
    end

    for group in string.gmatch(groups, "([^,]+)") do
        group = group:gsub("%s+", "")
        if group == ADMIN_GROUP then
            return true
        end
    end

    ngx.log(ngx.WARN, "User does not have required admin permissions")
    return false
end

local function encode_key(str)
    local resty_string = require "resty.string"
    return resty_string.to_hex(str)
end

-- List all share links for admin
function _M.list_all()
    if not has_permission() then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local all_links = {}
    
    -- Use KEYS command instead of SCAN to avoid hanging issues
    local keys, err = red:keys("share_token_reverse:*")
    if not keys then
        ngx.log(ngx.ERR, "Redis KEYS command failed: ", err)
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to get Redis keys: " .. (err or "unknown error") })
    end

    ngx.log(ngx.NOTICE, "Found ", #keys, " share_token_reverse keys")

    -- Process keys in batches to avoid timeout
    local batch_size = 50
    for i = 1, #keys, batch_size do
        local batch_end = math.min(i + batch_size - 1, #keys)
        
        for j = i, batch_end do
            local token_reverse_key = keys[j]
            local token = token_reverse_key:match("share_token_reverse:(.+)")
            
            if token then
                local token_reverse_data, err = red:get(token_reverse_key)
                if token_reverse_data and token_reverse_data ~= ngx.null then
                    local decoded, decode_err = cjson.decode(token_reverse_data)
                    if decoded and type(decoded) == "table" and decoded.userid and decoded.path then
                        -- Extract expiration info from the forward mapping
                        local path = decoded.path
                        path = ngx.unescape_uri(path)
                        local encoded_path = encode_key(path)
                        local share_key = "share_token:" .. decoded.userid .. ":" .. encoded_path
                        
                        local links_list, get_err = red:get(share_key)
                        if links_list and links_list ~= ngx.null then
                            local links, links_err = cjson.decode(links_list)
                        if links and type(links) == "table" then
                            for _, link in ipairs(links) do
                                if link.token == token then
                                    local expires_at = link.created_at + link.exp_seconds
                                    -- Get username from userid
                                    local username, err = keycloak.get_username_from_userid(decoded.userid)
                                    if not username then
                                        username = decoded.userid  -- Fallback to userid if username retrieval fails
                                        ngx.log(ngx.WARN, "Failed to get username for user ", decoded.userid, ": ", err)
                                    end
                                    
                                    table.insert(all_links, {
                                        token = token,
                                        userid = username,
                                        path = path,
                                        created_at = link.created_at,
                                        expires_at = expires_at
                                    })
                                    break
                                end
                            end
                        end
                        else
                            -- Token exists in reverse mapping but not in forward mapping (expired)
                            ngx.log(ngx.NOTICE, "Token expired (forward mapping not found): ", token)
                        end
                    else
                        ngx.log(ngx.WARN, "Invalid token_reverse_data for key: ", token_reverse_key)
                    end
                end
            end
        end
        
        -- Small delay between batches to avoid overwhelming Redis
        if batch_end < #keys then
            ngx.sleep(0.01) -- 10ms delay
        end
    end

    -- Sort by expires_at (newest first)
    table.sort(all_links, function(a, b)
        return a.expires_at > b.expires_at
    end)

    ngx.log(ngx.NOTICE, "Successfully retrieved ", #all_links, " active share links")

    redis_conn.close(red)
    send_response(ngx.HTTP_OK, { links = all_links })
end

-- Delete multiple share links for admin
function _M.delete_multiple()
    if not has_permission() then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Empty request body" })
    end

    local json_data, err = cjson.decode(body)
    if not json_data then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Invalid JSON format: " .. (err or "unknown error") })
    end

    local tokens = json_data.tokens
    if not tokens or type(tokens) ~= "table" or #tokens == 0 then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'tokens' array" })
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local deleted_count = 0
    local failed_tokens = {}

    for _, token in ipairs(tokens) do
        if type(token) == "string" and token ~= "" then
            local token_reverse_key = "share_token_reverse:" .. token
            local token_reverse_data, err = red:get(token_reverse_key)

            if token_reverse_data and token_reverse_data ~= ngx.null then
                local decoded = cjson.decode(token_reverse_data)
                if decoded and decoded.userid and decoded.path then
                    local path = ngx.unescape_uri(decoded.path)
                    local encoded_path = encode_key(path)
                    local share_key = "share_token:" .. decoded.userid .. ":" .. encoded_path

                    -- Get existing links list and remove the specified token
                    local links_list, get_err = red:get(share_key)
                    if links_list and links_list ~= ngx.null then
                        local links = cjson.decode(links_list)
                        if type(links) == "table" then
                            local updated_links = {}
                            local remaining_max_exp = 0
                            local token_found = false

                            for i, link in ipairs(links) do
                                if link.token ~= token then
                                    table.insert(updated_links, link)
                                    if link.exp_seconds > remaining_max_exp then
                                        remaining_max_exp = link.exp_seconds
                                    end
                                else
                                    token_found = true
                                end
                            end

                            if token_found then
                                -- Update the links list in Redis
                                if #updated_links > 0 then
                                    local updated_links_json = cjson.encode(updated_links)
                                    red:setex(share_key, remaining_max_exp, updated_links_json)
                                else
                                    red:del(share_key)
                                end
                            end
                        end
                    end

                    -- Delete the reverse mapping
                    red:del(token_reverse_key)
                    deleted_count = deleted_count + 1
                end
            else
                table.insert(failed_tokens, token)
            end
        end
    end

    redis_conn.close(red)

    local message = deleted_count .. " share link(s) deleted successfully"
    if #failed_tokens > 0 then
        message = message .. ". " .. #failed_tokens .. " token(s) not found or already expired."
    end

    send_response(ngx.HTTP_OK, { message = message, deleted_count = deleted_count, failed_tokens = failed_tokens })
end

-- Main request handler
local function handle_request()
    local method = ngx.req.get_method()
    if method == "GET" then
        _M.list_all()
    elseif method == "DELETE" then
        _M.delete_multiple()
    else
        ngx.log(ngx.ERR, "Unsupported method: ", method)
        ngx.exit(ngx.HTTP_METHOD_NOT_ALLOWED)
    end
end

pcall(handle_request)

return _M
