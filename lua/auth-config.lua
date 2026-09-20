local cjson = require "cjson.safe"
local auth = require "authorize"
local dir_listing = require "dir-listing"

-- Config file path
local config_file = (os.getenv("DATA_ROOT") or "/data") .. "/config/auth_config.json"

-- Header containing user groups
local groups_header = "X-USER-GROUPS"

local ADMIN_GROUP = os.getenv("ADMIN_GROUP")

-- Route prefix, matched anywhere in the URI so a URL_PREFIX deployment works.
local API_PREFIX = "fileserver/auth-config"

-- The operation vocabulary, mirroring the method tables in authorize.lua.
-- Allow has no "write" and deny has no "read": the matcher returns false for
-- those, so a rule using one would silently never match anything. Rejecting
-- them here turns a silent misconfiguration into a visible error.
local ALLOW_OPERATIONS = { read = true, all = true }
local DENY_OPERATIONS = { write = true, all = true }

-- Permission check function
local function has_permission(groups_header_value)
    if not groups_header_value then
        ngx.log(ngx.WARN, "No group header provided")
        return false
    end

    for group in string.gmatch(groups_header_value, "([^,]+)") do
        group = group:gsub("%s+", "")
        if group == ADMIN_GROUP then
            return true
        end
    end

    ngx.log(ngx.WARN, "User does not have required permissions")
    return false
end

-- Read file safely
local function read_file(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, "Could not open file: " .. (err or "unknown error")
    end

    local content = file:read("*a")
    file:close()
    return content, nil
end

-- Write content to <path>.tmp, leaving the real file untouched. The caller
-- renames it into place once every other step has succeeded.
local function stage_file(path, content)
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "w")
    if not file then
        return false, "Could not create temporary file: " .. (err or "unknown error")
    end

    local ok, write_err = file:write(content)
    if not ok then
        file:close()
        return false, "Could not write to file: " .. (write_err or "unknown error")
    end

    file:flush()

    local closed, close_err = file:close()
    if not closed then
        return false, "Failed to close file: " .. (close_err or "unknown error")
    end

    return true, nil
end

local function send_json(payload)
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(payload))
end

-- Returns a copy of config ready to encode: cjson renders an empty Lua table as
-- {}, so a round-trip through decode/encode turned a stored `"deny": []` into
-- `"deny": {}`, and the client reads these as arrays.
--
-- The sentinel is a lightuserdata with no length, so it must never reach other
-- Lua code — this returns a shallow copy and leaves the original alone, because
-- the rule lists are also handed to authorize.save_config_to_redis().
local function for_encoding(config)
    if type(config) ~= "table" or type(config.rules) ~= "table" then
        return config
    end

    local copy = {}
    for key, value in pairs(config) do
        copy[key] = value
    end

    copy.rules = {}
    for group, rules in pairs(config.rules) do
        if type(rules) == "table" then
            local encoded_rules = { allow = rules.allow, deny = rules.deny }
            for _, key in ipairs({ "allow", "deny" }) do
                if type(rules[key]) == "table" and #rules[key] == 0 then
                    encoded_rules[key] = cjson.empty_array
                end
            end
            copy.rules[group] = encoded_rules
        else
            copy.rules[group] = rules
        end
    end

    return copy
end

-- Errors carry a JSON body so the page can show the server's own wording.
-- An empty body made every failure read as "Server returned 400".
local function send_error(status, message)
    local payload = cjson.encode({ error = message }) or '{"error":"unknown error"}'
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(payload)
    return ngx.exit(status)
end

-- Get current version of config file
local function get_current_version()
    local content, err = read_file(config_file)
    if not content then
        return nil, err
    end

    -- cjson.safe.decode reports failure by returning nil, it does not raise, so
    -- pcall here would never catch a malformed file.
    local config, decode_err = cjson.decode(content)
    if type(config) ~= "table" then
        return nil, "Invalid JSON in config file: " .. (decode_err or "not an object")
    end

    return config.version or 1, nil
