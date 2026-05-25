-- Tests for housekeeping-admin.lua
--
-- Test framework: busted (https://olivinelabs.com/busted/)
-- Run with:
--   LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/housekeeping-admin_spec.lua

local ngx_mock = require("mock_ngx")
_G.ngx = ngx_mock

-- Mock os.getenv
os.getenv = function(k)
    if k == "ADMIN_GROUP" then return "/admin" end
    if k == "DATA_ROOT" then return "/data" end
    return nil
end

-- Mock filesystem for io.open and os.rename
local mock_files = {}
local original_io_open = io.open
io.open = function(path, mode)
    if mock_files[path] ~= nil then
        return { read = function(self, fmt) return mock_files[path] end, close = function(self) end }
    end
    if path:match("%.tmp$") then
        mock_files[path] = ""
        return { write = function(self, data) mock_files[path] = mock_files[path] .. data; return true end, flush = function(self) end, close = function(self) return true end }
    end
    return original_io_open(path, mode)
end

local original_os_rename = os.rename
os.rename = function(src, dst)
    mock_files[dst] = mock_files[src]
    mock_files[src] = nil
    return true
end

-- Mock filesystem for lfs operations (mutable per-test)
local mock_fs_entries = {}  -- path -> {name, name, ...} (directories only)
local mock_fs_attrs = {}    -- path -> {mode = "...", ...}

local function setup_mock_fs(entries)
    mock_fs_entries = {}
    mock_fs_attrs = {}
    for path, attr in pairs(entries) do
        mock_fs_attrs[path] = attr
        local parent, name = path:match("^(.*)/([^/]+)$")
        if parent then
            if not mock_fs_entries[parent] then
                mock_fs_entries[parent] = {}
            end
            table.insert(mock_fs_entries[parent], name)
        end
    end
end

local function clear_mock_fs()
    mock_fs_entries = {}
    mock_fs_attrs = {}
end

-- Mock lfs with dynamic entries
package.loaded["lfs"] = {
    dir = function(path)
        local entries = mock_fs_entries[path] or {}
        local i = 0
        return function()
            i = i + 1
            return entries[i]
        end
    end,
    attributes = function(path)
        return mock_fs_attrs[path]
    end,
    symlinkattributes = function(path)
        return mock_fs_attrs[path]
    end
}

-- Mock housekeeping module
package.loaded["housekeeping"] = {
    run = function(config_path, base_path, opts)
        return { ok = true, dry_run = true, buckets = {} }
    end
}

-- Helpers
local function set_config(content)
    mock_files[((os.getenv("DATA_ROOT") or "/data")) .. "/config/housekeeping.json"] = content
end
local function set_page(content)
    -- page is served relative to base_path (data_root .. url_prefix)
    -- default url_prefix is "/", so the path is /data/fileserver/housekeeping.html
    mock_files["/data/fileserver/housekeeping.html"] = content
end
local function set_method(m) ngx_mock.req.get_method = function() return m end end
local function set_uri(u) ngx_mock.var.uri = u; ngx_mock.var.url_prefix = "/" end
local function set_url_prefix(p) ngx_mock.var.url_prefix = p end
local function set_groups(g) ngx_mock.req.get_headers = function() return {["X-USER-GROUPS"] = g} end end
local function set_body(b) ngx_mock.req.get_body_data = function() return b end end
local function set_uri_args(args)
    ngx_mock.req.get_uri_args = function() return args end
end

-- Setup ngx_mock capture
ngx_mock.say = function(val) ngx_mock._last_say = val end
ngx_mock.exit = function(code) ngx_mock.status = code; ngx_mock._exited = true end
ngx_mock.req.read_body = function() end
ngx_mock.req.get_uri_args = function() return {} end

-- ============================================================================
-- Tests
-- ============================================================================

describe("housekeeping-admin module", function()
    before_each(function()
        package.loaded["housekeeping-admin"] = nil
        mock_files = {}
        clear_mock_fs()
        ngx_mock._last_say = nil
        ngx_mock._exited = false
        ngx_mock.header = {}
        ngx_mock.status = ngx_mock.HTTP_OK
        set_uri("/fileserver/housekeeping/config")
        set_method("GET")
        set_groups("/admin")
        set_body(nil)
        set_url_prefix("/")
        set_uri_args({})
    end)

    -- ========================================================================
    -- Auth tests
    -- ========================================================================
    describe("authentication", function()

        it("returns 403 when no X-USER-GROUPS header", function()
            set_groups(nil)
            require("housekeeping-admin")
            assert.are.equal(ngx.HTTP_FORBIDDEN, ngx_mock.status)
        end)

        it("returns 403 when user not in admin group", function()
            set_groups("/regular,/other")
            require("housekeeping-admin")
            assert.are.equal(ngx.HTTP_FORBIDDEN, ngx_mock.status)
        end)

        it("allows admin group user", function()
            set_groups("/admin")
            set_uri("/fileserver/housekeeping/config")
            set_method("GET")
            require("housekeeping-admin")
            -- Admin user should not get 403
            assert.are_not.equal(ngx.HTTP_FORBIDDEN, ngx_mock.status)
        end)

    end)

    -- ========================================================================
    -- GET /config
    -- ========================================================================
    describe("GET /config", function()

        it("returns config with version", function()
            local cjson = require("cjson.safe")
            set_config('{"download":{"rules":[{"path":"/","keep_count":5,"keep_days":0}]},"version":3}')
            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.is_not_nil(result)
            assert.are.equal(3, result.version)
            assert.is_not_nil(result.download)
        end)

        it("adds version 1 if missing", function()
            local cjson = require("cjson.safe")
            set_config('{"download":{"rules":[{"path":"/","keep_count":2,"keep_days":7}]}}')
            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.is_not_nil(result)
            assert.are.equal(1, result.version)
        end)

        it("returns default config with version 1 when file does not exist", function()
            local cjson = require("cjson.safe")
            -- No config file set up
            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.is_not_nil(result)
            assert.are.equal(1, result.version)
        end)

    end)

    -- ========================================================================
    -- POST /config
    -- ========================================================================
    describe("POST /config", function()

        it("saves config and increments version", function()
            local cjson = require("cjson.safe")
            set_method("POST")
            set_config('{"download":{"rules":[]},"version":1}')
            set_body('{"download":{"rules":[{"path":"/","keep_count":3,"keep_days":10}]},"version":1}')

            require("housekeeping-admin")

            -- Should have saved the new config with incremented version
            local saved = mock_files["/data/config/housekeeping.json"]
            assert.is_not_nil(saved)
            local decoded = cjson.decode(saved)
            assert.are.equal(2, decoded.version)
            assert.are.equal("/", decoded.download.rules[1].path)

            -- Response should contain the new config
            local result = cjson.decode(ngx_mock._last_say)
            assert.is_not_nil(result)
            assert.are.equal(2, result.version)
        end)

        it("returns 409 on version conflict", function()
            local cjson = require("cjson.safe")
            set_method("POST")
            set_config('{"download":{"rules":[]},"version":5}')
            set_body('{"download":{"rules":[{"path":"/","keep_count":3,"keep_days":10}]},"version":1}')

            require("housekeeping-admin")

            assert.are.equal(ngx.HTTP_CONFLICT, ngx_mock.status)
        end)

        it("rejects invalid config (rule missing keep_count)", function()
            local cjson = require("cjson.safe")
            set_method("POST")
            set_config('{"version":1}')
            set_body('{"download":{"rules":[{"path":"/","keep_days":10}]},"version":1}')

            require("housekeeping-admin")

            -- Should reject: rule is missing keep_count
            assert.are.equal(ngx.HTTP_BAD_REQUEST, ngx_mock.status)
        end)

    end)

    -- ========================================================================
    -- GET / (page serving)
    -- ========================================================================
    describe("GET / (page serving)", function()

        it("serves HTML page", function()
            set_uri("/fileserver/housekeeping")
            set_method("GET")
            set_page("<html>Housekeeping Admin</html>")

            require("housekeeping-admin")

            assert.are.equal("text/html", ngx_mock.header["Content-Type"])
            assert.are.equal("<html>Housekeeping Admin</html>", ngx_mock._last_say)
        end)

        it("returns 404 when page file missing", function()
            set_uri("/fileserver/housekeeping")
            set_method("GET")
            -- No page file set up

            require("housekeeping-admin")

            assert.are.equal(ngx.HTTP_NOT_FOUND, ngx_mock.status)
        end)

    end)

    -- ========================================================================
    -- GET /dirs — tree directory listing
    -- ========================================================================
    describe("GET /dirs", function()

        it("lists subdirectories with inherited rule from root '/'", function()
            local cjson = require("cjson.safe")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/" })
            set_config('{"download":{"rules":[{"path":"/","keep_count":50,"keep_days":0}]}}')
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/releases"] = { mode = "directory" },
                ["/data/download/backups"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.is_not_nil(result)
            assert.are.equal(2, #result)

            -- Both entries should have an effective_rule inherited from "/"
            for _, entry in ipairs(result) do
                assert.is_false(entry.has_rule)
                assert.is_not_nil(entry.effective_rule)
                assert.are.equal(50, entry.effective_rule.keep_count)
                assert.are.equal(0, entry.effective_rule.keep_days)
                assert.are.equal("/", entry.effective_rule.source)
            end
        end)

        it("detects explicit rule match at exact path", function()
            local cjson = require("cjson.safe")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/" })
            set_config('{"download":{"rules":[{"path":"/releases","keep_count":10,"keep_days":30},{"path":"/","keep_count":50,"keep_days":0}]}}')
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/releases"] = { mode = "directory" },
                ["/data/download/backups"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            -- Find the releases entry
            local releases_entry = nil
            local backups_entry = nil
            for _, entry in ipairs(result) do
                if entry.name == "releases" then releases_entry = entry end
                if entry.name == "backups" then backups_entry = entry end
            end

            assert.is_not_nil(releases_entry)
            assert.is_true(releases_entry.has_rule)
            assert.is_not_nil(releases_entry.rule)
            assert.are.equal(10, releases_entry.rule.keep_count)
            assert.are.equal(30, releases_entry.rule.keep_days)
            -- effective_rule should be the explicit rule (same values)
            assert.is_not_nil(releases_entry.effective_rule)
            assert.are.equal("/releases", releases_entry.effective_rule.source)

            -- backups should still inherit from "/"
            assert.is_not_nil(backups_entry)
            assert.is_false(backups_entry.has_rule)
            assert.is_not_nil(backups_entry.effective_rule)
            assert.are.equal("/", backups_entry.effective_rule.source)
            assert.are.equal(50, backups_entry.effective_rule.keep_count)
        end)

        it("most-specific rule wins (longest prefix match)", function()
            local cjson = require("cjson.safe")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/releases" })
            set_config('{"download":{"rules":[{"path":"/releases/v1","keep_count":5,"keep_days":7},{"path":"/releases","keep_count":10,"keep_days":30},{"path":"/","keep_count":50,"keep_days":0}]}}')
            setup_mock_fs({
                ["/data/download/releases"] = { mode = "directory" },
                ["/data/download/releases/v1"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(1, #result)
            local v1_entry = result[1]
            assert.are.equal("v1", v1_entry.name)
            -- Should match /releases/v1, not /releases or /
            assert.is_not_nil(v1_entry.effective_rule)
            assert.are.equal("/releases/v1", v1_entry.effective_rule.source)
            assert.are.equal(5, v1_entry.effective_rule.keep_count)
            assert.are.equal(7, v1_entry.effective_rule.keep_days)
        end)

        it("returns has_rule=false for directory with no rule and no inherited rule", function()
            local cjson = require("cjson.safe")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/" })
            -- No rules configured for download bucket
            set_config('{"download":{"rules":[]}}')
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/releases"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(1, #result)
            assert.is_false(result[1].has_rule)
            assert.is_nil(result[1].rule)
            assert.is_nil(result[1].effective_rule)
        end)

        it("correctly sets has_children for subdirectories", function()
            local cjson = require("cjson.safe")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/" })
            set_config('{"download":{"rules":[]}}')
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/releases"] = { mode = "directory" },
                ["/data/download/releases/v1"] = { mode = "directory" },
                ["/data/download/empty_dir"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            for _, entry in ipairs(result) do
                if entry.name == "releases" then
                    assert.is_true(entry.has_children)
                elseif entry.name == "empty_dir" then
                    assert.is_false(entry.has_children)
                end
            end
        end)

        it("returns empty array for non-existent directory", function()
            local cjson = require("cjson.safe")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/nonexistent" })
            set_config('{"download":{"rules":[]}}')
            -- No filesystem entry for /data/download/nonexistent
            setup_mock_fs({})

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.is_not_nil(result)
            assert.are.equal(0, #result)
        end)

        it("rejects path traversal attempts", function()
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/../../etc" })
            set_config('{"download":{"rules":[]}}')

            require("housekeeping-admin")
            assert.are.equal(ngx.HTTP_BAD_REQUEST, ngx_mock.status)
        end)

        it("rejects invalid bucket", function()
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "hacked", path = "/" })

            require("housekeeping-admin")
            assert.are.equal(ngx.HTTP_BAD_REQUEST, ngx_mock.status)
        end)

        -- NOTE: cannot test missing bucket param because mock ngx.exit
        -- does not halt execution, and nil bucket crashes fs_path construction
    end)

    -- ========================================================================
    -- GET /dirs — URL_PREFIX variations
    -- ========================================================================
    describe("GET /dirs with URL_PREFIX variations", function()

        it("works correctly with URL_PREFIX=/", function()
            local cjson = require("cjson.safe")
            set_url_prefix("/")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/" })
            set_config('{"download":{"rules":[{"path":"/","keep_count":50,"keep_days":0},{"path":"/releases","keep_count":10,"keep_days":30}]}}')
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/releases"] = { mode = "directory" },
                ["/data/download/backups"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(2, #result)

            local releases_entry = nil
            local backups_entry = nil
            for _, entry in ipairs(result) do
                if entry.name == "releases" then releases_entry = entry end
                if entry.name == "backups" then backups_entry = entry end
            end

            -- releases has explicit rule
            assert.is_not_nil(releases_entry)
            assert.is_true(releases_entry.has_rule)
            assert.are.equal(10, releases_entry.rule.keep_count)

            -- backups inherits from "/"
            assert.is_not_nil(backups_entry)
            assert.is_false(backups_entry.has_rule)
            assert.is_not_nil(backups_entry.effective_rule)
            assert.are.equal("/", backups_entry.effective_rule.source)
            assert.are.equal(50, backups_entry.effective_rule.keep_count)
        end)

        it("works correctly with URL_PREFIX=/myteam/", function()
            local cjson = require("cjson.safe")
            set_uri("/myteam/fileserver/housekeeping/dirs")
            set_url_prefix("/myteam/")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/" })
            set_config('{"download":{"rules":[{"path":"/","keep_count":30,"keep_days":7},{"path":"/releases","keep_count":5,"keep_days":14}]}}')
            setup_mock_fs({
                ["/data/myteam/download"] = { mode = "directory" },
                ["/data/myteam/download/releases"] = { mode = "directory" },
                ["/data/myteam/download/backups"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(2, #result)

            local releases_entry = nil
            local backups_entry = nil
            for _, entry in ipairs(result) do
                if entry.name == "releases" then releases_entry = entry end
                if entry.name == "backups" then backups_entry = entry end
            end

            -- releases has explicit rule
            assert.is_not_nil(releases_entry)
            assert.is_true(releases_entry.has_rule)
            assert.are.equal(5, releases_entry.rule.keep_count)
            assert.are.equal(14, releases_entry.rule.keep_days)

            -- backups inherits from "/"
            assert.is_not_nil(backups_entry)
            assert.is_false(backups_entry.has_rule)
            assert.is_not_nil(backups_entry.effective_rule)
            assert.are.equal("/", backups_entry.effective_rule.source)
            assert.are.equal(30, backups_entry.effective_rule.keep_count)
        end)

        it("lists subdirectories at a nested path with URL_PREFIX=/", function()
            local cjson = require("cjson.safe")
            set_url_prefix("/")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "download", path = "/releases" })
            set_config('{"download":{"rules":[{"path":"/releases","keep_count":10,"keep_days":30},{"path":"/","keep_count":50,"keep_days":0}]}}')
            setup_mock_fs({
                ["/data/download/releases"] = { mode = "directory" },
                ["/data/download/releases/v1.0"] = { mode = "directory" },
                ["/data/download/releases/v2.0"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(2, #result)

            -- Both should inherit from /releases
            for _, entry in ipairs(result) do
                assert.is_false(entry.has_rule)
                assert.is_not_nil(entry.effective_rule)
                assert.are.equal("/releases", entry.effective_rule.source)
                assert.are.equal(10, entry.effective_rule.keep_count)
            end
        end)

        it("lists subdirectories at a nested path with URL_PREFIX=/myteam/", function()
            local cjson = require("cjson.safe")
            set_uri("/myteam/fileserver/housekeeping/dirs")
            set_url_prefix("/myteam/")
            set_method("GET")
            set_uri_args({ bucket = "archive", path = "/builds" })
            set_config('{"archive":{"rules":[{"path":"/builds","keep_count":3,"keep_days":90}]}}')
            setup_mock_fs({
                ["/data/myteam/archive/builds"] = { mode = "directory" },
                ["/data/myteam/archive/builds/2024"] = { mode = "directory" },
            })

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(1, #result)
            assert.are.equal("2024", result[1].name)
            assert.is_false(result[1].has_rule)
            assert.is_not_nil(result[1].effective_rule)
            assert.are.equal("/builds", result[1].effective_rule.source)
            assert.are.equal(3, result[1].effective_rule.keep_count)
            assert.are.equal(90, result[1].effective_rule.keep_days)
        end)

        it("returns empty array for non-existent bucket path with URL_PREFIX=/", function()
            local cjson = require("cjson.safe")
            set_url_prefix("/")
            set_uri("/fileserver/housekeeping/dirs")
            set_method("GET")
            set_uri_args({ bucket = "public", path = "/" })
            set_config('{"public":{"rules":[]}}')
            -- No /data/public directory set up
            setup_mock_fs({})

            require("housekeeping-admin")

            local result = cjson.decode(ngx_mock._last_say)
            assert.are.equal(0, #result)
        end)
    end)

    -- ========================================================================
    -- Page serving with URL_PREFIX variations
    -- ========================================================================
    describe("page serving with URL_PREFIX variations", function()

        it("serves page with URL_PREFIX=/", function()
            set_url_prefix("/")
            set_uri("/fileserver/housekeeping")
            set_method("GET")
            mock_files["/data/fileserver/housekeeping.html"] = "<html>HK Admin</html>"

            require("housekeeping-admin")

            assert.are.equal("text/html", ngx_mock.header["Content-Type"])
            assert.are.equal("<html>HK Admin</html>", ngx_mock._last_say)
        end)

        it("serves page with URL_PREFIX=/myteam/", function()
            set_uri("/myteam/fileserver/housekeeping")
            set_url_prefix("/myteam/")
            set_method("GET")
            mock_files["/data/myteam/fileserver/housekeeping.html"] = "<html>HK Admin /myteam</html>"

            require("housekeeping-admin")

            assert.are.equal("text/html", ngx_mock.header["Content-Type"])
            assert.are.equal("<html>HK Admin /myteam</html>", ngx_mock._last_say)
        end)

        it("returns 404 when page missing with URL_PREFIX=/", function()
            set_url_prefix("/")
            set_uri("/fileserver/housekeeping")
            set_method("GET")
            -- No page file at /data/fileserver/housekeeping.html

            require("housekeeping-admin")
            assert.are.equal(ngx.HTTP_NOT_FOUND, ngx_mock.status)
        end)

        it("returns 404 when page missing with URL_PREFIX=/myteam/", function()
            set_uri("/myteam/fileserver/housekeeping")
            set_url_prefix("/myteam/")
            set_method("GET")
            -- No page file at /data/myteam/fileserver/housekeeping.html

            require("housekeeping-admin")
            assert.are.equal(ngx.HTTP_NOT_FOUND, ngx_mock.status)
        end)
    end)
end)
