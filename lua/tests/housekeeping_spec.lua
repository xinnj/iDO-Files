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
end)
