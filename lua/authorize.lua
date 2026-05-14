local redis_conn = require "redis_conn"
local cjson = require "cjson.safe"
local oidc = require "oidc"
local keycloak = require "keycloak"
local access_token = require "access-token"

local config_path = (os.getenv("DATA_ROOT") or "/data") .. "/config/auth_config.json"
local redis_key_prefix = "nginx_auth"

-- Simplified operation mapping
local allow_operations = {
    read = { GET = true, HEAD = true, OPTIONS = true },
    all = { GET = true, HEAD = true, OPTIONS = true, POST = true, PUT = true, PATCH = true, DELETE = true }
}

local deny_operations = {
    write = { POST = true, PUT = true, PATCH = true, DELETE = true },
    all = { GET = true, HEAD = true, OPTIONS = true, POST = true, PUT = true, PATCH = true, DELETE = true }
}

local shared_dict = ngx.shared["auth_cache"]

local _M = {}

-- Check if OIDC is properly configured when auth is required
local function is_oidc_configured()
    local auth_required = string.lower(os.getenv("AUTH_REQUIRED") or "") == "true"
    if not auth_required then
        return true  -- Auth not required, no OIDC needed
    end

    local client_id = os.getenv("OIDC_CLIENT_ID") or ""
    local client_secret = os.getenv("OIDC_CLIENT_SECRET") or ""
    local discovery_url = os.getenv("OIDC_DISCOVERY_URL") or ""

    return client_id ~= "" and client_secret ~= "" and discovery_url ~= ""
end

-- Serve the OIDC setup instruction page
local function serve_oidc_setup_page()
    local url_prefix = ngx.var.url_prefix or ""
    local logo_text = os.getenv("LOGO_TEXT") or "My Files"

    local html_path = (os.getenv("DATA_ROOT") or "/data") .. url_prefix .. "fileserver/oidc-setup.html"
    local file, err = io.open(html_path, "r")
    if not file then
        ngx.log(ngx.ERR, "Failed to open OIDC setup page: ", err)
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("OIDC is not configured. Please set OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, and OIDC_DISCOVERY_URL environment variables.")
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end

    local html = file:read("*a")
    file:close()

    -- Replace logo text placeholder
    html = html:gsub('id="logoText">My Files', 'id="logoText">' .. logo_text)

    ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say(html)
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

local function read_config()
    local file, open_err = io.open(config_path, "r")
    if not file then
        ngx.log(ngx.ERR, "Failed to open config file: ", open_err)
        return nil, open_err
    end

    local content = file:read("*a")
    file:close()

    local config, json_err = cjson.decode(content)
    if not config then
        ngx.log(ngx.ERR, "JSON decode error: ", json_err or "unknown error")
        return nil, json_err
    end

    for group, rules in pairs(config.rules) do
        if type(rules) ~= "table" or type(rules.allow) ~= "table" or type(rules.deny) ~= "table" then
            ngx.log(ngx.ERR, "Invalid config structure for group: ", group)
            return nil, "invalid config structure"
        end
    end

    return config.rules, nil
end

function _M.save_config_to_redis()
    local config, err = read_config()
    if not config then
        ngx.log(ngx.ERR, "Failed to load auth config: ", err)
        return false, err
    end

    local red, conn_err = redis_conn.get_conn()
    if not red then
        return false, conn_err
    end

    local existing_keys, scan_err = red:keys(redis_key_prefix .. ":*")
    if not existing_keys then
        redis_conn.close(red)
        return false, "Failed to scan existing keys: " .. (scan_err or "unknown error")
    end

    local keys_to_keep = {}
    for group, _ in pairs(config) do
        keys_to_keep[redis_key_prefix .. ":" .. group .. ":allow"] = true
        keys_to_keep[redis_key_prefix .. ":" .. group .. ":deny"] = true
    end

    local keys_to_delete = {}
    for _, key in ipairs(existing_keys) do
        if not keys_to_keep[key] then
            table.insert(keys_to_delete, key)
        end
    end

    red:init_pipeline()

    if #keys_to_delete > 0 then
        red:del(unpack(keys_to_delete))
    end

    for group, rules in pairs(config) do
        local allow_key = redis_key_prefix .. ":" .. group .. ":allow"
        local deny_key = redis_key_prefix .. ":" .. group .. ":deny"

        red:del(allow_key)
        red:del(deny_key)

        if #rules.allow > 0 then
            red:sadd(allow_key, unpack(rules.allow))
        end

        if #rules.deny > 0 then
            red:sadd(deny_key, unpack(rules.deny))
        end
    end

    local results, commit_err = red:commit_pipeline()
    redis_conn.close(red)
    if not results then
        ngx.log(ngx.ERR, "Redis pipeline failed: ", commit_err)
        return false, commit_err
    end

    if not shared_dict then
        ngx.log(ngx.ERR, "Shared dictionary not initialized")
        return false
    end
    shared_dict:set("initialized", true)

    ngx.log(ngx.NOTICE, "Configuration saved to Redis")
    return true, nil
end