end

local function validate_rule(rule, operations, allowed_names, group, list_name, index)
    if type(rule) ~= "string" then
        return false, string.format(
            "Invalid rule in %s list for role '%s' at position %d: expected a string",
            list_name, group, index)
    end

    local operation, path = rule:match("^([^:]+):(.+)$")
    if not operation then
        return false, string.format(
            "Invalid rule '%s' in %s list for role '%s' at position %d: expected <operation>:/<path>",
            rule, list_name, group, index)
    end

    if not operations[operation] then
        return false, string.format(
            "Invalid %s operation '%s' for role '%s' at position %d (allowed: %s)",
            list_name, operation, group, index, allowed_names)
    end

    if path == "/" then
        -- A bare root path would match every request URI, since rules are
        -- matched by plain prefix.
        return false, string.format(
            "Invalid %s path '/' for role '%s' at position %d: a root rule would match every URL",
            list_name, group, index)
    end

    if path:sub(1, 1) ~= "/" then
        return false, string.format(
            "Invalid %s path '%s' for role '%s' at position %d: must start with '/'",
            list_name, path, group, index)
    end

    if path:find("[%c]") then
        return false, string.format(
            "Invalid %s path for role '%s' at position %d: control characters are not allowed",
            list_name, group, index)
    end

    return true, nil
end

-- Validate configuration structure
local function validate_config(config)
    if type(config.rules) ~= "table" then
        return false, "Config must be a JSON object"
    end

    for group, rules in pairs(config.rules) do
        if type(group) ~= "string" or group == "" then
            return false, "Group keys must be non-empty strings"
        end

        if type(rules) ~= "table" then
            return false, "Invalid rule set for group " .. group
        end

        if not rules.allow or type(rules.allow) ~= "table" then
            return false, "Missing allow rules for group " .. group
        end

        if not rules.deny or type(rules.deny) ~= "table" then
            return false, "Missing deny rules for group " .. group
        end

        for index, rule in ipairs(rules.allow) do
            local ok, err = validate_rule(rule, ALLOW_OPERATIONS, "read, all", group, "allow", index)
            if not ok then
                return false, err
            end
        end

        for index, rule in ipairs(rules.deny) do
            local ok, err = validate_rule(rule, DENY_OPERATIONS, "write, all", group, "deny", index)
            if not ok then
                return false, err
            end
        end
    end

    return true, nil
end

-- Handler for GET requests (read config)
local function handle_get()
    ngx.header["Content-Type"] = "application/json"

    local content, err = read_file(config_file)
    if not content then
        ngx.log(ngx.ERR, "Failed to read config file: ", err)
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to read the configuration: " .. err)
    end

    local config, decode_err = cjson.decode(content)
    if type(config) ~= "table" then
        ngx.log(ngx.ERR, "Invalid JSON in config file: ", decode_err)
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR, "The configuration file is not valid JSON")
    end

    ngx.say(cjson.encode(for_encoding(config)))
end

