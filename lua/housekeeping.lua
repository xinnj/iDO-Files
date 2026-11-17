local lfs = require("lfs")
local cjson = require("cjson.safe")
local json = require("json")

local _M = {}

local function format_timestamp(epoch)
    if not epoch then return "-" end
    local t = os.date("*t", epoch)
    return string.format("%04d-%02d-%02d %02d:%02d", t.year, t.month, t.day, t.hour, t.min)
end

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

-- Retention units: files whose names produce the same key count as one file.
--
-- The key is the whole text matched by group_pattern (a Lua pattern, not a
-- capture group), so a rule can say "one build is one unit" without relying on
-- Lua's parenthesis semantics. Files that match nothing stay single units, which
-- keeps a folder of unrelated files behaving exactly as before.
local function sort_units(units)
    table.sort(units, function(a, b)
        if a.newest ~= b.newest then
            return a.newest > b.newest
        end
        if a.key ~= b.key then
            return a.key < b.key
        end
        if a.grouped ~= b.grouped then
            return a.grouped
        end
        return a.files[1].name < b.files[1].name
    end)
    return units
end

local function singleton_units(files)
    local units = {}
    for _, file in ipairs(files) do
        units[#units + 1] = {
            key = file.name,
            grouped = false,
            newest = file.mod_time or 0,
            files = { file },
        }
    end
    return units
end

