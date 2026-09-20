-- Tests for auth-config.lua
--
-- Run with:
--   LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/auth-config_spec.lua
--
-- The module runs its handler at load time, so every test installs its mocks,
-- clears package.loaded, and only then requires it.

local cjson = require("cjson.safe")
local ngx_mock = require("mock_ngx")
_G.ngx = ngx_mock

local real_getenv = os.getenv
os.getenv = function(k)
    if k == "ADMIN_GROUP" then return "fileserver_admin" end
    if k == "DATA_ROOT" then return "/data" end
    return nil
end

local CONFIG_PATH = "/data/config/auth_config.json"
local TMP_PATH = CONFIG_PATH .. ".tmp"

-- ------------------------------------------------------------------ filesystem

-- Only the config file and its staging file are intercepted; everything else
-- falls through, so busted and luarocks can still read their own files.
local mock_files = {}
local real_io_open = io.open
local real_os_rename = os.rename
local real_os_remove = os.remove

local function is_mocked_path(path)
    return path == CONFIG_PATH or path == TMP_PATH
end

io.open = function(path, mode)
    if not is_mocked_path(path) then
        return real_io_open(path, mode)
    end

    if mode == "r" then
        if mock_files[path] ~= nil then
            return {
                read = function() return mock_files[path] end,
                close = function() end,
            }
        end
        return nil, "no such file"
    end

    mock_files[path] = ""
    return {
        write = function(_, data) mock_files[path] = mock_files[path] .. data; return true end,
        flush = function() end,
        close = function() return true end,
    }
end

os.rename = function(src, dst)
    if not is_mocked_path(src) then
        return real_os_rename(src, dst)
    end
    if mock_files[src] == nil then
        return nil, "no such file"
    end
    mock_files[dst] = mock_files[src]
    mock_files[src] = nil
    return true
end

os.remove = function(path)
    if not is_mocked_path(path) then
        return real_os_remove(path)
    end
    mock_files[path] = nil
    return true
end

-- ------------------------------------------------------------------ lfs

local mock_fs_entries = {}
local mock_fs_attrs = {}

local function setup_mock_fs(entries)
    mock_fs_entries = {}
    mock_fs_attrs = {}
    for path, attr in pairs(entries) do
        mock_fs_attrs[path] = attr
        local parent, name = path:match("^(.*)/([^/]+)$")
        if parent then
            mock_fs_entries[parent] = mock_fs_entries[parent] or {}
            table.insert(mock_fs_entries[parent], name)
        end
    end
end

package.loaded["lfs"] = {
    dir = function(path)
        local entries = mock_fs_entries[path] or {}
        local i = 0
        return function()
            i = i + 1
            return entries[i]
        end
    end,
    attributes = function(path) return mock_fs_attrs[path] end,
    symlinkattributes = function(path) return mock_fs_attrs[path] end,
}

-- ------------------------------------------------------------------ redis / keycloak

local redis_sync = {}

package.loaded["authorize"] = {
    save_config_to_redis = function(rules)
        redis_sync.calls = (redis_sync.calls or 0) + 1
        redis_sync.last_rules = rules
        return redis_sync.ok, redis_sync.err
    end,
}

-- ------------------------------------------------------------------ ngx captures

local function set_method(m) ngx_mock.req.get_method = function() return m end end
local function set_uri(u) ngx_mock.var.uri = u end
local function set_url_prefix(p) ngx_mock.var.url_prefix = p end
local function set_groups(g) ngx_mock.req.get_headers = function() return { ["X-USER-GROUPS"] = g } end end
local function set_body(b) ngx_mock.req.get_body_data = function() return b end end
-- ngx.req.get_uri_args percent-decodes its values, so the mock does too —
-- otherwise a test for an encoded traversal would exercise nothing.
local function url_decode(value)
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function set_uri_args(args)
    local decoded = {}
    for key, value in pairs(args) do
        decoded[key] = type(value) == "string" and url_decode(value) or value
    end
    ngx_mock.req.get_uri_args = function() return decoded end
end