-- Handler for POST requests (save config with version check)
local function handle_post()
    ngx.header["Content-Type"] = "application/json"
    ngx.req.read_body()
    local post_data = ngx.req.get_body_data()

    if not post_data then
        ngx.log(ngx.ERR, "No POST data received")
        return send_error(ngx.HTTP_BAD_REQUEST, "No request body received")
    end

    local new_config, decode_err = cjson.decode(post_data)
    if type(new_config) ~= "table" then
        ngx.log(ngx.ERR, "Invalid JSON in POST data: ", decode_err)
        return send_error(ngx.HTTP_BAD_REQUEST, "Request body is not valid JSON")
    end

    -- Get expected version from post_data
    if new_config.version == nil then
        ngx.log(ngx.ERR, "No version provided in POST data")
        return send_error(ngx.HTTP_BAD_REQUEST, "No version provided")
    end

    local expected_version = tonumber(new_config.version)
    if not expected_version then
        ngx.log(ngx.ERR, "Invalid version format in POST data")
        return send_error(ngx.HTTP_BAD_REQUEST, "Invalid version format")
    end

    local current_version, err = get_current_version()
    if not current_version then
        ngx.log(ngx.ERR, "Failed to get current version: ", err)
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to read the current configuration: " .. err)
    end

    if expected_version ~= current_version then
        ngx.log(ngx.ERR, "Version conflict: expected ", expected_version, ", got ", current_version)
        return send_error(ngx.HTTP_CONFLICT,
            "The configuration was modified by another user. Reload to see the latest version.")
    end

    local valid, validation_err = validate_config(new_config)
    if not valid then
        ngx.log(ngx.ERR, "Invalid configuration: ", validation_err)
        return send_error(ngx.HTTP_BAD_REQUEST, validation_err)
    end

    new_config.version = current_version + 1
    local encoded = cjson.encode(for_encoding(new_config))
    if not encoded then
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to serialise the configuration")
    end

    -- Two-phase save. Runtime authorization reads Redis, not the file, so
    -- writing the file first and failing afterwards would leave the rules the
    -- admin just saved silently unenforced. Stage the file, apply to Redis, and
    -- only then swap the file in — nothing changes anywhere unless both succeed.
    local staged, stage_err = stage_file(config_file, encoded)
    if not staged then
        ngx.log(ngx.ERR, "Failed to stage config file: ", stage_err)
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR, "Failed to write the configuration: " .. stage_err)
    end

    local synced, sync_err = auth.save_config_to_redis(new_config.rules)
    if not synced then
        os.remove(config_file .. ".tmp")
        ngx.log(ngx.ERR, "Failed to save config to Redis: ", sync_err)
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR,
            "Failed to apply the configuration: " .. (sync_err or "unknown error")
            .. ". Nothing was changed.")
    end

    local replaced, rename_err = os.rename(config_file .. ".tmp", config_file)
    if not replaced then
        ngx.log(ngx.ERR, "Failed to replace config file: ", rename_err)
        return send_error(ngx.HTTP_INTERNAL_SERVER_ERROR,
            "Failed to replace the configuration file: " .. (rename_err or "unknown error"))
    end

    ngx.say(encoded)
end

