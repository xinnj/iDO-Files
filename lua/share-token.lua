local cjson = require "cjson.safe"
local redis_conn = require "redis_conn"
local random = require "random"
local resty_string = require "resty.string"
local auth = require "authorize"
local keycloak = require "keycloak"

local _M = {}

local function send_response(status, data)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(data))
    ngx.exit(status)
end

local function generate_token()
    local bytes = random.bytes(8)
    return resty_string.to_hex(bytes)
end

local function encode_key(str)
    return resty_string.to_hex(str)
end

function _M.generate()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Empty request body" })
    end

    local json_data, err = cjson.decode(body)
    if not json_data then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Invalid JSON format: " .. (err or "unknown error") })
    end

    local headers = ngx.req.get_headers()
    local userid = headers["X-USER"]
    local groups = headers["X-USER-GROUPS"]
    if not userid or userid == "" then
        return send_response(ngx.HTTP_UNAUTHORIZED, { message = "User not authenticated" })
    end

    if not json_data.path or type(json_data.path) ~= "string" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'path' string" })
    end

    if not json_data.exp or type(json_data.exp) ~= "number" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'exp' number" })
    end

    -- Validate expiration time (max 1 year = 525600 minutes)
    local max_exp_minutes = 525600
    if json_data.exp <= 0 or json_data.exp > max_exp_minutes then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Expiration time must be between 1 and " .. max_exp_minutes .. " minutes (1 year)" })
    end

    if not auth.checkAuthorize(groups, "POST", json_data.path) then
        return send_response(ngx.HTTP_FORBIDDEN, { message = "Write permission required to create share links" })
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local token = generate_token()
    -- Check for token conflicts and regenerate if necessary
    local max_attempts = 10
    local attempts = 0
    while attempts < max_attempts do
        local token_reverse_key = "share_token_reverse:" .. token
        local existing_token = red:get(token_reverse_key)
        if not existing_token or existing_token == ngx.null then
            break
        end
        token = generate_token()
        attempts = attempts + 1
    end
    
    if attempts >= max_attempts then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to generate unique token after multiple attempts" })
    end
    
    local exp_seconds = json_data.exp * 60
    local path = json_data.path
    -- Ensure path consistency by unescaping if needed
    path = ngx.unescape_uri(path)
    local encoded_path = encode_key(path)
    local share_key = "share_token:" .. userid .. ":" .. encoded_path
    local token_reverse_key = "share_token_reverse:" .. token
    
    -- Get existing links list
    local links_list, get_err = red:get(share_key)
    local links = {}
    if links_list and links_list ~= ngx.null then
        local decoded_list = cjson.decode(links_list)
        if type(decoded_list) == "table" then
            links = decoded_list
        end
    end
    
    -- Add new link to list
    local new_link = {
        token = token,
        created_at = ngx.time(),
        exp_seconds = exp_seconds
    }
    table.insert(links, new_link)
    
    -- Calculate the maximum expiration time among all links
    local max_exp = 0
    for i, link in ipairs(links) do
        if link.exp_seconds and link.exp_seconds > max_exp then
            max_exp = link.exp_seconds
        end
    end
    -- If no links have expiration time (shouldn't happen), use new link's expiration
    if max_exp == 0 then
        max_exp = exp_seconds
    end
    
    local links_json = cjson.encode(links)
    local ok, err = red:setex(share_key, max_exp, links_json)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to store token: " .. (err or "unknown error") })
    end

    local token_reverse_data = cjson.encode({
        token = token,
        userid = userid,
        path = json_data.path
    })
    ok, err = red:setex(token_reverse_key, exp_seconds, token_reverse_data)
    if not ok then
        red:del(share_key)
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to store reverse mapping: " .. (err or "unknown error") })
    end

    redis_conn.close(red)

    send_response(ngx.HTTP_OK, { token = token })
end

function _M.list()
    local headers = ngx.req.get_headers()
    local userid = headers["X-USER"]
    if not userid or userid == "" then
        return send_response(ngx.HTTP_UNAUTHORIZED, { message = "User not authenticated" })
    end

    local path = ngx.var.arg_path or ""
    if not path or path == "" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing 'path' parameter" })
    end

    path = ngx.unescape_uri(path)
    local encoded_path = encode_key(path)

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local share_key = "share_token:" .. userid .. ":" .. encoded_path
    local links_list, err = red:get(share_key)

    local links = {}
    if links_list and links_list ~= ngx.null then
        local decoded, decode_err = cjson.decode(links_list)
        if type(decoded) == "table" then
            links = decoded
            ngx.log(ngx.NOTICE, "Found " .. #links .. " share links for path: " .. path)
        else
            ngx.log(ngx.ERR, "Failed to decode links list: " .. (decode_err or "unknown error"))
        end
    else
        ngx.log(ngx.NOTICE, "No share links found for path: " .. path)
    end

    local result = {}
    local valid_links = {}
    local need_update = false
    local current_time = ngx.time()

    for i, link in ipairs(links) do
        local token_reverse_key = "share_token_reverse:" .. link.token
        local token_reverse_data, err = red:get(token_reverse_key)

        -- Check if token still exists in reverse mapping
        if token_reverse_data and token_reverse_data ~= ngx.null then
            local expire_timestamp = link.created_at + link.exp_seconds
            table.insert(result, {
                token = link.token,
                created_at = link.created_at,
                expires_at = expire_timestamp
            })
            table.insert(valid_links, link)
        else
            -- Token expired, mark for removal
            need_update = true
            ngx.log(ngx.NOTICE, "Token expired and will be removed from list: " .. link.token)
        end
    end

    -- Update the links list if expired tokens were found
    if need_update then
        local max_exp = 0
        for i, link in ipairs(valid_links) do
            if link.exp_seconds and link.exp_seconds > max_exp then
                max_exp = link.exp_seconds
            end
        end

        if #valid_links > 0 then
            local valid_links_json = cjson.encode(valid_links)
            red:setex(share_key, max_exp, valid_links_json)
            ngx.log(ngx.NOTICE, "Updated links list, removed " .. (#links - #valid_links) .. " expired tokens")
        else
            red:del(share_key)
            ngx.log(ngx.NOTICE, "Deleted empty links list")
        end
    end

    redis_conn.close(red)
    send_response(ngx.HTTP_OK, { links = result })
end

function _M.delete()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Empty request body" })
    end

    local json_data, err = cjson.decode(body)
    if not json_data then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Invalid JSON format: " .. (err or "unknown error") })
    end

    local token = json_data.token
    if not token or type(token) ~= "string" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'token' string" })
    end

    local headers = ngx.req.get_headers()
    local userid = headers["X-USER"]
    if not userid or userid == "" then
        return send_response(ngx.HTTP_UNAUTHORIZED, { message = "User not authenticated" })
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local token_reverse_key = "share_token_reverse:" .. token
    local token_reverse_data, err = red:get(token_reverse_key)

    if not token_reverse_data or token_reverse_data == ngx.null then
        redis_conn.close(red)
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Token not found or expired" })
    end

    local decoded_reverse = cjson.decode(token_reverse_data)
    if not decoded_reverse or not decoded_reverse.userid or decoded_reverse.userid ~= userid then
        redis_conn.close(red)
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Token not found or unauthorized" })
    end

    local path = decoded_reverse.path
    path = ngx.unescape_uri(path)
    local encoded_path = encode_key(path)
    local share_key = "share_token:" .. userid .. ":" .. encoded_path

    -- Get existing links list and remove the specified token
    local links_list, get_err = red:get(share_key)
    if links_list and links_list ~= ngx.null then
        local links = cjson.decode(links_list)
        if type(links) == "table" then
            local updated_links = {}
            local remaining_max_exp = 0
            for i, link in ipairs(links) do
                if link.token ~= token then
                    table.insert(updated_links, link)
                    if link.exp_seconds > remaining_max_exp then
                        remaining_max_exp = link.exp_seconds
                    end
                end
            end
            
            -- Update the links list in Redis
            if #updated_links > 0 then
                local updated_links_json = cjson.encode(updated_links)
                red:setex(share_key, remaining_max_exp, updated_links_json)
            else
                red:del(share_key)
            end
        end
    end

    -- Delete the reverse mapping
    red:del(token_reverse_key)

    redis_conn.close(red)

    send_response(ngx.HTTP_OK, { message = "Token deleted successfully" })
end

local function checkShareToken(token)
    if not token or token == "" then
        ngx.log(ngx.ERR, "Token missing from URI")
        ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end

    local red, err = redis_conn.get_conn()
    if not red then
        ngx.log(ngx.ERR, "Redis connection failed: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Direct lookup using reverse mapping key
    local token_reverse_key = "share_token_reverse:" .. token
    local token_data, _ = red:get(token_reverse_key)

    if not token_data or token_data == ngx.null then
        redis_conn.close(red)
        ngx.log(ngx.WARN, "Invalid token: ", token)
        ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end

    local decoded = cjson.decode(token_data)
    redis_conn.close(red)

    if not decoded or not decoded.path then
        ngx.log(ngx.ERR, "Invalid token data: ", token)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local mapped_path = decoded.path
    mapped_path = ngx.unescape_uri(mapped_path)

    local groups = keycloak.get_user_groups(decoded.userid)
    if not groups then
        ngx.log(ngx.WARN, "Failed to retrieve user groups")
        ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end
    if not auth.checkAuthorize(groups, "GET", mapped_path) then
        ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end

    return mapped_path
end

function _M.authorize()
    local uri = ngx.var.uri
    local token = uri:match("/([^/]+)/?$") or uri:match("^([^/]+)/?$")

    local mapped_path = checkShareToken(token)
    ngx.log(ngx.NOTICE, "Share token authorized successful: " .. mapped_path)

    -- Extract file name from path
    local file_name = mapped_path:match("/([^/]+)$") or mapped_path:match("^([^/]+)$")

    ngx.var.store_path = mapped_path
    ngx.var.file_name = file_name

    if file_name then
        if file_name:match("%.html?$") then
            -- Store token in nginx variable for later use in body filter
            ngx.var.share_token = token
        else
            ngx.var.content_disposition = "attachment; filename=\"" .. file_name .. "\""
        end

    end
end

function _M.authorizeGenTimeToken(token, path)
    local mapped_path = checkShareToken(token)

    local data_root = os.getenv("DATA_ROOT") or "/data"
    local fs_path = data_root .. mapped_path
    -- Read file content
    local file_content = ""
    local file, err = io.open(fs_path, "r")
    if file then
        file_content = file:read("*all")
        file:close()
        ngx.log(ngx.DEBUG, "Successfully read file content: " .. fs_path)

        local pattern = '<div[^>]*class="qrcode"[^>]*path="([^"]+)"'
        local qrcodePath = file_content:match(pattern)
        ngx.log(ngx.DEBUG, "qrcodePath from file: " .. qrcodePath)

        path = ngx.unescape_uri(path)
        ngx.log(ngx.DEBUG, "qrcodePath from uri: " .. path)

        if qrcodePath ~= path then
            ngx.log(ngx.WARN, "qrcodePath from file is different from uri")
            ngx.exit(ngx.HTTP_UNAUTHORIZED)
        end
        ngx.log(ngx.NOTICE, "GenTimeToken authorized by share token successful")
    else
        ngx.log(ngx.ERR, "Failed to open file " .. fs_path .. ": " .. (err or "unknown error"))
    end
end

function _M.body_filter()
    local token = ngx.var.share_token
    if not token or token == "" then
        return
    end

    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    local ctx = ngx.ctx
    if not ctx.buffered_body then
        ctx.buffered_body = {}
    end

    if chunk and #chunk > 0 then
        table.insert(ctx.buffered_body, chunk)
    end

    if not eof then
        ngx.arg[1] = nil
        return
    end

    local full_body = table.concat(ctx.buffered_body)
    local original_length = #full_body

    local new_body, _ = full_body:gsub('(<div class="qrcode"[^>]*)>', '%1 share-token="' .. token .. '">')

    -- Remove <a> tags
    new_body = new_body:gsub('<a[^>]*>.-</a>', '')

    -- Remove empty <p> tags (handle multi-line)
    new_body = new_body:gsub('<p>%s*</p>', '')

    -- Append HTML comments at the end to maintain the original body length
    local current_length = #new_body
    if current_length < original_length then
        local padding_length = original_length - current_length
        local comment = "\n<!--" .. string.rep("-", padding_length - 7) .. "-->"
        new_body = new_body:gsub('(</html>)', '%1' .. comment)
    end

    ngx.arg[1] = new_body

    ctx.buffered_body = nil
end

return _M