ngx_mock.say = function(val) ngx_mock._last_say = val end
ngx_mock.exit = function(code) ngx_mock.status = code; return code end
ngx_mock.req.read_body = function() end
ngx_mock.HTTP_METHOD_NOT_ALLOWED = 405

local function run()
    package.loaded["auth-config"] = nil
    package.loaded["dir-listing"] = nil
    require("auth-config")
end

local function last_json()
    return cjson.decode(ngx_mock._last_say)
end

local function set_config(content) mock_files[CONFIG_PATH] = content end

local SEED_CONFIG = cjson.encode({
    version = 1,
    rules = {
        [".default"] = { allow = {}, deny = {} },
        fileserver_admin = {
            allow = { "all:/download", "all:/archive", "all:/public" },
            deny = {},
        },
    },
})

-- ------------------------------------------------------------------ setup

describe("auth-config", function()
    before_each(function()
        mock_files = {}
        set_config(SEED_CONFIG)
        setup_mock_fs({
            ["/data/download"] = { mode = "directory" },
            ["/data/download/documents"] = { mode = "directory" },
            ["/data/download/code"] = { mode = "directory" },
            ["/data/public"] = { mode = "directory" },
            ["/data/archive"] = { mode = "directory" },
        })
        redis_sync = { ok = true, err = nil, calls = 0 }
        package.loaded["keycloak"] = nil
        set_uri("/fileserver/auth-config")
        set_url_prefix("/")
        set_method("GET")
        set_groups("fileserver_admin")
        set_body(nil)
        set_uri_args({})
        ngx_mock._last_say = nil
        ngx_mock.status = 200
        ngx_mock.header = {}
        os.getenv = function(k)
            if k == "ADMIN_GROUP" then return "fileserver_admin" end
            if k == "DATA_ROOT" then return "/data" end
            return nil
        end
    end)

    after_each(function()
        os.getenv = real_getenv
    end)

    describe("authorization", function()
        it("rejects a request with no group header", function()
            set_groups(nil)
            run()
            assert.are.equal(403, ngx_mock.status)
        end)

        it("rejects a request from a non-admin role", function()
            set_groups("guest, team-a")
            run()
            assert.are.equal(403, ngx_mock.status)
        end)

        it("allows a request from the admin role", function()
            run()
            assert.are_not.equal(403, ngx_mock.status)
            assert.is_not_nil(last_json())
        end)
    end)

    describe("GET /auth-config", function()
        it("returns the config as stored", function()
            run()
            local body = last_json()
            assert.are.equal(1, body.version)
            assert.is_not_nil(body.rules["fileserver_admin"])
        end)

        it("keeps empty allow and deny lists as arrays on the wire", function()
            set_config(cjson.encode({
                version = 1,
                rules = { guest = { allow = {}, deny = {} } },
            }))
            run()

            -- cjson would otherwise render these as {} and the page reads them
            -- as arrays.
            assert.is_truthy(ngx_mock._last_say:find('"allow":%[%]'))
            assert.is_truthy(ngx_mock._last_say:find('"deny":%[%]'))
        end)

        it("returns a JSON error, not an empty 200, when the file is corrupt", function()
            set_config("{ this is not json")
            run()

            assert.are.equal(500, ngx_mock.status)
            local body = last_json()
            assert.is_not_nil(body.error)
        end)

        it("returns a JSON error when the file is missing", function()
            mock_files[CONFIG_PATH] = nil
            run()

            assert.are.equal(500, ngx_mock.status)
            assert.is_not_nil(last_json().error)
        end)
    end)

    describe("routing", function()
        it("404s an unknown sub-path with a JSON body", function()
            set_uri("/fileserver/auth-configuration")
            run()

            assert.are.equal(404, ngx_mock.status)
            assert.is_not_nil(last_json().error)
        end)

        it("rejects POST to the read-only sub-routes", function()
            set_uri("/fileserver/auth-config/roles")
            set_method("POST")
            run()

            assert.are.equal(405, ngx_mock.status)
        end)

        it("rejects an unsupported method on the config route", function()
            set_method("DELETE")
            run()

            assert.are.equal(405, ngx_mock.status)
        end)
    end)

    describe("GET /auth-config/roles", function()
        before_each(function()
            set_uri("/fileserver/auth-config/roles")
        end)

        it("returns the role list when Keycloak answers", function()
            package.loaded["keycloak"] = {
                get_realm_roles = function() return { "auditors", "guest" }, "keycloak" end,
            }
            run()

            local body = last_json()
            assert.are.same({ "auditors", "guest" }, body.roles)
            assert.are.equal("keycloak", body.source)
            assert.is_false(body.degraded)
            assert.are.equal("fileserver_admin", body.admin_group)
        end)

        it("reports the cache as the source on a cache hit", function()
            package.loaded["keycloak"] = {
                get_realm_roles = function() return { "auditors" }, "cache" end,
            }
            run()

            assert.are.equal("cache", last_json().source)
            assert.is_false(last_json().degraded)
        end)

        it("degrades to an empty list rather than erroring when Keycloak is unavailable", function()
            package.loaded["keycloak"] = {
                get_realm_roles = function() return nil, "OIDC is not configured" end,
            }
            run()

            assert.are.equal(200, ngx_mock.status)
            local body = last_json()
            assert.are.same({}, body.roles)
            assert.are.equal("unavailable", body.source)
            assert.is_true(body.degraded)
            assert.are.equal("OIDC is not configured", body.error)

            -- On the wire it must be [] and not {}: cjson renders an empty Lua
            -- table as an object, and the page iterates this as an array.
            assert.is_truthy(ngx_mock._last_say:find('"roles":%[%]'))
        end)

        it("degrades when the keycloak module cannot be loaded", function()
            package.loaded["keycloak"] = nil
            run()

            assert.are.equal(200, ngx_mock.status)
            assert.are.equal("unavailable", last_json().source)
        end)

        it("passes the refresh flag through", function()
            local seen
            package.loaded["keycloak"] = {
                get_realm_roles = function(refresh) seen = refresh; return { "a" }, "keycloak" end,
            }
            set_uri_args({ refresh = "1" })
            run()

            assert.is_true(seen)
        end)
    end)

    describe("GET /auth-config/dirs", function()
        before_each(function()
            set_uri("/fileserver/auth-config/dirs")
        end)

        it("lists subdirectories sorted, with a ready-to-use rule path", function()
            set_uri_args({ path = "/download" })
            run()

            local body = last_json()
            assert.are.equal(2, #body)
            assert.are.equal("code", body[1].name)
            assert.are.equal("/download/code", body[1].path)
            assert.are.equal("documents", body[2].name)
            assert.are.equal("/download/documents", body[2].path)
        end)

        it("keeps the url prefix in the returned path", function()
            -- The filesystem lives under DATA_ROOT + url_prefix.
            set_url_prefix("/myteam/")
            setup_mock_fs({
                ["/data/myteam/download"] = { mode = "directory" },
                ["/data/myteam/download/docs"] = { mode = "directory" },
            })
            set_uri_args({ path = "/myteam/download" })
            run()

            local body = last_json()
            assert.are.equal(1, #body)
            assert.are.equal("/myteam/download/docs", body[1].path)
        end)

        it("reports has_children", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/parent"] = { mode = "directory" },
                ["/data/download/parent/child"] = { mode = "directory" },
                ["/data/download/leaf"] = { mode = "directory" },
            })
            set_uri_args({ path = "/download" })
            run()

            -- Sorted by name: leaf, then parent.
            local body = last_json()
            assert.are.equal("leaf", body[1].name)
            assert.is_false(body[1].has_children)
            assert.are.equal("parent", body[2].name)
            assert.is_true(body[2].has_children)
        end)

        it("lists non-ASCII directory names", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/测试目录"] = { mode = "directory" },
            })
            set_uri_args({ path = "/download" })
            run()

            assert.are.equal("测试目录", last_json()[1].name)
        end)

        it("returns an empty list for a directory that does not exist", function()
            set_uri_args({ path = "/download/nope" })
            run()

            assert.are.equal(200, ngx_mock.status)
            assert.are.same({}, last_json())
        end)

        it("rejects a missing path", function()
            set_uri_args({})
            run()

            assert.are.equal(400, ngx_mock.status)
            assert.is_not_nil(last_json().error)
        end)

        it("rejects an empty path", function()
            set_uri_args({ path = "" })
            run()

            assert.are.equal(400, ngx_mock.status)
        end)

        it("rejects a path outside the buckets", function()
            set_uri_args({ path = "/etc/passwd" })
            run()

            assert.are.equal(400, ngx_mock.status)
            assert.is_not_nil(last_json().error)
        end)

        it("rejects a path that escapes the url prefix", function()
            set_uri_args({ path = "/download/../etc" })
            run()

            assert.are.equal(400, ngx_mock.status)
        end)

        it("rejects a percent-encoded traversal", function()
            -- get_uri_args decodes %2e%2e to "..", which must still be caught.
            set_uri_args({ path = "/download/%2e%2e/secret" })
            run()

            assert.are.equal(400, ngx_mock.status)
        end)

        it("rejects a bucket outside the allow-list", function()
            set_uri_args({ path = "/internal-download" })
            run()

            assert.are.equal(400, ngx_mock.status)
        end)

        it("skips hidden directories", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/.hidden"] = { mode = "directory" },
                ["/data/download/visible"] = { mode = "directory" },
            })
            set_uri_args({ path = "/download" })
            run()

            local body = last_json()
            assert.are.equal(1, #body)
            assert.are.equal("visible", body[1].name)
        end)
    end)

    describe("POST /auth-config", function()
        local function post(payload)
            set_method("POST")
            set_body(cjson.encode(payload))
            run()
        end

        it("saves a valid config and returns the incremented version", function()
            post({
                version = 1,
                rules = { guest = { allow = { "read:/public" }, deny = { "write:/public/tmp" } } },
            })

            assert.are.equal(200, ngx_mock.status)
            local body = last_json()
            assert.are.equal(2, body.version)
            assert.are.same({ "read:/public" }, body.rules.guest.allow)
            assert.are.equal(1, redis_sync.calls)
            assert.are.same({ "read:/public" }, redis_sync.last_rules.guest.allow)
        end)

        it("rejects a version mismatch with a JSON 409", function()
            post({ version = 99, rules = { guest = { allow = {}, deny = {} } } })

            assert.are.equal(409, ngx_mock.status)
            assert.is_not_nil(last_json().error)
            assert.are.equal(0, redis_sync.calls)
        end)

        it("rejects a missing version", function()
            post({ rules = { guest = { allow = {}, deny = {} } } })

            assert.are.equal(400, ngx_mock.status)
        end)

        it("rejects a body that is not JSON", function()
            set_method("POST")
            set_body("not json at all")
            run()

            assert.are.equal(400, ngx_mock.status)
            assert.is_not_nil(last_json().error)
        end)

        describe("operation vocabulary", function()
            it("accepts read and all in allow", function()
                post({
                    version = 1,
                    rules = { g = { allow = { "read:/public", "all:/download" }, deny = {} } },
                })
                assert.are.equal(200, ngx_mock.status)
            end)

            it("accepts write and all in deny", function()
                post({
                    version = 1,
                    rules = { g = { allow = {}, deny = { "write:/public", "all:/download" } } },
                })
                assert.are.equal(200, ngx_mock.status)
            end)

            it("rejects write in allow, naming the operation", function()
                post({ version = 1, rules = { guest = { allow = { "write:/x" }, deny = {} } } })

                assert.are.equal(400, ngx_mock.status)
                local err = last_json().error
                assert.is_truthy(err:find("write", 1, true))
                assert.is_truthy(err:find("guest", 1, true))
                assert.is_truthy(err:find("read, all", 1, true))
                assert.are.equal(0, redis_sync.calls)
            end)

            it("rejects read in deny", function()
                post({ version = 1, rules = { guest = { allow = {}, deny = { "read:/x" } } } })

                assert.are.equal(400, ngx_mock.status)
                assert.is_truthy(last_json().error:find("write, all", 1, true))
            end)

            it("rejects an unknown operation", function()
                post({ version = 1, rules = { guest = { allow = { "bogus:/x" }, deny = {} } } })

                assert.are.equal(400, ngx_mock.status)
            end)

            it("rejects a root rule", function()
                post({ version = 1, rules = { guest = { allow = { "all:/" }, deny = {} } } })

                assert.are.equal(400, ngx_mock.status)
                assert.is_truthy(last_json().error:find("every URL", 1, true))
            end)

            it("rejects a rule without an operation", function()
                post({ version = 1, rules = { guest = { allow = { "/download" }, deny = {} } } })

                assert.are.equal(400, ngx_mock.status)
            end)

            it("rejects a path with a control character", function()
                post({ version = 1, rules = { guest = { allow = { "all:/down\nload" }, deny = {} } } })

                assert.are.equal(400, ngx_mock.status)
                assert.is_truthy(last_json().error:find("control", 1, true))
            end)

            it("rejects a missing allow list", function()
                post({ version = 1, rules = { guest = { deny = {} } } })

                assert.are.equal(400, ngx_mock.status)
                assert.is_truthy(last_json().error:find("allow", 1, true))
            end)

            it("rejects a missing deny list", function()
                post({ version = 1, rules = { guest = { allow = {} } } })

                assert.are.equal(400, ngx_mock.status)
                assert.is_truthy(last_json().error:find("deny", 1, true))
            end)
        end)

        it("names the role and list in the error for a rule deep in the config", function()
            post({
                version = 1,
                rules = {
                    ["team-a"] = { allow = { "read:/public" }, deny = {} },
                    ["team-b"] = { allow = { "read:/public", "write:/oops" }, deny = {} },
                },
            })

            assert.are.equal(400, ngx_mock.status)
            local err = last_json().error
            assert.is_truthy(err:find("team-b", 1, true))
            assert.is_truthy(err:find("position 2", 1, true))
        end)
    end)

    describe("atomic save", function()
        local function post_valid()
            set_method("POST")
            set_body(cjson.encode({
                version = 1,
                rules = { guest = { allow = { "read:/public" }, deny = {} } },
            }))
            run()
        end

        it("leaves the file untouched and removes the staged file when Redis fails", function()
            redis_sync = { ok = false, err = "connection refused", calls = 0 }
            post_valid()

            assert.are.equal(500, ngx_mock.status)
            assert.is_not_nil(last_json().error)

            -- The real config must still be the old one, and no .tmp left behind.
            assert.are.equal(SEED_CONFIG, mock_files[CONFIG_PATH])
            assert.is_nil(mock_files[TMP_PATH])
        end)

        it("hands Redis real tables, not the encoding sentinel, for empty lists", function()
            -- cjson.empty_array is a lightuserdata with no length, so passing it
            -- into save_config_to_redis makes `#rules.deny` throw.
            set_method("POST")
            set_body(cjson.encode({
                version = 1,
                rules = { guest = { allow = {}, deny = {} } },
            }))
            run()

            assert.are.equal(200, ngx_mock.status)
            local seen = redis_sync.last_rules.guest
            assert.are.equal("table", type(seen.deny))
            assert.are.equal(0, #seen.deny)
            assert.are.equal(0, #seen.allow)

            -- ...while the response and the file still carry arrays.
            assert.is_truthy(ngx_mock._last_say:find('"deny":%[%]'))
            local saved = cjson.decode(mock_files[CONFIG_PATH])
            assert.are.same({}, saved.rules.guest.deny)
        end)

        it("applies to Redis before replacing the file", function()
            local file_at_sync_time
            package.loaded["authorize"] = {
                save_config_to_redis = function(rules)
                    file_at_sync_time = mock_files[CONFIG_PATH]
                    redis_sync.last_rules = rules
                    return true
                end,
            }
            post_valid()

            assert.are.equal(200, ngx_mock.status)
            -- During the sync the file was still the old content, i.e. the tmp
            -- file had not been renamed into place yet.
            assert.are.equal(SEED_CONFIG, file_at_sync_time)
            assert.is_nil(mock_files[TMP_PATH])

            local saved = cjson.decode(mock_files[CONFIG_PATH])
            assert.are.equal(2, saved.version)
            assert.are.same({ "read:/public" }, saved.rules.guest.allow)
        end)
    end)
end)