-- URIs like /<prefix>fileserver/auth-configuration also match the nginx
-- location regex, so route on the exact sub-path.
local function get_sub_path()
    local uri = ngx.var.uri or ""
    local pos = uri:find(API_PREFIX, 1, true)
    if not pos then
        return nil
    end
    local sub = uri:sub(pos + #API_PREFIX)
    sub = sub:gsub("^/+", ""):gsub("/+$", "")
    return sub
end

local function respond_roles(roles, source, err)
    -- cjson encodes an empty Lua table as {} — the page needs an array.
    if #roles == 0 then
        roles = cjson.empty_array
    end

    send_json({
        roles = roles,
        source = source,
        degraded = (source == "unavailable"),
        error = err,
        admin_group = ADMIN_GROUP,
    })
end

-- GET /fileserver/auth-config/roles
-- Always 200: the page degrades to config-derived roles rather than erroring.
local function handle_get_roles()
    local args = ngx.req.get_uri_args()
    local refresh = args["refresh"] == "1" or args["refresh"] == "true"

    -- Lazy require: keycloak pulls in resty.http, and the core config
    -- endpoints must not depend on that being available.
    local loaded, keycloak = pcall(require, "keycloak")
    if not loaded or type(keycloak) ~= "table" or type(keycloak.get_realm_roles) ~= "function" then
        return respond_roles({}, "unavailable", "Keycloak integration is unavailable")
    end

    local roles, source_or_err = keycloak.get_realm_roles(refresh)
    if not roles then
        return respond_roles({}, "unavailable", source_or_err)
    end

    respond_roles(roles, source_or_err, nil)
end

-- GET /fileserver/auth-config/dirs?path=<uri path>
-- Entries carry the ready-to-use rule path, including the URL prefix, so the
-- client never reconstructs one.
local function handle_get_dirs()
    local args = ngx.req.get_uri_args()
    local path = args["path"]

    if type(path) ~= "string" or path == "" then
        ngx.log(ngx.ERR, "Missing 'path' parameter")
        return send_error(ngx.HTTP_BAD_REQUEST, "Missing or invalid 'path' parameter")
    end

    -- ngx.req.get_uri_args percent-decodes, so %2e%2e arrives here as "..".
    if path:find("%.%.") then
        ngx.log(ngx.ERR, "Path traversal attempt: ", path)
        return send_error(ngx.HTTP_BAD_REQUEST, "Path traversal is not allowed")
    end

    if path:find("[%c]") then
        ngx.log(ngx.ERR, "Control character in path")
        return send_error(ngx.HTTP_BAD_REQUEST, "Invalid characters in path")
    end

    local url_prefix = ngx.var.url_prefix or "/"
    if url_prefix:sub(1, 1) ~= "/" then
        url_prefix = "/" .. url_prefix
    end
    if url_prefix:sub(-1) ~= "/" then
        url_prefix = url_prefix .. "/"
    end

    if path:sub(1, #url_prefix) ~= url_prefix then
        ngx.log(ngx.ERR, "Path outside the allowed buckets: ", path)
        return send_error(ngx.HTTP_BAD_REQUEST, "Path is outside the allowed buckets")
    end

    local relative = path:sub(#url_prefix + 1)
    local bucket, sub_path = relative:match("^([^/]+)/(.*)$")
    if not bucket then
        bucket, sub_path = relative, ""
    end

    if not dir_listing.BUCKETS[bucket] then
        ngx.log(ngx.ERR, "Path outside the allowed buckets: ", path)
        return send_error(ngx.HTTP_BAD_REQUEST, "Path is outside the allowed buckets")
    end

    local data_root = os.getenv("DATA_ROOT") or "/data"
    local entries = {}
    for _, entry in ipairs(dir_listing.list_subdirs(data_root .. url_prefix, bucket, sub_path)) do
        table.insert(entries, {
            name = entry.name,
            path = url_prefix .. bucket .. entry.rel_path,
            has_children = entry.has_children,
        })
    end

    send_json(entries)
end

-- Main request handler
local function handle_request()
    -- Verify permissions
    local groups = ngx.req.get_headers()[groups_header]
    if not has_permission(groups) then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local sub_path = get_sub_path()

    if sub_path == "roles" then
        if ngx.req.get_method() ~= "GET" then
            return send_error(ngx.HTTP_METHOD_NOT_ALLOWED, "Method not allowed")
        end
        return handle_get_roles()
    end

    if sub_path == "dirs" then
        if ngx.req.get_method() ~= "GET" then
            return send_error(ngx.HTTP_METHOD_NOT_ALLOWED, "Method not allowed")
        end
        return handle_get_dirs()
    end

    if sub_path ~= "" then
        ngx.log(ngx.ERR, "Unknown sub-path: ", sub_path)
        return send_error(ngx.HTTP_NOT_FOUND, "Unknown endpoint")
    end

    -- Route requests
    local method = ngx.req.get_method()
    if method == "GET" then
        handle_get()
    elseif method == "POST" then
        handle_post()
    else
        ngx.log(ngx.ERR, "Unsupported method: ", method)
        return ngx.exit(ngx.HTTP_METHOD_NOT_ALLOWED)
    end
end

-- Run the handler safely. Without an error handler any failure produced an
-- empty 200, which the page reported as a JSON syntax error.
local ok, err = pcall(handle_request)
if not ok then
    ngx.log(ngx.ERR, "auth-config handler error: ", err)
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Internal server error"}')
end
