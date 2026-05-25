local cjson = require("cjson.safe")
local lfs = require("lfs")
local housekeeping = require("housekeeping")

-- Config file path
local config_file = (os.getenv("DATA_ROOT") or "/data") .. "/config/housekeeping.json"

-- Admin group from env
local ADMIN_GROUP = os.getenv("ADMIN_GROUP")

-- Permission check: user must be in the ADMIN_GROUP
local function has_permission(groups_header)
    if not groups_header then
        ngx.log(ngx.WARN, "No group header provided")
        return false
    end

    for group in string.gmatch(groups_header, "([^,]+)") do
        group = group:gsub("%s+", "")
        if group == ADMIN_GROUP then
            return true
        end
    end

    ngx.log(ngx.WARN, "User does not have required permissions")
    return false
end

-- Read a file safely
local function read_file(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, "Could not open file: " .. (err or "unknown error")
    end

    local content = file:read("*a")
    file:close()
    return content, nil
end

-- Write a file atomically (write to .tmp, flush, os.rename)
local function write_file(path, content)
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

-- Validate config structure: must have download/archive/public buckets,
-- each with rules array, each rule with path (string), keep_count (number), keep_days (number)
local function validate_config(config)
    local buckets = { "download", "archive", "public" }

    for _, bucket in ipairs(buckets) do
        if config[bucket] then
            local bucket_config = config[bucket]
            if type(bucket_config) ~= "table" then
                return false, "Bucket '" .. bucket .. "' must be an object"
            end
            if bucket_config.rules then
                if type(bucket_config.rules) ~= "table" then
                    return false, "Bucket '" .. bucket .. "' rules must be an array"
                end
                for i, rule in ipairs(bucket_config.rules) do
                    if type(rule.path) ~= "string" then
                        return false, "Rule " .. i .. " in '" .. bucket .. "' missing 'path' string"
                    end
                    if type(rule.keep_count) ~= "number" then
                        return false, "Rule " .. i .. " in '" .. bucket .. "' missing 'keep_count' number"
                    end
                    if type(rule.keep_days) ~= "number" then
                        return false, "Rule " .. i .. " in '" .. bucket .. "' missing 'keep_days' number"
                    end
                end
            end
        end
    end

    return true, nil
end

-- GET /fileserver/housekeeping — serve static HTML page
local function handle_page()
    local data_root = os.getenv("DATA_ROOT") or "/data"
    local url_prefix = ngx.var.url_prefix or "/"
    local base_path = data_root .. url_prefix
    local page_path = base_path .. "fileserver/housekeeping.html"

    local content, err = read_file(page_path)
    if not content then
        ngx.log(ngx.ERR, "Failed to read housekeeping page: ", err)
        ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    ngx.header["Content-Type"] = "text/html"
    ngx.say(content)
end

-- GET /fileserver/housekeeping/config — read config JSON with version field
local function handle_get_config()
    ngx.header["Content-Type"] = "application/json"

    local content, err = read_file(config_file)
    if not content then
        -- Return default empty config with version 1 if file does not exist
        ngx.say(cjson.encode({ version = 1 }))
        return
    end

    local ok, config = pcall(cjson.decode, content)
    if not ok then
        ngx.log(ngx.ERR, "Invalid JSON in config file: ", config)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Add version field if missing
    if not config.version then
        config.version = 1
    end

    ngx.say(cjson.encode(config))
end

-- POST /fileserver/housekeeping/config — save config with version check, atomic write
local function handle_post_config()
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

    -- Require version field in body
    local expected_version = new_config.version
    if not expected_version then
        ngx.log(ngx.ERR, "No version provided in POST data")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    expected_version = tonumber(expected_version)
    if not expected_version then
        ngx.log(ngx.ERR, "Invalid version format in POST data")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Read current config version
    local current_version = 1
    local content, err = read_file(config_file)
    if content then
        local ok, current = pcall(cjson.decode, content)
        if ok and current and current.version then
            current_version = tonumber(current.version) or 1
        end
    end

    -- Version conflict check (409 on mismatch)
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

    -- Increment version and write atomically
    new_config.version = current_version + 1

    local success, write_err = write_file(config_file, cjson.encode(new_config))
    if not success then
        ngx.log(ngx.ERR, "Failed to write config file: ", write_err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Return new config as JSON
    ngx.say(cjson.encode(new_config))
end

-- GET /fileserver/housekeeping/dirs — list immediate subdirectories with rule status
local function handle_get_dirs()
    ngx.header["Content-Type"] = "application/json"

    local args = ngx.req.get_uri_args()
    local bucket = args["bucket"]
    local path = args["path"] or ""

    -- Validate bucket parameter
    if not bucket then
        ngx.log(ngx.ERR, "Missing 'bucket' parameter")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local valid_buckets = { download = true, archive = true, public = true }
    if not valid_buckets[bucket] then
        ngx.log(ngx.ERR, "Invalid bucket: ", bucket)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    -- Basic path traversal check
    if path:find("%.%.") then
        ngx.log(ngx.ERR, "Path traversal attempt: ", path)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local data_root = os.getenv("DATA_ROOT") or "/data"
    local url_prefix = ngx.var.url_prefix or "/"
    local base_path = data_root .. url_prefix

    -- Build filesystem path
    local clean_path = path
    if clean_path:sub(1, 1) == "/" then
        clean_path = clean_path:sub(2)
    end

    local fs_path
    if clean_path == "" then
        fs_path = base_path .. bucket
    else
        fs_path = base_path .. bucket .. "/" .. clean_path
    end
    -- Read housekeeping config for rules
    local rules = {}
    local content, err = read_file(config_file)
    if content then
        local ok, config = pcall(cjson.decode, content)
        if ok and config and config[bucket] and config[bucket].rules then
            for _, r in ipairs(config[bucket].rules) do
                table.insert(rules, r)
            end
        end
    end

    -- Sort rules by path length descending (most specific first)
    table.sort(rules, function(a, b) return #a.path > #b.path end)

    -- List immediate subdirectories (not files, not hidden)
    local dirs = {}
    local attr = lfs.attributes(fs_path)
    if not attr or attr.mode ~= "directory" then
        ngx.say(cjson.encode(dirs))
        return
    end

    for entry in lfs.dir(fs_path) do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local full = fs_path .. "/" .. entry
            local sa = lfs.symlinkattributes(full)
            if sa and sa.mode == "directory" then
                -- Build the relative path for this subdirectory (from bucket root)
                local rel_path
                if clean_path == "" then
                    rel_path = "/" .. entry
                else
                    rel_path = "/" .. clean_path .. "/" .. entry
                end

                -- Check for explicit rule (exact path match)
                local explicit_rule = nil
                for _, rule in ipairs(rules) do
                    if rule.path == rel_path then
                        explicit_rule = rule
                        break
                    end
                end

                -- Find effective rule (first prefix match from sorted rules)
                local effective_rule = nil
                for _, rule in ipairs(rules) do
                    if rel_path == rule.path then
                        effective_rule = rule
                        break
                    end
                    if rule.path == "/"
                        or (#rel_path > #rule.path
                            and rel_path:sub(1, #rule.path) == rule.path
                            and rel_path:sub(#rule.path + 1, #rule.path + 1) == "/") then
                        effective_rule = rule
                        break
                    end
                end

                -- Check if this directory has subdirectories
                local has_children = false
                for subentry in lfs.dir(full) do
                    if subentry ~= "." and subentry ~= ".." and subentry:sub(1, 1) ~= "." then
                        local subfull = full .. "/" .. subentry
                        local subsa = lfs.symlinkattributes(subfull)
                        if subsa and subsa.mode == "directory" then
                            has_children = true
                            break
                        end
                    end
                end

                local entry_data = {
                    name = entry,
                    has_rule = explicit_rule ~= nil,
                    has_children = has_children,
                }
                if explicit_rule then
                    entry_data.rule = explicit_rule
                end
                if effective_rule then
                    entry_data.effective_rule = {
                        keep_count = effective_rule.keep_count,
                        keep_days = effective_rule.keep_days,
                        source = effective_rule.path
                    }
                end

                table.insert(dirs, entry_data)
            end
        end
    end

    -- Sort entries by name
    table.sort(dirs, function(a, b) return a.name < b.name end)

    ngx.say(cjson.encode(dirs))
end

-- POST /fileserver/housekeeping/run — trigger housekeeping.run() with collect_files=true
local function handle_post_run()
    ngx.header["Content-Type"] = "application/json"
    ngx.req.read_body()

    local body_data = ngx.req.get_body_data()
    local opts = { collect_files = true }

    if body_data and #body_data > 0 then
        local ok, decoded = pcall(cjson.decode, body_data)
        if ok and type(decoded) == "table" then
            if decoded.dry_run ~= nil then
                opts.dry_run = decoded.dry_run == true
            end
        end
    end

    local data_root = os.getenv("DATA_ROOT") or "/data"
    local url_prefix = ngx.var.url_prefix or "/"
    local base_path = data_root .. url_prefix

    local result = housekeeping.run(config_file, base_path, opts)

    -- Initialize result.files when collect_files is true
    if not result.files then
        result.files = {}
    end

    ngx.say(cjson.encode(result))
end

-- Parse sub-path from URI: extract the part after "/fileserver/housekeeping"
local function get_sub_path()
    local uri = ngx.var.uri
    local prefix = "fileserver/housekeeping"
    local pos = uri:find(prefix)
    if not pos then
        return ""
    end
    local sub = uri:sub(pos + #prefix)
    -- Remove leading and trailing slashes
    sub = sub:gsub("^/", ""):gsub("/$", "")
    return sub
end

-- Main request handler
local function handle_request()
    -- Verify admin permissions
    local groups = ngx.req.get_headers()["X-USER-GROUPS"]
    if not has_permission(groups) then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local method = ngx.req.get_method()
    local sub_path = get_sub_path()

    if sub_path == "" and method == "GET" then
        handle_page()
    elseif sub_path == "config" and method == "GET" then
        handle_get_config()
    elseif sub_path == "config" and method == "POST" then
        handle_post_config()
    elseif sub_path == "dirs" and method == "GET" then
        handle_get_dirs()
    elseif sub_path == "run" and method == "POST" then
        handle_post_run()
    else
        ngx.log(ngx.ERR, "Unsupported route: ", method, " ", sub_path)
        ngx.exit(ngx.HTTP_NOT_FOUND)
    end
end

-- Run the handler safely with pcall for error handling
local ok, err = pcall(handle_request)
if not ok then
    ngx.log(ngx.ERR, "housekeeping-admin handler error: ", tostring(err))
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = tostring(err) }))
end