local function group_files(files, pattern)
    local units = {}

    if not pattern or pattern == "" then
        return sort_units(singleton_units(files)), nil
    end

    local by_key = {}
    for _, file in ipairs(files) do
        local ok, s, e = pcall(string.find, file.name, pattern)
        if not ok then
            -- A hand-edited config can hold a malformed pattern. Cleanup must not
            -- die mid-run: log a warning at the caller, count everything as
            -- individual files, and let the next fix land in the config.
            return sort_units(singleton_units(files)), tostring(s)
        end

        -- string.find("x", "") returns 1, 0: an empty match must not create a
        -- shared "" key, or every file collapses into one unit.
        local key = (s and e >= s) and file.name:sub(s, e) or nil

        if key then
            local unit = by_key[key]
            if not unit then
                unit = { key = key, grouped = true, newest = file.mod_time or 0, files = {} }
                by_key[key] = unit
                units[#units + 1] = unit
            end
            unit.files[#unit.files + 1] = file
            if (file.mod_time or 0) > unit.newest then
                unit.newest = file.mod_time or 0
            end
        else
            -- Appended directly, never inserted into by_key: a real key equal to
            -- this name must not merge the two.
            units[#units + 1] = {
                key = file.name,
                grouped = false,
                newest = file.mod_time or 0,
                files = { file },
            }
        end
    end

    for _, unit in ipairs(units) do
        table.sort(unit.files, function(a, b) return a.name < b.name end)
    end

    return sort_units(units), nil
end

_M.group_files = group_files

-- Applies a rule to units that are already newest-first.
--
-- Same semantics as the old per-file loop, one level up: a unit inside
-- keep_count is kept; a unit whose newest member is younger than keep_days is
-- kept; only a unit that fails both is deleted, and then every file in it goes.
local function plan_deletions(units, keep_count, keep_days, now)
    keep_count = keep_count or 0
    local keep_seconds = (keep_days or 0) * 86400
    local to_delete = {}

    for i, unit in ipairs(units) do
        unit.index = i
        local keep = (keep_count > 0 and i <= keep_count)
            or (keep_seconds > 0 and (now - unit.newest) < keep_seconds)
        unit.action = keep and "keep" or "delete"

        if not keep then
            for _, file in ipairs(unit.files) do
                to_delete[#to_delete + 1] = file
            end
        end
    end

    return to_delete
end

_M.plan_deletions = plan_deletions

local MAX_GROUP_PATTERN_LEN = 256

-- Effective pattern for one rule.
--
-- The rule field is tri-state: absent (inherit the global), "" (explicitly off
-- for this rule), or a pattern. A rule is atomic, like keep_count/keep_days, so
-- a child rule with no field inherits the *global*, not its parent rule's
-- override.
function _M.resolve_group_pattern(global_pattern, rule)
    local global = type(global_pattern) == "string" and global_pattern or ""

    if rule and type(rule.group_pattern) == "string" then
        return rule.group_pattern, "rule"
    end

    if global ~= "" then
        return global, "global"
    end

    return "", "none"
end

-- Most specific rule for a bucket-relative path ("/" or "/a/b").
function _M.find_effective_rule(rules, rel_path)
    rel_path = rel_path or "/"
    if rel_path == "" then
        rel_path = "/"
    end

    local best, best_len = nil, -1
    for _, rule in ipairs(rules or {}) do
        if type(rule.path) == "string"
            and #rule.path > best_len
            and path_matches(rel_path, rule.path) then
            best, best_len = rule, #rule.path
        end
    end
    return best
end

-- Checks a pattern before it is saved.
--
-- pcall(string.find, "", p) is NOT enough: with an empty subject the matcher
-- never reaches a malformed tail, so "a[", "abc[", "zzz%" and "[a-z]%" all pass
-- it. Probe subjects that can advance through the pattern's literals. The
-- per-file pcall in group_files is still the real guarantee.
function _M.validate_pattern(pattern)
    if type(pattern) ~= "string" then
        return false, "must be a string"
    end
    if #pattern > MAX_GROUP_PATTERN_LEN then
        return false, "too long (max " .. MAX_GROUP_PATTERN_LEN .. " characters)"
    end
    if pattern == "" then
        return true
    end

    local literal = pattern:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", "")
    local probes = {
        "",
        "aaaaaaaaaaaaaaaa",
        "aA0_-./()[]{}%",
        literal,
        "MyApp-main-5.0.22-Release-Testing.ipa",
    }
    for _, subject in ipairs(probes) do
        local ok, err = pcall(string.find, subject, pattern)
        if not ok then
            return false, tostring(err)
        end
    end
    return true
end

-- Shared by the cleanup run and the preview endpoint so the two cannot drift.
function _M.preview_dir(dir_path, pattern, keep_count, keep_days)
    local files = collect_files(dir_path)
    local units, err = group_files(files, pattern or "")
    if err then
        return nil, err
    end

    plan_deletions(units, keep_count, keep_days, os.time())

    for _, unit in ipairs(units) do
        local size_total = 0
        for _, file in ipairs(unit.files) do
            size_total = size_total + (file.size or 0)
        end
        unit.size_total = size_total
        unit.file_count = #unit.files
    end

    return {
        total_files = #files,
        total_units = #units,
        units = units,
    }
end

local PREVIEW_MAX_UNITS = 100
local PREVIEW_MAX_FILES_PER_UNIT = 20

local function encode_unit(unit)
    local limit = math.min(#unit.files, PREVIEW_MAX_FILES_PER_UNIT)
    local files = {}
    for i = 1, limit do
        local file = unit.files[i]
        files[i] = cjson.encode({
            name = file.name,
            size = file.size,
            mtime = file.mod_time,
            modified = format_timestamp(file.mod_time),
        })
    end

    return json.encode_object({
        { "key", cjson.encode(unit.key) },
        { "grouped", cjson.encode(unit.grouped) },
        { "index", cjson.encode(unit.index) },
        { "newest", cjson.encode(format_timestamp(unit.newest)) },
        { "file_count", cjson.encode(unit.file_count or #unit.files) },
        { "size_total", cjson.encode(unit.size_total or 0) },
        { "action", cjson.encode(unit.action) },
        { "files_truncated", cjson.encode(#unit.files > limit) },
        { "files", "[" .. table.concat(files, ",") .. "]" },
    })
end

function _M.encode_preview(result)
    local count = math.min(#result.units, PREVIEW_MAX_UNITS)
    local truncated = #result.units > count

    local units = {}
    for i = 1, count do
        local unit = result.units[i]
        if #unit.files > PREVIEW_MAX_FILES_PER_UNIT then
            truncated = true
        end
        units[i] = encode_unit(unit)
    end

    return json.encode_object({
        { "ok", cjson.encode(result.ok ~= false) },
        { "bucket", cjson.encode(result.bucket) },
        { "path", cjson.encode(result.path) },
        { "pattern", cjson.encode(result.pattern) },
        { "pattern_source", cjson.encode(result.pattern_source) },
        { "keep_count", cjson.encode(result.keep_count) },
        { "keep_days", cjson.encode(result.keep_days) },
        { "total_files", cjson.encode(result.total_files) },
        { "total_units", cjson.encode(result.total_units) },
        { "truncated", cjson.encode(truncated) },
        { "units", "[" .. table.concat(units, ",") .. "]" },
    })
end

local function clean_dir(rule, dir_path, dry_run, collect_files_arg, strip_prefix)
    local files = collect_files(dir_path)
    if #files == 0 then
        if collect_files_arg then
            return 0, 0, {}
        end
        return 0, 0
    end

    local units, group_err = group_files(files, rule.group_pattern or "")
    if group_err then
        ngx.log(ngx.WARN, "housekeeping: ignoring invalid group_pattern '",
                tostring(rule.group_pattern), "' for ", dir_path, ": ", group_err)
    end

    local to_delete = plan_deletions(units, rule.keep_count, rule.keep_days, os.time())

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
                modified = format_timestamp(file.mod_time)
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

    local global_pattern = type(config.group_pattern) == "string" and config.group_pattern or ""

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
                table.insert(rules, {
                    path = abs_path,
                    keep_count = r.keep_count,
                    keep_days = r.keep_days,
                    -- Resolved here so clean_dir never needs the global config.
                    group_pattern = _M.resolve_group_pattern(global_pattern, r),
                })
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

-- Serialise a run result for the wire.
--
-- cjson renders an empty Lua table as {}, so a bucket that had nothing to delete
-- came back with "files": {} and "errors": {} — objects, not lists. Anything
-- reading them as arrays sees a truthy value with no .length, which is how a
-- guard like `files.length > 0` quietly does nothing. Both keys are lists by
-- contract, so they are spelled out; see lua/json.lua.
local LIST_KEYS = { files = true, errors = true }

local function encode_bucket_result(bucket)
    if type(bucket) ~= "table" then
        return cjson.encode(bucket)
    end

    local fields = {}
    for key, value in pairs(bucket) do
        if LIST_KEYS[key] then
            fields[#fields + 1] = { key, json.encode_array(value) }
        else
            fields[#fields + 1] = { key, cjson.encode(value) }
        end
    end

    return json.encode_object(fields)
end

local function encode_result(result)
    if type(result) ~= "table" then
        return cjson.encode(result) or "null"
    end

    -- buckets is a map, so its members are encoded one by one and joined by
    -- hand — the same thing encode_object does for a field, one level deeper.
    local buckets = {}
    for name, bucket in pairs(result.buckets or {}) do
        buckets[#buckets + 1] = cjson.encode(name) .. ":" .. encode_bucket_result(bucket)
    end

    local fields = {}
    for key, value in pairs(result) do
        if key == "buckets" then
            fields[#fields + 1] = { "buckets", "{" .. table.concat(buckets, ",") .. "}" }
        elseif LIST_KEYS[key] then
            fields[#fields + 1] = { key, json.encode_array(value) }
        else
            fields[#fields + 1] = { key, cjson.encode(value) }
        end
    end

    return json.encode_object(fields)
end

_M.encode_result = encode_result

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
    ngx.say(encode_result(result))
end

return _M
