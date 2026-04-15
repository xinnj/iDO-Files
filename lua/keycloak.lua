local http = require "resty.http"
local cjson = require "cjson"
local redis_conn = require "redis_conn"

local GROUPS_CACHE_TTL = tonumber(os.getenv("GROUPS_CACHE_TTL") or 300)

local ssl_verify = true
if os.getenv("OIDC_SSL_VERIFY") == "no" then
    ssl_verify = false
end

local function get_oidc_config(discovery_url)
    local httpc = http.new()
    local res, err = httpc:request_uri(discovery_url, {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json",
        },
        ssl_verify = ssl_verify
    })

    if not res then
        return nil, "failed to get OIDC config: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        return nil, "invalid status: " .. res.status .. ", body: " .. res.body
    end

    return cjson.decode(res.body)
end

local function get_admin_url(token_endpoint)
    -- Extract realm name from token endpoint
    -- Typical format: https://keycloak.example.com/auth/realms/{realm}/protocol/openid-connect/token
    local realm_start = token_endpoint:find("/realms/")
    if not realm_start then
        return nil, "invalid token endpoint format"
    end

    local realm_end = token_endpoint:find("/protocol", realm_start)
    if not realm_end then
        return nil, "invalid token endpoint format"
    end

    -- Extract base URL (everything before /realms/{realm})
    local base_url = token_endpoint:sub(1, realm_start - 1)
    return base_url .. "/admin/realms/" .. token_endpoint:sub(realm_start + 8, realm_end - 1)
end

local function get_keycloak_token(client_id, client_secret, token_endpoint)
    local httpc = http.new()
    local res, err = httpc:request_uri(token_endpoint, {
        method = "POST",
        body = "grant_type=client_credentials&client_id=" .. client_id .. "&client_secret=" .. client_secret,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        ssl_verify = ssl_verify
    })

    if not res then
        return nil, "failed to get token: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        return nil, "invalid status: " .. res.status .. ", body: " .. res.body
    end

    local token = cjson.decode(res.body)
    return token.access_token
end

local function get_user_groups(user_id)
    -- First try to get from Redis cache
    local red, _ = redis_conn.get_conn()
    if red then
        local cached_groups, _ = red:get("user_groups:" .. user_id)
        if cached_groups and cached_groups ~= ngx.null then
            redis_conn.close(red)
            return cached_groups
        end
    end

    -- Get OIDC discovery URL from environment
    local discovery_url = os.getenv("OIDC_DISCOVERY_URL")
    if not discovery_url then
        return nil, "OIDC_DISCOVERY_URL environment variable not set"
    end

    -- Get OIDC configuration
    local oidc_config, err = get_oidc_config(discovery_url)
    if not oidc_config then
        return nil, "failed to get OIDC config: " .. (err or "unknown error")
    end

    -- Get admin base URL from token endpoint
    local admin_url, err = get_admin_url(oidc_config.token_endpoint)
    if not admin_url then
        return nil, "failed to determine admin URL: " .. (err or "unknown error")
    end

    -- Get client credentials from environment
    local client_id = os.getenv("OIDC_CLIENT_ID")
    if not client_id then
        return nil, "OIDC_CLIENT_ID environment variable not set"
    end
    local client_secret = os.getenv("OIDC_CLIENT_SECRET")
    if not client_secret then
        return nil, "OIDC_CLIENT_SECRET environment variable not set"
    end

    -- Get access token
    local access_token, err = get_keycloak_token(client_id, client_secret, oidc_config.token_endpoint)
    if not access_token then
        return nil, "failed to get access token: " .. (err or "unknown error")
    end

    -- Make request to get user groups
    local httpc = http.new()
    local url = admin_url .. "/users/" .. user_id .. "/groups"

    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "application/json",
        },
        ssl_verify = ssl_verify
    })

    if not res then
        return nil, "failed to request: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        return nil, "invalid status: " .. res.status .. ", body: " .. res.body
    end

    local groupsTable = {}
    for _, group in ipairs(cjson.decode(res.body)) do
        table.insert(groupsTable, group.path)
    end
    local groups = table.concat(groupsTable, ",")

    -- Store in Redis cache if connection is available
    if red then
        local ok, err = red:setex("user_groups:" .. user_id, GROUPS_CACHE_TTL, groups)
        if not ok then
            ngx.log(ngx.ERR, "failed to cache user groups in Redis: ", err)
        end
    end

    redis_conn.close(red)
    return groups
end

local function get_username_from_userid(user_id)
    -- First try to get from Redis cache
    local red, _ = redis_conn.get_conn()
    if red then
        local cached_username, _ = red:get("username:" .. user_id)
        if cached_username and cached_username ~= ngx.null then
            redis_conn.close(red)
            return cached_username
        end
    end

    -- Get OIDC discovery URL from environment
    local discovery_url = os.getenv("OIDC_DISCOVERY_URL")
    if not discovery_url then
        return nil, "OIDC_DISCOVERY_URL environment variable not set"
    end

    -- Get OIDC configuration
    local oidc_config, err = get_oidc_config(discovery_url)
    if not oidc_config then
        return nil, "failed to get OIDC config: " .. (err or "unknown error")
    end

    -- Get admin base URL from token endpoint
    local admin_url, err = get_admin_url(oidc_config.token_endpoint)
    if not admin_url then
        return nil, "failed to determine admin URL: " .. (err or "unknown error")
    end

    -- Get client credentials from environment
    local client_id = os.getenv("OIDC_CLIENT_ID")
    if not client_id then
        return nil, "OIDC_CLIENT_ID environment variable not set"
    end
    local client_secret = os.getenv("OIDC_CLIENT_SECRET")
    if not client_secret then
        return nil, "OIDC_CLIENT_SECRET environment variable not set"
    end

    -- Get access token
    local access_token, err = get_keycloak_token(client_id, client_secret, oidc_config.token_endpoint)
    if not access_token then
        return nil, "failed to get access token: " .. (err or "unknown error")
    end

    -- Make request to get user info
    local httpc = http.new()
    local url = admin_url .. "/users/" .. user_id

    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "application/json",
        },
        ssl_verify = ssl_verify
    })

    if not res then
        return nil, "failed to request: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        return nil, "invalid status: " .. res.status .. ", body: " .. res.body
    end

    local user_info = cjson.decode(res.body)
    local username = user_info.username or user_id

    -- Store in Redis cache if connection is available
    if red then
        local ok, err = red:setex("username:" .. user_id, GROUPS_CACHE_TTL, username)
        if not ok then
            ngx.log(ngx.ERR, "failed to cache username in Redis: ", err)
        end
    end

    redis_conn.close(red)
    return username
end

-- Export functions
local _M = {
    get_user_groups = get_user_groups,
    get_username_from_userid = get_username_from_userid
}

return _M