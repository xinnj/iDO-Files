local http = require "resty.http"
local cjson = require "cjson"
local redis_conn = require "redis_conn"

local GROUPS_CACHE_TTL = tonumber(os.getenv("GROUPS_CACHE_TTL") or 300)

local ssl_verify = true
if os.getenv("OIDC_SSL_VERIFY") == "no" then
    ssl_verify = false
end

-- os.getenv returns "" for variables that are exported but unset, and in Lua
-- "" is truthy — so `if not value` does not catch that case.
local function getenv_nonempty(name)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return nil
    end
    return value
end

-- Percent-encode a value for an application/x-www-form-urlencoded body.
-- Needed because a client secret containing "&" would otherwise truncate the
-- request body and the token call would fail with an opaque error.
local function form_encode(value)
    return (tostring(value):gsub("[^%w%-%._~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
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
        body = "grant_type=client_credentials"
            .. "&client_id=" .. form_encode(client_id)
            .. "&client_secret=" .. form_encode(client_secret),
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

-- Discovery -> admin base URL -> client-credentials token.
-- Returns admin_url, access_token on success; nil, nil, err otherwise.
local function get_admin_context()
    local discovery_url = getenv_nonempty("OIDC_DISCOVERY_URL")
    if not discovery_url then
        return nil, nil, "OIDC_DISCOVERY_URL environment variable not set"
    end

    local client_id = getenv_nonempty("OIDC_CLIENT_ID")
    if not client_id then
        return nil, nil, "OIDC_CLIENT_ID environment variable not set"
    end

    local client_secret = getenv_nonempty("OIDC_CLIENT_SECRET")
    if not client_secret then
        return nil, nil, "OIDC_CLIENT_SECRET environment variable not set"
    end

    local oidc_config, err = get_oidc_config(discovery_url)
    if not oidc_config then
        return nil, nil, "failed to get OIDC config: " .. (err or "unknown error")
    end

    local admin_url, admin_err = get_admin_url(oidc_config.token_endpoint)
    if not admin_url then
        return nil, nil, "failed to determine admin URL: " .. (admin_err or "unknown error")
    end

    local access_token, token_err = get_keycloak_token(client_id, client_secret, oidc_config.token_endpoint)
    if not access_token then
        return nil, nil, "failed to get access token: " .. (token_err or "unknown error")
    end

    return admin_url, access_token, nil
end

local REALM_ROLES_CACHE_KEY = "realm_roles:all"

local function fetch_realm_roles()
    local admin_url, access_token, err = get_admin_context()
    if not admin_url then
        return nil, err
    end

    local httpc = http.new()
    local res, req_err = httpc:request_uri(admin_url .. "/roles", {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "application/json",
        },
        ssl_verify = ssl_verify
    })

    if not res then
        return nil, "failed to request: " .. (req_err or "unknown error")
    end

    -- Listing realm roles needs a permission the other Admin API calls do not
    -- (they only read one user), so a bare "403" here is almost always a client
    -- that was never granted it. Say so, rather than leaving an operator to
    -- decode a Keycloak status code.
    -- Phrased without a trailing full stop or bracketed status code: the page
    -- already wraps this in its own parentheses in the degraded-roles notice.
    if res.status == 403 then
        return nil, "Keycloak refused the request with 403 — the client's service account needs "
            .. "the 'view-realm' role from the realm-management client to list realm roles"
    end

    if res.status ~= 200 then
        return nil, "invalid status: " .. res.status .. ", body: " .. res.body
    end

    local roles = {}
    for _, role in ipairs(cjson.decode(res.body)) do
        if role.name then
            table.insert(roles, role.name)
        end
    end
    table.sort(roles)
    return roles
end

-- Realm role names, which is what the authorization rules key on.
-- Pass refresh=true to bypass the Redis cache.
-- Returns roles, source ("keycloak" | "cache") on success; nil, err otherwise.
local function get_realm_roles(refresh)
    local red = redis_conn.get_conn()

    if red and not refresh then
        local cached, _ = red:get(REALM_ROLES_CACHE_KEY)
        if cached and cached ~= ngx.null then
            local decoded = cjson.decode(cached)
            if type(decoded) == "table" then
                redis_conn.close(red)
                return decoded, "cache"
            end
        end
    end

    -- resty.http is not always usable (the E2E environment stubs it as an
    -- empty table), so the whole network path is guarded.
    local ok, roles, err = pcall(fetch_realm_roles)
    if not ok then
        if red then redis_conn.close(red) end
        return nil, tostring(roles)
    end
    if not roles then
        if red then redis_conn.close(red) end
        return nil, err
    end

    -- Only successful lookups are cached; a degraded result must not be
    -- pinned for the whole TTL.
    if red then
        local set_ok, set_err = red:setex(REALM_ROLES_CACHE_KEY, GROUPS_CACHE_TTL, cjson.encode(roles))
        if not set_ok then
            ngx.log(ngx.ERR, "failed to cache realm roles in Redis: ", set_err)
        end
        redis_conn.close(red)
    end

    return roles, "keycloak"
end

local function get_user_groups(user_id)
    -- First try to get from Redis cache
    local red, _ = redis_conn.get_conn()
    if red then
        local cached_groups, _ = red:get("user_roles:" .. user_id)
        if cached_groups and cached_groups ~= ngx.null then
            redis_conn.close(red)
            return cached_groups
        end
    end

    local admin_url, access_token, ctx_err = get_admin_context()
    if not admin_url then
        if red then redis_conn.close(red) end
        return nil, ctx_err
    end

    -- Make request to get user realm roles
    local httpc = http.new()
    local url = admin_url .. "/users/" .. user_id .. "/role-mappings/realm"

    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "application/json",
        },
        ssl_verify = ssl_verify
    })

    if not res then
        if red then redis_conn.close(red) end
        return nil, "failed to request: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        if red then redis_conn.close(red) end
        return nil, "invalid status: " .. res.status .. ", body: " .. res.body
    end

    local groupsTable = {}
    for _, role in ipairs(cjson.decode(res.body)) do
        -- Realm roles have flat names (no path/slash), matching the
        -- no-leading-slash format used throughout the auth system.
        table.insert(groupsTable, role.name)
    end
    local groups = table.concat(groupsTable, ",")

    -- Store in Redis cache if connection is available
    if red then
        local ok, err = red:setex("user_roles:" .. user_id, GROUPS_CACHE_TTL, groups)
        if not ok then
            ngx.log(ngx.ERR, "failed to cache user roles in Redis: ", err)
        end
        redis_conn.close(red)
    end

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

    local admin_url, access_token, ctx_err = get_admin_context()
    if not admin_url then
        if red then redis_conn.close(red) end
        return nil, ctx_err
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
        if red then redis_conn.close(red) end
        return nil, "failed to request: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        if red then redis_conn.close(red) end
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
        redis_conn.close(red)
    end

    return username
end

-- Export functions
local _M = {
    get_user_groups = get_user_groups,
    get_username_from_userid = get_username_from_userid,
    get_realm_roles = get_realm_roles
}

return _M