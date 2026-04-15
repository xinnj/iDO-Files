local cjson = require "cjson.safe"
local auth = require "authorize"

-- Config file path
local config_file = "/data/config/auth_config.json"

-- Header containing user groups
local groups_header = "X-USER-GROUPS"

local ADMIN_GROUP = os.getenv("ADMIN_GROUP")

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

-- Write file safely (atomic operation)
local function write_file(path, content)
    -- Write to temporary file first
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

    -- Ensure all data is written
    file:flush()

    -- Check for write errors
    local ok, close_err = file:close()
    if not ok then
        return false, "Failed to close file: " .. (close_err or "unknown error")
    end

    -- Replace original file
    local ok, rename_err = os.rename(tmp_path, path)
    if not ok then
        return false, "Failed to replace file: " .. (rename_err or "unknown error")
    end

    return true, nil
end

-- Get current version of config file
local function get_current_version()
    local content, err = read_file(config_file)
    if not content then
        return nil, err
    end

    local ok, config = pcall(cjson.decode, content)
    if not ok then
        return nil, "Invalid JSON in config file"
    end

    return config.version or 1, nil
end

-- Validate configuration structure
local function validate_config(config)
    if type(config.rules) ~= "table" then
        return false, "Config must be a JSON object"
    end

    for group, rules in pairs(config.rules) do
        if type(group) ~= "string" or not group:startswith("/") then
            return false, "Group keys must be strings starting with /"
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

        -- Validate each rule
        for _, rule in ipairs(rules.allow) do
            if type(rule) ~= "string" or not rule:match("^.+:/.+") then
                return false, "Invalid rule in allow list: " .. tostring(rule)
            end
        end

        for _, rule in ipairs(rules.deny) do
            if type(rule) ~= "string" or not rule:match("^.+:/.+") then
                return false, "Invalid rule in deny list: " .. tostring(rule)
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
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Validate JSON structure
    local ok, config = pcall(cjson.decode, content)
    if not ok then
        ngx.log(ngx.ERR, "Invalid JSON in config file: ", config)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.say(cjson.encode(config))
end

-- Handler for POST requests (save config with version check)
local function handle_post()
    ngx.header["Content-Type"] = "application/json"
    ngx.req.read_body()
    local post_data = ngx.req.get_body_data()

    if not post_data then
        ngx.log(ngx.ERR, "No POST data received")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Validate JSON
    local ok, new_config = pcall(cjson.decode, post_data)
    if not ok then
        ngx.log(ngx.ERR, "Invalid JSON in POST data: ", new_config)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Get expected version from post_data
    local expected_version = new_config.version
    if expected_version then
        expected_version = tonumber(expected_version)
        if not expected_version then
            ngx.log(ngx.ERR, "Invalid version format in POST data")
            ngx.exit(ngx.HTTP_BAD_REQUEST)
        end
    else
        ngx.log(ngx.ERR, "No version provided in POST data")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Get current version
    local current_version, err = get_current_version()
    if not current_version then
        ngx.log(ngx.ERR, "Failed to get current version: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Version conflict check
    if expected_version ~= current_version then
        ngx.log(ngx.ERR, "Version conflict: expected ", expected_version, ", got ", current_version)
        ngx.exit(ngx.HTTP_CONFLICT)
    end

    -- Validate config structure
    local valid, err = validate_config(new_config)
    if not valid then
        ngx.log(ngx.ERR, "Invalid configuration: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Increment version
    new_config.version = current_version + 1

    -- Write to file
    local success, write_err = write_file(config_file, cjson.encode(new_config))
    if not success then
        ngx.log(ngx.ERR, "Failed to write config file: ", write_err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local ok, err = auth.save_config_to_redis()
    if not ok then
        ngx.log(ngx.ERR, "Failed to save config to Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Return success with new config
    ngx.say(cjson.encode(new_config))
end

-- Main request handler
local function handle_request()
    -- Verify permissions
    local groups = ngx.req.get_headers()[groups_header]
    if not has_permission(groups) then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    -- Route requests
    local method = ngx.req.get_method()
    if method == "GET" then
        handle_get()
    elseif method == "POST" then
        handle_post()
    else
        ngx.log(ngx.ERR, "Unsupported method: ", method)
        ngx.exit(ngx.HTTP_METHOD_NOT_ALLOWED)
    end
end

-- Add string.startswith method for convenience
if not string.startswith then
    function string.startswith(str, substr)
        return str:sub(1, #substr) == substr
    end
end

-- Run the handler safely
pcall(handle_request)