local function load_config()
    if not shared_dict then
        ngx.log(ngx.ERR, "Shared dictionary not initialized")
        return false
    end

    if not shared_dict:get("initialized") then
        ngx.log(ngx.NOTICE, "Loading initial configuration from file")
        local ok, err = _M.save_config_to_redis()
        if not ok then
            ngx.log(ngx.ERR, "Failed to load initial config: ", err)
            return false
        end
    end

    return true
end

local function starts_with(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

local function check_allow_permission(rule, method, uri)
    local operation_part, url_part = string.match(rule, "^([^:]+):(.+)$")
    if not operation_part or not url_part then
        return false
    end

    -- Check if the URI matches the path pattern
    if not starts_with(uri, url_part) then
        return false
    end

    -- Check if the method is allowed by the operation
    if operation_part == "all" then
        return allow_operations.all[method] or false
    elseif operation_part == "read" then
        return allow_operations.read[method] or false
    end

    return false
end

local function check_deny_permission(rule, method, uri)
    local operation_part, url_part = string.match(rule, "^([^:]+):(.+)$")
    if not operation_part or not url_part then
        return false
    end

    -- Check if the URI matches the path pattern
    if not starts_with(uri, url_part) then
        return false
    end

    -- Check if the method is denied by the operation
    if operation_part == "all" then
        return deny_operations.all[method] or false
    elseif operation_part == "write" then
        return deny_operations.write[method] or false
    end

    return false
end

local function verify_access_token(token)
    local ok, data = access_token.verify(token)
    if not ok then
        return false, data
    end

    if not data.userid or type(data.userid) ~= "string" then
        return false, "Invalid userid in token"
    end

    local groups = keycloak.get_user_groups(data.userid)
    if not groups then
        return false, "Failed to retrieve user groups"
    end

    return true, groups
end

function _M.checkAuthorize(groups, method, uri)
    if not load_config() then
        ngx.log(ngx.ERR, "Configuration not loaded, denying access")
        return false
    end

    local valid_groups = {}
    for group in string.gmatch(groups, "[^,]+") do
        group = group:gsub("%s+", "")
        if group:sub(1, 1) == "/" then
            table.insert(valid_groups, group)
        end
    end

    if #valid_groups == 0 then
        table.insert(valid_groups, '/.default')
    end

    local red, err = redis_conn.get_conn()
    if not red then
        ngx.log(ngx.ERR, "Redis client creation failed: ", err)
        return false
    end

    local checkResult = false
    local checkMessage = ""
    for _, group in ipairs(valid_groups) do
        -- First check deny rules
        local deny_key = redis_key_prefix .. ":" .. group .. ":deny"
        local deny_rules, deny_err = red:smembers(deny_key)
        if deny_err then
            ngx.log(ngx.ERR, "Redis smembers(deny) error: ", deny_err)
        elseif deny_rules then
            for _, rule in ipairs(deny_rules) do
                if rule ~= ngx.null and rule ~= "" then
                    if check_deny_permission(rule, method, uri) then
                        checkMessage = string.format(
                            "DENIED by group '%s' rule '%s' for %s %s",
                            group, rule, method, uri)
                        checkResult = false
                        goto checkFinsh
                    end
                end
            end
        end

        -- Then check allow rules
        local allow_key = redis_key_prefix .. ":" .. group .. ":allow"
        local allow_rules, allow_err = red:smembers(allow_key)
        if allow_err then
            ngx.log(ngx.ERR, "Redis smembers(allow) error: ", allow_err)
        elseif allow_rules then
            for _, rule in ipairs(allow_rules) do
                if rule ~= ngx.null and rule ~= "" then
                    if check_allow_permission(rule, method, uri) then
                        checkMessage = string.format(
                            "ALLOWED by group '%s' rule '%s' for %s %s",
                            group, rule, method, uri)
                        checkResult = true
                    end
                end
            end
        end
    end

    ::checkFinsh::

    redis_conn.close(red)
    if checkMessage == "" then
        local checked_groups = table.concat(valid_groups, ",")
        checkMessage = string.format(
            "DENIED for %s %s. Groups checked: %s",
            method, uri, checked_groups)
    end
    ngx.log(ngx.NOTICE, checkMessage)
    return checkResult
end

function _M.authorize(method, uri)
    local auth_required = string.lower(os.getenv("AUTH_REQUIRED") or "") == "true"
    if not auth_required then
        return true
    end

    -- Check OIDC configuration before attempting authentication
    if not is_oidc_configured() then
        serve_oidc_setup_page()
        return false
    end

    if not method then
        method = ngx.req.get_method()
    end
    if not uri then
        uri = ngx.var.uri
    end

    local headers = ngx.req.get_headers()
    local auth_header = headers["authorization"] or headers["Authorization"]
    local groups

    if auth_header then
        local token = string.sub(auth_header, 8) -- Remove "Bearer " prefix

        if not token then
            ngx.log(ngx.ERR, "No authorization token provided")
            return false
        end

        local is_valid, groups_token = verify_access_token(token)

        if not is_valid then
            ngx.log(ngx.ERR, "Token verification failed: " .. groups_token)
            return false
        end

        groups = groups_token
    else
        oidc.authenticate(false)
        groups = ngx.req.get_headers()["X-USER-GROUPS"]
    end

    if not groups then
        groups = ""
    end
    return _M.checkAuthorize(groups, method, uri)
end

return _M
