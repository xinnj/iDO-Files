local cjson = require "cjson.safe"
local redis_conn = require "redis_conn"
local random = require "random"
local resty_string = require "resty.string"

local _M = {}

    local function send_response(status, data)
    ngx.status = status
    ngx.header.content_type = "application/json"
    local json_str = cjson.encode(data)
    -- Ensure empty table is encoded as array not object
    if data.tokens and type(data.tokens) == "table" and #data.tokens == 0 then
        json_str = string.gsub(json_str, '{"count":0,"tokens":{}}', '{"count":0,"tokens":[]}')
    end
    ngx.say(json_str)
    ngx.exit(status)
end

local function generate_token()
    local bytes = random.bytes(32)
    return resty_string.to_hex(bytes)
end

local function generate_token_id()
    local bytes = random.bytes(16)
    return "tid_" .. resty_string.to_hex(bytes)
end

function _M.verify(token)
    local red, err = redis_conn.get_conn()
    if not red then
        return false, "Failed to connect to Redis: " .. (err or "unknown error")
    end

    local token_key = "token:" .. token
    local token_data, err = red:get(token_key)
    redis_conn.close(red)

    if not token_data then
        return false, "Token not found or expired"
    end

    local decoded = cjson.decode(token_data)
    if not decoded then
        return false, "Invalid token data"
    end

    return true, decoded
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
    if not userid or userid == "" then
        return send_response(ngx.HTTP_UNAUTHORIZED, { message = "User not authenticated" })
    end

    if not json_data.exp or type(json_data.exp) ~= "number" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'exp' number" })
    end

    if not json_data.description or type(json_data.description) ~= "string" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'description' string" })
    end

    if #json_data.description > 100 then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Description too long (max 100 characters)" })
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local token = generate_token()
    local token_id = generate_token_id()
    local exp_seconds = json_data.exp * 60
    local token_key = "token:" .. token
    local token_id_key = "token_id:" .. token_id
    local user_tokens_key = "user_tokens:" .. userid

    local token_data = cjson.encode({
        userid = userid,
        description = json_data.description,
        created_at = ngx.time()
    })

    local ok, err = red:set(token_key, token_data)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to store token: " .. (err or "unknown error") })
    end

    ok, err = red:expire(token_key, exp_seconds)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to set token TTL: " .. (err or "unknown error") })
    end

    -- Store token_id -> token mapping (with same TTL)
    ok, err = red:set(token_id_key, token)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to store token_id mapping: " .. (err or "unknown error") })
    end

    ok, err = red:expire(token_id_key, exp_seconds)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to set token_id TTL: " .. (err or "unknown error") })
    end

    ok, err = red:zadd(user_tokens_key, ngx.time(), token_id)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to add token to user's token list: " .. (err or "unknown error") })
    end

    redis_conn.close(red)

    send_response(ngx.HTTP_OK, { token = token, token_id = token_id })
end

function _M.list()
    local headers = ngx.req.get_headers()
    local userid = headers["X-USER"]
    if not userid or userid == "" then
        return send_response(ngx.HTTP_UNAUTHORIZED, { message = "User not authenticated" })
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local user_tokens_key = "user_tokens:" .. userid
    local tokens, err = red:zrange(user_tokens_key, 0, -1)

    local token_list = {}
    local tokens_array = {}

    if tokens and tokens ~= ngx.null then
        if type(tokens) == "table" then
            tokens_array = tokens
        else
            tokens_array = {tokens}
        end
    end

    for i, token_id in ipairs(tokens_array) do
        local token_id_key = "token_id:" .. token_id
        local token, err = red:get(token_id_key)

        if token and token ~= ngx.null then
            local token_key = "token:" .. token
            local token_data, err = red:get(token_key)

            if token_data and token_data ~= ngx.null then
                local decoded = cjson.decode(token_data)
                if decoded then
                    -- Get TTL for this token and calculate absolute expiration time
                    local ttl, err = red:ttl(token_key)
                    local expires_at = nil
                    if ttl and ttl > 0 then
                        expires_at = ngx.time() + ttl
                    end

                    table.insert(token_list, {
                        token_id = token_id,
                        description = decoded.description,
                        created_at = decoded.created_at,
                        expires_at = expires_at
                    })
                end
            end
        end
    end

    redis_conn.close(red)
    send_response(ngx.HTTP_OK, { tokens = token_list, count = #token_list })
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

    local token_id = json_data.token_id

    if not token_id or type(token_id) ~= "string" then
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Missing or invalid 'token_id' string" })
    end

    local red, err = redis_conn.get_conn()
    if not red then
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to connect to Redis: " .. (err or "unknown error") })
    end

    local token_id_key = "token_id:" .. token_id
    local token, err = red:get(token_id_key)

    if not token or token == ngx.null then
        redis_conn.close(red)
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Token not found or expired" })
    end

    local token_key = "token:" .. token
    local token_data, err = red:get(token_key)

    if not token_data then
        redis_conn.close(red)
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Token not found or expired" })
    end

    local decoded = cjson.decode(token_data)
    if not decoded or not decoded.userid then
        redis_conn.close(red)
        return send_response(ngx.HTTP_BAD_REQUEST, { message = "Invalid token data" })
    end

    local user_tokens_key = "user_tokens:" .. decoded.userid
    red:zrem(user_tokens_key, token_id)

    local ok, err = red:del(token_key)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to delete token: " .. (err or "unknown error") })
    end

    ok, err = red:del(token_id_key)
    if not ok then
        redis_conn.close(red)
        return send_response(ngx.HTTP_INTERNAL_SERVER_ERROR, { message = "Failed to delete token_id mapping: " .. (err or "unknown error") })
    end

    redis_conn.close(red)

    send_response(ngx.HTTP_OK, { message = "Token deleted successfully" })
end

return _M
