-- Tests for housekeeping.lua
--
-- Test framework: busted (https://olivinelabs.com/busted/)
-- Run with:
--   LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/housekeeping_spec.lua

local ngx_mock = require("mock_ngx")
_G.ngx = ngx_mock

-- ============================================================================
-- Mock lfs (Lua Filesystem)
-- ============================================================================
local mock_entries = {}  -- path -> {entry_name, ...}
local mock_attrs = {}    -- path -> {mode, modification, size, ...}

local function setup_filesystem(entries)
    mock_entries = {}
    mock_attrs = {}
    for path, attr in pairs(entries) do
        mock_attrs[path] = attr
        local parent, name = path:match("^(.*)/([^/]+)$")
        if parent then
            if not mock_entries[parent] then
                mock_entries[parent] = {}
            end
            table.insert(mock_entries[parent], name)
        end
    end
end

package.loaded["lfs"] = {
    dir = function(path)
        local entries = mock_entries[path] or {}
        local i = 0
        return function()
            i = i + 1
            return entries[i]
        end
    end,
    attributes = function(path)
        return mock_attrs[path]
    end,
    symlinkattributes = function(path)
        return mock_attrs[path]
    end
}

-- ============================================================================
-- Track os.remove calls
-- ============================================================================
local removed_files = {}
local original_os_remove = os.remove
os.remove = function(path)
    table.insert(removed_files, path)
    return true
end

-- ============================================================================
-- Mock os.time for deterministic file ages
-- ============================================================================
local mock_time = 1000000000  -- fixed timestamp (~2001-09-09)
local original_os_time = os.time
os.time = function()
    return mock_time
end

-- ============================================================================
-- Mock io.open for config file reading
-- ============================================================================
local mock_config_files = {}
local original_io_open = io.open
io.open = function(path, mode)
    if path:find("__throw__", 1, true) then
        error("simulated I/O error: " .. path)
    end
    if mock_config_files[path] ~= nil then
        local content = mock_config_files[path]
        return {
            read = function(self, fmt)
                return content
            end,
            close = function() end
        }
    end
    return nil, "no such file"
end

-- ============================================================================
-- Require the module under test
-- ============================================================================
package.loaded["housekeeping"] = nil
local housekeeping = require("housekeeping")

-- ============================================================================
-- Reset state before each test
-- ============================================================================
local function reset_state()
    removed_files = {}
    mock_entries = {}
    mock_attrs = {}
    mock_config_files = {}
    ngx_mock.status = nil
    ngx_mock.header = {}
    ngx_mock.req.get_body_data = function() return nil end
    ngx_mock.var.url_prefix = "/"
    ngx_mock.say = function(s) end
end

-- ============================================================================
-- Tests
-- ============================================================================
describe("housekeeping module", function()
    before_each(function()
        reset_state()
    end)

    -- ========================================================================
    -- Config loading errors
    -- ========================================================================
    describe("config loading errors", function()

        it("returns error when config file cannot be opened", function()
            local result = housekeeping.run("/nonexistent/config.json", "/data/test/")
            assert.is_false(result.ok)
            assert.is_not_nil(result.error)
            assert.is_true(result.error:find("cannot open") ~= nil)
        end)

        it("returns error when config JSON is invalid", function()
            mock_config_files["/data/config/bad.json"] = "not valid json {{{"
            local result = housekeeping.run("/data/config/bad.json", "/data/test/")
            assert.is_false(result.ok)
            assert.is_not_nil(result.error)
        end)

        it("returns error when read_config throws", function()
            local result = housekeeping.run("__throw__/config.json", "/data/test/")
            assert.is_false(result.ok)
            assert.is_not_nil(result.error)
            assert.is_true(result.error:find("config read error") ~= nil)
        end)

    end)

    -- ========================================================================
    -- Empty rules
    -- ========================================================================
    describe("empty rules", function()

        it("skips buckets with empty rules array", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [] },
                "public": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/public"] = { mode = "directory" },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.is_nil(result.buckets.download)
            assert.is_not_nil(result.buckets.public)
        end)

        it("skips buckets with no rules key", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "enabled": true }
            }
            ]]
            setup_filesystem({})

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.is_nil(result.buckets.download)
        end)

    end)

    -- ========================================================================
    -- Count-based retention (keep_count)
    -- ========================================================================
    describe("count-based retention (keep_count)", function()

        it("deletes oldest files when count exceeds keep_count", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 2}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
                ["/data/test/download/file3.txt"] = { mode = "file", modification = mock_time - 300, size = 300 },
                ["/data/test/download/file4.txt"] = { mode = "file", modification = mock_time - 400, size = 400 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            local bucket = result.buckets.download
            assert.is_not_nil(bucket)
            assert.are.equal(2, bucket.deleted_files)
            assert.are.equal(700, bucket.freed_bytes) -- 300 + 400
            assert.are.equal(1, bucket.cleaned_dirs)
        end)

        it("does not delete when file count is within keep_count", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 10}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(0, result.buckets.download.deleted_files)
            assert.are.equal(0, result.buckets.download.freed_bytes)
        end)

        it("keep_count=0 disables count check when keep_days is large", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 0, "keep_days": 999}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/old.txt"] = { mode = "file", modification = mock_time - 500000, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(0, result.buckets.download.deleted_files)
        end)

    end)

    -- ========================================================================
    -- Age-based retention (keep_days)
    -- ========================================================================
    describe("age-based retention (keep_days)", function()

        it("deletes files older than keep_days", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_days": 2}] }
            }
            ]]
            local two_days = 2 * 86400
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/new.txt"] = { mode = "file", modification = mock_time - 1000, size = 100 },
                ["/data/test/download/old.txt"] = { mode = "file", modification = mock_time - two_days - 1, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(1, result.buckets.download.deleted_files)
            assert.are.equal(200, result.buckets.download.freed_bytes)
        end)

        it("keep_days=0 disables age check when keep_count is large", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_days": 0, "keep_count": 999}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/old.txt"] = { mode = "file", modification = mock_time - 500000, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(0, result.buckets.download.deleted_files)
        end)

    end)

    -- ========================================================================
    -- Combined count + age (AND logic)
    -- ========================================================================
    describe("combined count and age retention", function()

        it("only deletes files beyond keep_count AND older than keep_days", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 2, "keep_days": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                -- file1, file2: kept by count (newest 2)
                -- file3: beyond count but only 3 days old -> kept by age
                -- file4: beyond count AND 10 days old -> deleted
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100,       size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200,       size = 200 },
                ["/data/test/download/file3.txt"] = { mode = "file", modification = mock_time - 3*86400,    size = 300 },
                ["/data/test/download/file4.txt"] = { mode = "file", modification = mock_time - 10*86400,   size = 400 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(1, result.buckets.download.deleted_files)
            assert.are.equal(400, result.buckets.download.freed_bytes)
        end)

    end)

    -- ========================================================================
    -- Build grouping (group_files)
    -- ========================================================================
    describe("group_files", function()

        local function files(list)
            local result = {}
            for i, entry in ipairs(list) do
                result[i] = {
                    name = entry[1],
                    path = "/data/test/download/" .. entry[1],
                    mod_time = entry[2],
                    size = i,
                }
            end
            return result
        end

        it("treats files sharing the matched prefix as one unit", function()
            local units, err = housekeeping.group_files(files({
                { "MyApp-main-5.0.22-Release-Testing.plist", 100 },
                { "MyApp-main-5.0.22-Release-Testing.ipa",   200 },
                { "MyApp-main-5.0.22-Appstore.ipa",          300 },
                { "MyApp-main-5.0.23-Appstore.ipa",          400 },
            }), "^.-%-%d+%.%d+%.%d+")

            assert.is_nil(err)
            assert.are.equal(2, #units)

            assert.are.equal("MyApp-main-5.0.23", units[1].key)
            assert.are.equal(1, #units[1].files)

            assert.are.equal("MyApp-main-5.0.22", units[2].key)
            assert.are.equal(3, #units[2].files)
            assert.is_true(units[2].grouped)
        end)

        it("keeps unmatched files as their own units", function()
            local units, err = housekeeping.group_files(files({
                { "MyApp-main-5.0.22-Appstore.ipa", 300 },
                { "MyApp-main-5.0.22-Release.ipa",  200 },
                { "README.txt",                         100 },
            }), "^.-%-%d+%.%d+%.%d+")

            assert.is_nil(err)
            assert.are.equal(2, #units)

            assert.are.equal("MyApp-main-5.0.22", units[1].key)
            assert.are.equal(2, #units[1].files)

            assert.are.equal("README.txt", units[2].key)
            assert.is_false(units[2].grouped)
            assert.are.equal(1, #units[2].files)
        end)

        it("treats every file as its own unit without a pattern", function()
            local source = files({
                { "a-5.0.22.ipa", 300 },
                { "a-5.0.22.plist", 200 },
                { "b.txt", 100 },
            })

            for _, pattern in ipairs({ "", nil }) do
                local units, err = housekeeping.group_files(source, pattern)
                assert.is_nil(err)
                assert.are.equal(3, #units)
                for _, unit in ipairs(units) do
                    assert.is_false(unit.grouped)
                    assert.are.equal(1, #unit.files)
                end
            end
        end)

        it("does not group on an empty match", function()
            for _, pattern in ipairs({ "^", "a*" }) do
                local units, err = housekeeping.group_files(files({
                    { "bbb", 300 },
                    { "ccc", 200 },
                }), pattern)

                assert.is_nil(err)
                assert.are.equal(2, #units)
                assert.is_false(units[1].grouped)
            end
        end)

        it("uses the whole match as the key, not a capture", function()
            local units, err = housekeeping.group_files(files({
                { "build-v5.0.22-Release.ipa", 300 },
                { "build-v5.0.22-Appstore.ipa", 200 },
            }), "(%d+)%.(%d+)")

            assert.is_nil(err)
            assert.are.equal(1, #units)
            assert.are.equal("5.0", units[1].key)
        end)

        it("takes the unit time from its newest member", function()
            local units = housekeeping.group_files(files({
                { "build-5.0.22-old.ipa",   100 },
                { "build-5.0.22-new.ipa",   500 },
                { "build-5.0.21-old.ipa",   200 },
            }), "^build%-%d+%.%d+%.%d+")

            assert.are.equal(2, #units)
            assert.are.equal("build-5.0.22", units[1].key)
            assert.are.equal(500, units[1].newest)
        end)

        it("orders equal unit times deterministically", function()
            local source = files({
                { "b.txt", 100 },
                { "a.txt", 100 },
            })

            local first = housekeeping.group_files(source, "")
            local second = housekeeping.group_files({ source[2], source[1] }, "")

            assert.are.equal("a.txt", first[1].key)
            assert.are.equal("a.txt", second[1].key)
            assert.are.equal("b.txt", first[2].key)
            assert.are.equal("b.txt", second[2].key)
        end)

        it("degrades to no grouping and reports a malformed pattern", function()
            local units, err = housekeeping.group_files(files({
                { "a.ipa", 300 },
                { "b.ipa", 200 },
            }), "a[")

            assert.is_not_nil(err)
            assert.are.equal(2, #units)
            assert.is_false(units[1].grouped)
        end)

    end)

    -- ========================================================================
    -- Unit retention (plan_deletions)
    -- ========================================================================
    describe("plan_deletions", function()

        local function units_from(list, pattern)
            local files = {}
            for i, entry in ipairs(list) do
                files[i] = { name = entry[1], path = "/d/" .. entry[1], mod_time = entry[2], size = 10 }
            end
            return housekeeping.group_files(files, pattern)
        end

        it("deletes every file of units beyond keep_count", function()
            local units = units_from({
                { "build-5.0.23-Appstore.ipa", 400 },
                { "build-5.0.22-Release.ipa",  300 },
                { "build-5.0.22-Appstore.ipa", 200 },
                { "build-5.0.22-Release.plist", 100 },
            }, "^build%-%d+%.%d+%.%d+")

            local deleted = housekeeping.plan_deletions(units, 1, 0, mock_time)

            assert.are.equal(3, #deleted)
            assert.are.equal("keep", units[1].action)
            assert.are.equal("delete", units[2].action)
        end)

        it("rescues a unit whose newest member is young", function()
            local units = units_from({
                { "build-5.0.23-Appstore.ipa", mock_time - 1000 },
                { "build-5.0.22-Release.ipa",  mock_time - 10 * 86400 },
                { "build-5.0.22-Appstore.ipa", mock_time - 86400 },
            }, "^build%-%d+%.%d+%.%d+")

            -- Beyond keep_count, but 5.0.22 has a one-day-old member.
            local deleted = housekeeping.plan_deletions(units, 1, 7, mock_time)

            assert.are.equal(0, #deleted)
            assert.are.equal("keep", units[2].action)
        end)

        it("deletes a unit past both limits", function()
            local units = units_from({
                { "build-5.0.23-Appstore.ipa", mock_time - 1000 },
                { "build-5.0.22-Release.ipa",  mock_time - 10 * 86400 },
                { "build-5.0.22-Appstore.ipa", mock_time - 9 * 86400 },
            }, "^build%-%d+%.%d+%.%d+")

            local deleted = housekeeping.plan_deletions(units, 1, 7, mock_time)

            assert.are.equal(2, #deleted)
            assert.are.equal("delete", units[2].action)
        end)

        it("counts unmatched files individually", function()
            local units = units_from({
                { "build-5.0.22-Appstore.ipa", 400 },
                { "build-5.0.22-Release.ipa",  300 },
                { "notes.txt",                 200 },
                { "readme.txt",                100 },
            }, "^build%-%d+%.%d+%.%d+")

            local deleted = housekeeping.plan_deletions(units, 1, 0, mock_time)

            assert.are.equal(2, #deleted)
            assert.are.equal("notes.txt", deleted[1].name)
            assert.are.equal("readme.txt", deleted[2].name)
        end)

    end)

    -- ========================================================================
    -- Pattern resolution and validation
    -- ========================================================================
    describe("resolve_group_pattern", function()

        it("uses the global pattern when the rule has no override", function()
            local pattern, source = housekeeping.resolve_group_pattern("^global", { path = "/" })
            assert.are.equal("^global", pattern)
            assert.are.equal("global", source)
        end)

        it("lets a rule override the global", function()
            local pattern, source = housekeeping.resolve_group_pattern("^global",
                { path = "/", group_pattern = "^rule" })
            assert.are.equal("^rule", pattern)
            assert.are.equal("rule", source)
        end)

        it("treats an empty rule override as no grouping", function()
            local pattern, source = housekeeping.resolve_group_pattern("^global",
                { path = "/", group_pattern = "" })
            assert.are.equal("", pattern)
            assert.are.equal("rule", source)
        end)

        it("treats a missing or empty global as no grouping", function()
            assert.are.equal("", (housekeeping.resolve_group_pattern(nil, { path = "/" })))
            assert.are.equal("none", select(2, housekeeping.resolve_group_pattern(nil, { path = "/" })))
            assert.are.equal("", (housekeeping.resolve_group_pattern("", { path = "/" })))
            assert.are.equal("none", select(2, housekeeping.resolve_group_pattern("", { path = "/" })))
        end)

        it("ignores a non-string global value", function()
            local pattern, source = housekeeping.resolve_group_pattern(42, { path = "/" })
            assert.are.equal("", pattern)
            assert.are.equal("none", source)
        end)

    end)

    describe("find_effective_rule", function()

        local rules = {
            { path = "/", keep_count = 50 },
            { path = "/builds", keep_count = 10 },
            { path = "/builds/ios", keep_count = 5 },
        }

        it("picks the most specific matching rule", function()
            assert.are.equal("/builds/ios", housekeeping.find_effective_rule(rules, "/builds/ios").path)
            assert.are.equal("/builds", housekeeping.find_effective_rule(rules, "/builds/android").path)
            assert.are.equal("/", housekeeping.find_effective_rule(rules, "/other").path)
        end)

        it("respects path boundaries", function()
            assert.are.equal("/", housekeeping.find_effective_rule(rules, "/buildsx").path)
        end)

        it("returns nil when no rule matches", function()
            assert.is_nil(housekeeping.find_effective_rule({ { path = "/builds" } }, "/other"))
        end)

    end)

    describe("validate_pattern", function()

        it("accepts empty and well-formed patterns", function()
            assert.is_true((housekeeping.validate_pattern("")))
            assert.is_true((housekeeping.validate_pattern("^.-%-%d+%.%d+%.%d+")))
            assert.is_true((housekeeping.validate_pattern("[a-z]+%.[a-z]+")))
        end)

        it("rejects malformed patterns", function()
            for _, pattern in ipairs({ "%", "a[", "abc[", "zzz%", "[a-z]%" }) do
                local ok, err = housekeeping.validate_pattern(pattern)
                assert.is_false(ok, "accepted: " .. pattern)
                assert.is_not_nil(err)
            end
        end)

        it("rejects non-strings and over-long patterns", function()
            assert.is_false((housekeeping.validate_pattern(42)))
            assert.is_false((housekeeping.validate_pattern(string.rep("a", 257))))
        end)

    end)

    -- ========================================================================
    -- Grouped retention (run integration)
    -- ========================================================================
    describe("grouped retention", function()

        local function build_dir()
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/build-5.0.23-Appstore.ipa"] = { mode = "file", modification = mock_time - 50,  size = 40 },
                ["/data/test/download/build-5.0.23-Release.ipa"]  = { mode = "file", modification = mock_time - 60,  size = 5 },
                ["/data/test/download/build-5.0.22-Appstore.ipa"] = { mode = "file", modification = mock_time - 100, size = 30 },
                ["/data/test/download/build-5.0.22-Release.ipa"]  = { mode = "file", modification = mock_time - 200, size = 20 },
                ["/data/test/download/build-5.0.22-Release.plist"] = { mode = "file", modification = mock_time - 300, size = 10 },
            })
        end

        it("counts a build as one unit against keep_count", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_true(result.ok)
            -- Grouped, 5.0.22 is one unit and all three of its files go. Counting
            -- files individually would delete four (65 bytes).
            assert.are.equal(3, result.buckets.download.deleted_files)
            assert.are.equal(60, result.buckets.download.freed_bytes)
        end)

        it("groups with a rule pattern when no global is set", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": {
                    "rules": [{"path": "/", "keep_count": 1,
                               "group_pattern": "^.-%-%d+%.%d+%.%d+"}]
                }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_true(result.ok)
            assert.are.equal(3, result.buckets.download.deleted_files)
        end)

        it("lets a rule override the global pattern", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": {
                    "rules": [{"path": "/", "keep_count": 1, "group_pattern": "^build"}]
                }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_true(result.ok)
            -- "^build" puts all four files in one unit, so nothing is beyond 1.
            assert.are.equal(0, result.buckets.download.deleted_files)
        end)

        it("treats an empty rule override as no grouping", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": {
                    "rules": [{"path": "/", "keep_count": 3, "group_pattern": ""}]
                }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_true(result.ok)
            -- Grouping would see only two units and delete nothing; per-file
            -- counting keeps the three newest and deletes the last two.
            assert.are.equal(2, result.buckets.download.deleted_files)
            assert.are.equal(30, result.buckets.download.freed_bytes)
        end)

        it("does not treat the global pattern as a bucket", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_nil(result.buckets.group_pattern)
            assert.is_not_nil(result.buckets.download)
        end)

        it("rescues an old build with one recent file", function()
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/build-5.0.23-Appstore.ipa"] = { mode = "file", modification = mock_time - 100, size = 10 },
                ["/data/test/download/build-5.0.22-Appstore.ipa"] = { mode = "file", modification = mock_time - 10 * 86400, size = 20 },
                ["/data/test/download/build-5.0.22-Release.ipa"]  = { mode = "file", modification = mock_time - 86400, size = 30 },
            })
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": { "rules": [{"path": "/", "keep_count": 1, "keep_days": 7}] }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_true(result.ok)
            assert.are.equal(0, result.buckets.download.deleted_files)
        end)

        it("does not crash on a malformed pattern in the config", function()
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/a.ipa"] = { mode = "file", modification = mock_time - 100, size = 10 },
                ["/data/test/download/b.ipa"] = { mode = "file", modification = mock_time - 200, size = 20 },
            })
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "a[",
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/")

            assert.is_true(result.ok)
            assert.are.equal(1, result.buckets.download.deleted_files)
        end)

        it("reports every deleted file of a dropped unit", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/", { collect_files = true })

            assert.are.equal(3, #result.buckets.download.files)
            local names = {}
            for _, file in ipairs(result.buckets.download.files) do
                names[file.name] = true
            end
            assert.is_true(names["build-5.0.22-Appstore.ipa"])
            assert.is_true(names["build-5.0.22-Release.ipa"])
            assert.is_true(names["build-5.0.22-Release.plist"])
        end)

        it("does not remove files in dry_run mode", function()
            build_dir()
            mock_config_files["/data/config/test.json"] = [[
            {
                "group_pattern": "^.-%-%d+%.%d+%.%d+",
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]

            local result = housekeeping.run("/data/config/test.json", "/data/test/", { dry_run = true })

            assert.are.equal(3, result.buckets.download.deleted_files)
            assert.are.equal(0, #removed_files)
        end)

    end)

    -- ========================================================================
    -- Preview
    -- ========================================================================
    describe("preview_dir", function()

        it("returns units with their keep/delete action", function()
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/build-5.0.23-Appstore.ipa"] = { mode = "file", modification = mock_time - 50,  size = 40 },
                ["/data/test/download/build-5.0.23-Release.ipa"]  = { mode = "file", modification = mock_time - 60,  size = 5 },
                ["/data/test/download/build-5.0.22-Appstore.ipa"] = { mode = "file", modification = mock_time - 100, size = 30 },
                ["/data/test/download/build-5.0.22-Release.ipa"]  = { mode = "file", modification = mock_time - 200, size = 20 },
                ["/data/test/download/build-5.0.22-Release.plist"] = { mode = "file", modification = mock_time - 300, size = 10 },
            })

            local result, err = housekeeping.preview_dir(
                "/data/test/download", "^.-%-%d+%.%d+%.%d+", 1, 0)

            assert.is_nil(err)
            assert.are.equal(5, result.total_files)
            assert.are.equal(2, result.total_units)

            assert.are.equal("keep", result.units[1].action)
            assert.are.equal(2, result.units[1].file_count)
            assert.are.equal(45, result.units[1].size_total)

            assert.are.equal("delete", result.units[2].action)
            assert.are.equal(3, result.units[2].file_count)
            assert.are.equal(60, result.units[2].size_total)
        end)

        it("returns an error for a malformed pattern", function()
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/a.ipa"] = { mode = "file", modification = mock_time - 100, size = 10 },
            })

            local result, err = housekeeping.preview_dir("/data/test/download", "a[", 1, 0)

            assert.is_nil(result)
            assert.is_not_nil(err)
        end)

    end)

    describe("encode_preview()", function()

        local cjson = require("cjson.safe")

        local function preview(units, extra)
            local result = {
                ok = true,
                bucket = "download",
                path = "/builds",
                pattern = "^.-%-%d+%.%d+%.%d+",
                pattern_source = "global",
                keep_count = 1,
                keep_days = 0,
                total_files = 0,
                total_units = #units,
                units = units,
            }
            for key, value in pairs(extra or {}) do
                result[key] = value
            end
            return result
        end

        it("spells an empty units list as []", function()
            local text = housekeeping.encode_preview(preview({}, { pattern = "", pattern_source = "none" }))

            assert.is_true(text:find('"units":[]', 1, true) ~= nil, "no units array in: " .. text)
            assert.is_nil(text:find('"units":{}', 1, true), "empty units became an object: " .. text)
        end)

        it("encodes populated units and their files as arrays", function()
            local text = housekeeping.encode_preview(preview({
                {
                    key = "build-5.0.22",
                    grouped = true,
                    index = 1,
                    newest = mock_time - 100,
                    action = "delete",
                    files = {
                        { name = "build-5.0.22-A.ipa", size = 10, mod_time = mock_time - 100 },
                        { name = "build-5.0.22-B.ipa", size = 20, mod_time = mock_time - 200 },
                    },
                },
            }))

            local decoded = cjson.decode(text)
            assert.are.equal(1, #decoded.units)
            assert.are.equal("build-5.0.22", decoded.units[1].key)
            assert.is_true(decoded.units[1].grouped)
            assert.are.equal("delete", decoded.units[1].action)
            assert.are.equal(2, #decoded.units[1].files)
            assert.are.equal("build-5.0.22-A.ipa", decoded.units[1].files[1].name)
        end)

        it("caps files per unit and flags truncation", function()
            local files = {}
            for i = 1, 21 do
                files[i] = { name = string.format("build-5.0.22-%02d.ipa", i), size = 1, mod_time = mock_time - i }
            end

            local text = housekeeping.encode_preview(preview({
                {
                    key = "build-5.0.22",
                    grouped = true,
                    index = 1,
                    newest = mock_time - 1,
                    action = "keep",
                    files = files,
                },
            }, { total_files = 21 }))

            local decoded = cjson.decode(text)
            assert.are.equal(21, decoded.units[1].file_count)
            assert.are.equal(20, #decoded.units[1].files)
            assert.is_true(decoded.units[1].files_truncated)
            assert.is_true(decoded.truncated)
        end)

        it("caps the number of units and flags truncation", function()
            local units = {}
            for i = 1, 101 do
                units[i] = {
                    key = string.format("file-%03d.txt", i),
                    grouped = false,
                    index = i,
                    newest = mock_time - i,
                    action = i <= 1 and "keep" or "delete",
                    files = { { name = string.format("file-%03d.txt", i), size = 1, mod_time = mock_time - i } },
                }
            end

            local text = housekeeping.encode_preview(preview(units, { total_files = 101 }))
            local decoded = cjson.decode(text)

            assert.are.equal(101, decoded.total_units)
            assert.are.equal(100, #decoded.units)
            assert.is_true(decoded.truncated)
        end)

    end)

    -- ========================================================================
    -- dry_run mode
    -- ========================================================================
    describe("dry_run mode", function()

        it("counts files but does not remove them when dry_run=true", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/", { dry_run = true })
            assert.is_true(result.ok)
            assert.is_true(result.dry_run)
            assert.are.equal(1, result.buckets.download.deleted_files)
            assert.are.equal(200, result.buckets.download.freed_bytes)
            assert.are.equal(0, #removed_files)
        end)

        it("actually removes files when dry_run=false", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/", { dry_run = false })
            assert.is_true(result.ok)
            assert.is_false(result.dry_run)
            assert.are.equal(1, result.buckets.download.deleted_files)
            assert.are.equal(1, #removed_files)
        end)

        it("dry_run defaults to false when not specified in opts", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_false(result.dry_run)
            assert.are.equal(1, #removed_files)
        end)

    end)

    -- ========================================================================
    -- Bucket filtering
    -- ========================================================================
    describe("bucket filtering", function()

        it("only processes the specified bucket when opts.bucket is set", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] },
                "public": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
                ["/data/test/public"] = { mode = "directory" },
                ["/data/test/public/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 50 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/", { bucket = "download" })
            assert.is_true(result.ok)
            assert.is_not_nil(result.buckets.download)
            assert.is_nil(result.buckets.public)
        end)

    end)

    -- ========================================================================
    -- Parent rule inheritance (prefix matching)
    -- ========================================================================
    describe("parent rule inheritance", function()

        it("applies parent directory rule to child directories via prefix matching", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/app", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/app"] = { mode = "directory" },
                ["/data/test/download/app/v1"] = { mode = "directory" },
                ["/data/test/download/app/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/app/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
                ["/data/test/download/app/v1/file3.txt"] = { mode = "file", modification = mock_time - 300, size = 300 },
                ["/data/test/download/app/v1/file4.txt"] = { mode = "file", modification = mock_time - 400, size = 400 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            local bucket = result.buckets.download
            assert.is_not_nil(bucket)
            -- "download/app" has 2 files, keep 1 -> 1 deleted
            -- "download/app/v1" inherits same rule, 2 files, keep 1 -> 1 deleted
            -- Total: 2 deleted files, 2 cleaned dirs, 3 scanned dirs
            assert.are.equal(2, bucket.deleted_files)
            assert.are.equal(2, bucket.cleaned_dirs)
            assert.are.equal(3, bucket.scanned_dirs) -- download, download/app, download/app/v1
        end)

    end)

    -- ========================================================================
    -- Edge cases
    -- ========================================================================
    describe("edge cases", function()

        it("handles empty directories without error", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(0, result.buckets.download.deleted_files)
        end)

        it("skips dot-prefixed files and directories", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/.hidden"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/.hidden_dir"] = { mode = "directory" },
                ["/data/test/download/.hidden_dir/inside.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
                ["/data/test/download/visible.txt"] = { mode = "file", modification = mock_time - 300, size = 300 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            -- Only visible.txt is counted; .hidden* entries are skipped
            -- 1 file with keep_count=1 -> 0 deleted
            assert.are.equal(0, result.buckets.download.deleted_files)
        end)

        it("handles missing base directory gracefully", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            -- Do NOT set up /data/test/download in filesystem

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(0, result.buckets.download.scanned_dirs)
        end)

        it("no rule matches directory -> traverses but does not clean", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [{"path": "/specific", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/other"] = { mode = "directory" },
                ["/data/test/download/other/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/other/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            -- "download/other" does NOT match "download/specific" prefix
            -- No rule applies, so nothing is cleaned
            assert.are.equal(0, result.buckets.download.deleted_files)
            -- But directories are still scanned
            assert.are.equal(2, result.buckets.download.scanned_dirs)
        end)

        it("handles multiple rules with different paths in same bucket", function()
            mock_config_files["/data/config/test.json"] = [[
            {
                "download": { "rules": [
                    {"path": "/a", "keep_count": 2},
                    {"path": "/b", "keep_days": 1}
                ]}
            }
            ]]
            local one_day = 86400
            setup_filesystem({
                ["/data/test/download"] = { mode = "directory" },
                ["/data/test/download/a"] = { mode = "directory" },
                ["/data/test/download/b"] = { mode = "directory" },
                -- download/a: 3 files, keep 2 -> 1 deleted
                ["/data/test/download/a/f1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/test/download/a/f2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
                ["/data/test/download/a/f3.txt"] = { mode = "file", modification = mock_time - 300, size = 300 },
                -- download/b: 2 files, keep_days=1
                ["/data/test/download/b/f1.txt"] = { mode = "file", modification = mock_time - 100, size = 50 },
                ["/data/test/download/b/f2.txt"] = { mode = "file", modification = mock_time - one_day - 1, size = 60 },
            })

            local result = housekeeping.run("/data/config/test.json", "/data/test/")
            assert.is_true(result.ok)
            assert.are.equal(2, result.buckets.download.deleted_files) -- 1 from a + 1 from b
        end)

    end)

    -- ========================================================================
    -- Empty lists reach the wire as [], not {}
    -- ========================================================================
    -- cjson renders an empty Lua table as {}, and once decoded [] and {} are the
    -- same empty table — so these assert on the text that was written. Decoding
    -- first would make both shapes look identical.
    describe("encode_result()", function()

        local cjson = require("cjson.safe")

        local function assert_no_empty_object(text, what)
            for _, key in ipairs({ "files", "errors" }) do
                assert.is_true(text:find('"' .. key .. '":{}', 1, true) == nil,
                    what .. " spelled an empty " .. key .. " as {}: " .. text)
            end
        end

        it("spells a bucket's empty files and errors lists as []", function()
            local text = housekeeping.encode_result({
                ok = true,
                dry_run = true,
                buckets = {
                    download = {
                        scanned_dirs = 1,
                        cleaned_dirs = 0,
                        deleted_files = 0,
                        freed_bytes = 0,
                        files = {},
                        errors = {},
                    },
                },
            })

            assert_no_empty_object(text, "the bucket result")
            assert.is_true(text:find('"files":[]', 1, true) ~= nil, "no files array in: " .. text)
            assert.is_true(text:find('"errors":[]', 1, true) ~= nil, "no errors array in: " .. text)
        end)

        it("spells the top-level empty files list as []", function()
            local text = housekeeping.encode_result({ ok = true, dry_run = true, buckets = {}, files = {} })

            assert.is_true(text:find('"files":[]', 1, true) ~= nil, "no files array in: " .. text)
        end)

        it("omits files when there is none, as cjson did", function()
            local text = housekeeping.encode_result({ ok = true, dry_run = true, buckets = {} })

            assert.is_true(text:find('"files"', 1, true) == nil, "unexpected files key in: " .. text)
        end)

        it("keeps populated lists and scalars with the shape unchanged", function()
            local text = housekeeping.encode_result({
                ok = true,
                dry_run = false,
                buckets = {
                    download = {
                        scanned_dirs = 2,
                        cleaned_dirs = 1,
                        deleted_files = 1,
                        freed_bytes = 42,
                        errors = { "boom" },
                        files = { { path = "/data/download/a.txt", size = 42, mod_time = 1000 } },
                    },
                },
            })

            local decoded = cjson.decode(text)
            assert.is_true(decoded.ok)
            assert.are.equal(false, decoded.dry_run)
            assert.are.equal(2, decoded.buckets.download.scanned_dirs)
            assert.are.equal(42, decoded.buckets.download.freed_bytes)
            assert.are.equal("boom", decoded.buckets.download.errors[1])
            assert.are.equal("/data/download/a.txt", decoded.buckets.download.files[1].path)
            assert.are.equal(42, decoded.buckets.download.files[1].size)
        end)

        it("keeps an error result as it is", function()
            local text = housekeeping.encode_result({ ok = false, error = "config read error: boom" })

            local decoded = cjson.decode(text)
            assert.are.equal(false, decoded.ok)
            assert.are.equal("config read error: boom", decoded.error)
        end)
    end)

    -- ========================================================================
    -- handle_request
    -- ========================================================================
    describe("handle_request()", function()

        local say_output

        before_each(function()
            say_output = nil
            ngx_mock.say = function(s) say_output = s end
            ngx_mock.req.get_body_data = function() return nil end
            ngx_mock.var.url_prefix = "/"
        end)

        it("sets content-type header to application/json", function()
            mock_config_files["/data/config/housekeeping.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/download"] = { mode = "directory" },
            })

            housekeeping.handle_request()

            assert.are.equal("application/json", ngx_mock.header.content_type)
        end)

        it("returns HTTP 500 status when run encounters an error", function()
            -- No mock config file -> io.open returns nil -> run returns error
            housekeeping.handle_request()

            assert.are.equal(ngx.HTTP_INTERNAL_SERVER_ERROR, ngx_mock.status)
        end)

        it("outputs valid JSON from run result", function()
            mock_config_files["/data/config/housekeeping.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/download"] = { mode = "directory" },
            })

            housekeeping.handle_request()

            assert.is_not_nil(say_output)
            local cjson = require("cjson")
            local decoded = cjson.decode(say_output)
            assert.is_true(decoded.ok)
            assert.is_not_nil(decoded.buckets.download)
        end)

        it("spells an empty files list as [] in the response", function()
            mock_config_files["/data/config/housekeeping.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/download"] = { mode = "directory" },
            })

            housekeeping.handle_request()

            assert.is_not_nil(say_output)
            assert.is_true(say_output:find('"files":[]', 1, true) ~= nil,
                "the run response spelled an empty files list as {}: " .. tostring(say_output))
            assert.is_true(say_output:find('"errors":[]', 1, true) ~= nil,
                "the run response spelled an empty errors list as {}: " .. tostring(say_output))
        end)

        it("parses JSON body for opts and applies dry_run and bucket filter", function()
            ngx_mock.req.get_body_data = function()
                return '{"dry_run":true,"bucket":"download"}'
            end

            mock_config_files["/data/config/housekeeping.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 1}] },
                "public": { "rules": [{"path": "/", "keep_count": 1}] }
            }
            ]]
            setup_filesystem({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
                ["/data/download/file2.txt"] = { mode = "file", modification = mock_time - 200, size = 200 },
                ["/data/public"] = { mode = "directory" },
                ["/data/public/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 50 },
            })

            housekeeping.handle_request()

            assert.is_not_nil(say_output)
            local cjson = require("cjson")
            local decoded = cjson.decode(say_output)
            -- dry_run passed through correctly
            assert.is_true(decoded.dry_run)
            -- bucket filter applied: only download processed
            assert.is_not_nil(decoded.buckets.download)
            assert.is_nil(decoded.buckets.public)
            -- No actual removals (dry_run=true)
            assert.are.equal(0, #removed_files)
        end)

        it("handles invalid JSON body gracefully (ignores it)", function()
            ngx_mock.req.get_body_data = function()
                return "not valid json"
            end

            mock_config_files["/data/config/housekeeping.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/download"] = { mode = "directory" },
            })

            -- Should not error; invalid JSON body is silently ignored
            housekeeping.handle_request()

            assert.is_not_nil(say_output)
            local cjson = require("cjson")
            local decoded = cjson.decode(say_output)
            assert.is_true(decoded.ok)
        end)

        it("uses url_prefix to construct base_path", function()
            ngx_mock.var.url_prefix = "/myteam/"

            mock_config_files["/data/config/housekeeping.json"] = [[
            {
                "download": { "rules": [{"path": "/", "keep_count": 5}] }
            }
            ]]
            setup_filesystem({
                ["/data/myteam/download"] = { mode = "directory" },
                ["/data/myteam/download/file1.txt"] = { mode = "file", modification = mock_time - 100, size = 100 },
            })

            housekeeping.handle_request()

            assert.is_not_nil(say_output)
            local cjson = require("cjson")
            local decoded = cjson.decode(say_output)
            assert.is_true(decoded.ok)
            -- The correct base_path was used, so the bucket was found and scanned
            assert.is_not_nil(decoded.buckets.download)
            assert.are.equal(1, decoded.buckets.download.scanned_dirs)
        end)

    end)

    -- ========================================================================
    -- File tracking (collect_files)
    -- ========================================================================
    describe("file tracking", function()
        it("returns file details when collect_files is true", function()
            local cjson = require("cjson.safe")
            local config = cjson.encode({
                download = {
                    rules = {{path = "/", keep_count = 0, keep_days = 1}}
                }
            })
            mock_config_files["/data/config/housekeeping.json"] = config
            setup_filesystem({
                ["/data/download"] = {mode = "directory", modification = mock_time - 100000, size = 0},
                ["/data/download/old.zip"] = {mode = "file", modification = mock_time - 200000, size = 1024},
                ["/data/download/new.zip"] = {mode = "file", modification = mock_time - 100, size = 2048}
            })
            removed_files = {}
            mock_time = 1000000000

            local result = housekeeping.run("/data/config/housekeeping.json", "/data/", {
                dry_run = true,
                bucket = "download",
                collect_files = true
            })

            assert.equals(1, result.buckets.download.deleted_files)
            assert.is_table(result.buckets.download.files)
            local deleted = result.buckets.download.files[1]
            assert.equals("old.zip", deleted.name)
            assert.equals("/old.zip", deleted.path)
            assert.equals(1024, deleted.size)
        end)

        it("does not include files when collect_files is false", function()
            local cjson = require("cjson.safe")
            local config = cjson.encode({
                download = {
                    rules = {{path = "/", keep_count = 0, keep_days = 1}}
                }
            })
            mock_config_files["/data/config/housekeeping.json"] = config
            setup_filesystem({
                ["/data/download"] = {mode = "directory", modification = mock_time - 100000, size = 0},
                ["/data/download/old.zip"] = {mode = "file", modification = mock_time - 200000, size = 1024}
            })
            removed_files = {}
            mock_time = 1000000000

            local result = housekeeping.run("/data/config/housekeeping.json", "/data/", {
                dry_run = true,
                bucket = "download",
                collect_files = false
            })

            assert.equals(1, result.buckets.download.deleted_files)
            assert.is_nil(result.buckets.download.files)
        end)
    end)
end)
