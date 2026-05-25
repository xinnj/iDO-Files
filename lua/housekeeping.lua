local lfs = require("lfs")
local cjson = require("cjson.safe")

local _M = {}

local function read_config(path)
    local f = io.open(path, "r")
    if not f then
        return nil, "cannot open config: " .. path
    end
    local content = f:read("*a")
    f:close()
    local config, err = cjson.decode(content)
    if not config then
        return nil, "invalid config JSON: " .. (err or "unknown error")
    end
    return config
end

local function path_matches(dir_path, prefix)
    if dir_path == prefix then
        return true
    end
    if prefix == "/" then
        return true
    end
    if #dir_path > #prefix and dir_path:sub(1, #prefix) == prefix
        and dir_path:sub(#prefix + 1, #prefix + 1) == "/" then
        return true
    end
    return false
end

local function match_rule(rules, dir_path)
    for _, rule in ipairs(rules) do
        if path_matches(dir_path, rule.path) then
            return rule
        end
    end
    return nil
end

local function collect_files(dir_path)
    local files = {}
    for file in lfs.dir(dir_path) do
        if file ~= "." and file ~= ".." and file:sub(1, 1) ~= "." then
            local full = dir_path .. "/" .. file
            local attr = lfs.attributes(full)
            if attr and attr.mode == "file" then
                table.insert(files, {
                    name = file,
                    path = full,
                    mod_time = attr.modification,
                    size = attr.size
                })
            end
        end
    end
    return files
end

local function clean_dir(rule, dir_path, dry_run, collect_files_arg, strip_prefix)
    local files = collect_files(dir_path)
    if #files == 0 then
        if collect_files_arg then
            return 0, 0, {}
        end
        return 0, 0
    end

    table.sort(files, function(a, b) return a.mod_time > b.mod_time end)

    local to_delete = {}
    local now = os.time()
    local keep_count = rule.keep_count or 0
    local keep_days = rule.keep_days or 0
    local keep_seconds = keep_days * 86400

    for i, file in ipairs(files) do
        local should_delete = true

        if keep_count > 0 and i <= keep_count then
            should_delete = false
        end

        if keep_seconds > 0 and (now - file.mod_time) < keep_seconds then
            should_delete = false
        end

        if should_delete then
            table.insert(to_delete, file)
        end
    end

    local deleted_files = nil
    if collect_files_arg then
        deleted_files = {}
    end

    local prefix_len = strip_prefix and (#strip_prefix + 1) or 0
    local freed = 0
    for _, file in ipairs(to_delete) do
        freed = freed + file.size
        if deleted_files then
            local display_path = file.path
            if prefix_len > 0 and display_path:sub(1, prefix_len) == strip_prefix .. "/" then
                display_path = "/" .. display_path:sub(prefix_len + 1)
            end
            table.insert(deleted_files, {
                name = file.name,
                path = display_path,
                size = file.size,
                mod_time = file.mod_time
            })
        end
        if not dry_run then
            local remove_ok, remove_err = os.remove(file.path)
            if not remove_ok then
                ngx.log(ngx.WARN, "housekeeping: failed to remove ", file.path, ": ", remove_err)
            end
        end
    end

    return #to_delete, freed, deleted_files
end

local function walk_dir(rules, dir_path, dry_run, result, collect_files_arg, strip_prefix)
    local attr = lfs.attributes(dir_path)
    if not attr or attr.mode ~= "directory" then
        return
    end

    result.scanned_dirs = result.scanned_dirs + 1

    local rule = match_rule(rules, dir_path)
    if rule and ((rule.keep_count or 0) > 0 or (rule.keep_days or 0) > 0) then
        local deleted, freed, deleted_files = clean_dir(rule, dir_path, dry_run, collect_files_arg, strip_prefix)
        if deleted > 0 then
            result.cleaned_dirs = result.cleaned_dirs + 1
            result.deleted_files = result.deleted_files + deleted
            result.freed_bytes = result.freed_bytes + freed
            if collect_files_arg and deleted_files then
                for _, f in ipairs(deleted_files) do
                    table.insert(result.files, f)
                end
            end
        end
    end

    for entry in lfs.dir(dir_path) do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local full = dir_path .. "/" .. entry
            local sa = lfs.symlinkattributes(full)
            if sa and sa.mode == "directory" then
                walk_dir(rules, full, dry_run, result, collect_files_arg, strip_prefix)
            end
        end
    end
end

function _M.run(config_path, base_path, opts)
    opts = opts or {}
    local dry_run = opts.dry_run == true
    local collect_files = opts.collect_files == true
    local target_bucket = opts.bucket

    local ok, result1, result2 = pcall(read_config, config_path)
    if not ok then
        return { ok = false, error = "config read error: " .. tostring(result1) }
    end
    -- pcall succeeded, result1 is the first return value of read_config
    local config = result1
    if not config then
        -- result2 is the error string from read_config
        return { ok = false, error = result2 or "invalid config" }
    end

    local response = { ok = true, dry_run = dry_run, buckets = {} }

    for bucket, bucket_config in pairs(config) do
        if type(bucket_config) == "table"
            and (not target_bucket or bucket == target_bucket)
            and bucket_config.rules
            and #bucket_config.rules > 0 then

            local rules = {}
            local bucket_path = base_path .. bucket
            for _, r in ipairs(bucket_config.rules) do
                local abs_path
                if r.path == "/" then
                    abs_path = bucket_path
                else
                    abs_path = bucket_path .. r.path
                end
                table.insert(rules, { path = abs_path, keep_count = r.keep_count, keep_days = r.keep_days })
            end
            table.sort(rules, function(a, b) return #a.path > #b.path end)

            local result = {
                scanned_dirs = 0,
                cleaned_dirs = 0,
                deleted_files = 0,
                freed_bytes = 0,
                errors = {}
            }
            if collect_files then
                result.files = {}
            end

            local bucket_path = base_path .. bucket
            local ok, walk_err = pcall(walk_dir, rules, bucket_path, dry_run, result, collect_files, bucket_path)
            if not ok then
                table.insert(result.errors, tostring(walk_err))
            end

            response.buckets[bucket] = result
        end
    end

    return response
end

function _M.handle_request()
    ngx.header.content_type = "application/json"

    local body_data = ngx.req.get_body_data()
    local opts = { collect_files = true }
    if body_data and #body_data > 0 then
        local ok, decoded = pcall(cjson.decode, body_data)
        if ok and type(decoded) == "table" then
            for k, v in pairs(decoded) do
                opts[k] = v
            end
        end
    end

    local data_root = os.getenv("DATA_ROOT") or "/data"
    local url_prefix = ngx.var.url_prefix or "/"
    local base_path = data_root .. url_prefix
    local result = _M.run(data_root .. "/config/housekeeping.json", base_path, opts)
    if not result.ok then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    end
    ngx.say(cjson.encode(result))
end

return _M
