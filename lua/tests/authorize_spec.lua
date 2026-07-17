-- Tests for authorize.lua
local ngx_mock = require("mock_ngx")

-- Set up globals
_G.ngx = ngx_mock
ngx_mock.var.url_prefix = "/"

-- Mock cjson.safe
package.loaded["cjson.safe"] = {
    encode = function(t)
        if type(t) ~= "table" then return tostring(t) end
        local parts = {}
        for k, v in pairs(t) do
            if type(v) == "string" then
                table.insert(parts, '"' .. k .. '":"' .. v .. '"')
            elseif type(v) == "boolean" then
                table.insert(parts, '"' .. k .. '":' .. tostring(v))
            elseif type(v) == "number" then
                table.insert(parts, '"' .. k .. '":' .. v)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end,
    decode = function(s)
        return {}
    end
}

-- In-memory Redis store for testing
local mock_redis_store = {}

local mock_red = {
    set_timeout = function() end,
    connect = function() return true end,
    auth = function() return true end,
    set_keepalive = function() return true end
}

function mock_red:keys(pattern)
    local result = {}
    for key, _ in pairs(mock_redis_store) do
        if key:match("^nginx_auth:") then
            table.insert(result, key)
        end
    end
    return result
end

function mock_red:smembers(key)
    local data = mock_redis_store[key]
    if data and type(data) == "table" then
        return data
    end
    return {}
end

function mock_red:del(...)
    return 1
end

function mock_red:sadd(key, ...)
    return 1
end

function mock_red:init_pipeline()
    return true
end

function mock_red:commit_pipeline()
    return {true}
end

function mock_red:set(key, value)
    return "OK"
end

function mock_red:get(key)
    return nil
end

package.loaded["resty.redis"] = {}
package.loaded["redis_conn"] = {
    get_conn = function()
        return mock_red, nil
    end,
    close = function(red)
        return true
    end
}

-- Mock oidc module
package.loaded["resty.openidc"] = {}
package.loaded["oidc"] = {
    authenticate = function(checkOnly)
        -- no-op for testing
    end
}

-- Mock resty.http
package.loaded["resty.http"] = {}

-- Mock keycloak module
package.loaded["keycloak"] = {
    get_user_groups = function(userid)
        return "fileserver_admin"
    end,
    get_username_from_userid = function(userid)
        return "testuser"
    end
}

-- Mock resty.string
package.loaded["resty.string"] = {
    to_hex = function(s) return s end
}

-- Mock random
package.loaded["random"] = {
    bytes = function(n) return string.rep("a", n) end,
    token = function(n) return string.rep("t", n) end
}

-- Mock access-token module
package.loaded["access-token"] = {
    verify = function(token)
        return false, "Token not found"
    end,
    generate = function() end,
    list = function() end,
    delete = function() end
}

-- Mock shared dict for auth_cache
local mock_shared_dict = {
    _data = {},
    get = function(self, key)
        return self._data[key]
    end,
    set = function(self, key, value)
        self._data[key] = value
        return true, nil
    end
}

ngx_mock.shared = {
    ["auth_cache"] = mock_shared_dict,
    ["concurrent_control"] = mock_shared_dict
}

-- Default Redis data setup
local function reset_redis_data()
    mock_redis_store = {
        ["nginx_auth:fileserver_admin:allow"] = {"all:/download", "all:/public", "all:/archive"},
        ["nginx_auth:fileserver_admin:deny"] = {},
        ["nginx_auth:.default:allow"] = {"read:/download", "read:/public"},
        ["nginx_auth:.default:deny"] = {"write:/download"}
    }
end

reset_redis_data()

-- Fresh require of authorize module
package.loaded["authorize"] = nil
local authorize = require("authorize")

describe("authorize module", function()

    before_each(function()
        -- Reset shared dict and mark as initialized so load_config() skips file reading
        mock_shared_dict._data = { initialized = true }
        -- Reset redis data
        reset_redis_data()
    end)

    describe("checkAuthorize", function()

        it("allows GET for admin group on download path", function()
            local result = authorize.checkAuthorize("fileserver_admin", "GET", "/download")
            assert.is_true(result)
        end)

        it("allows POST for admin group on download path (all permission)", function()
            local result = authorize.checkAuthorize("fileserver_admin", "POST", "/download")
            assert.is_true(result)
        end)

        it("allows GET for default group on download path (read permission)", function()
            local result = authorize.checkAuthorize(".default", "GET", "/download")
            assert.is_true(result)
        end)

        it("denies POST for default group on download path (write deny rule)", function()
            local result = authorize.checkAuthorize(".default", "POST", "/download")
            assert.is_false(result)
        end)

        it("falls back to .default when no matching rules found for group", function()
            local result = authorize.checkAuthorize("unknown-group", "GET", "/download")
            -- unknown-group has no rules, falls back to .default which has read:/download allow
            assert.is_true(result)
        end)

        it("deny rules take priority over allow rules", function()
            mock_redis_store = {
                ["nginx_auth:test-group:allow"] = {"all:/download"},
                ["nginx_auth:test-group:deny"] = {"all:/download"}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("test-group", "GET", "/download")
            -- Deny takes priority: deny is checked first in the loop, short-circuits
            assert.is_false(result)
        end)

        it("handles comma-separated groups", function()
            local result = authorize.checkAuthorize("fileserver_admin, other-group", "GET", "/download")
            assert.is_true(result)
        end)

        it("defaults to .default group when no valid groups provided", function()
            local result = authorize.checkAuthorize("", "GET", "/download")
            -- Empty string falls back to .default which has read:/download allow
            assert.is_true(result)
        end)

        it("falls back to .default when group has no configured rules", function()
            local result = authorize.checkAuthorize("invalid-group", "GET", "/download")
            -- invalid-group has no rules, falls back to .default which has read:/download allow
            assert.is_true(result)
        end)

        it("allows read on public path for default group", function()
            local result = authorize.checkAuthorize(".default", "GET", "/public")
            assert.is_true(result)
        end)

        it("denies write on archive for default group (no rule)", function()
            local result = authorize.checkAuthorize(".default", "PUT", "/archive")
            assert.is_false(result)
        end)

        it("handles URI with path under prefix", function()
            mock_redis_store = {
                ["nginx_auth:test-group:allow"] = {"all:/download/subfolder"},
                ["nginx_auth:test-group:deny"] = {}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("test-group", "GET", "/download/subfolder/file.txt")
            assert.is_true(result)
        end)

        it("denies when URI does not match any allowed prefix", function()
            mock_redis_store = {
                ["nginx_auth:limited-group:allow"] = {"read:/public"},
                ["nginx_auth:limited-group:deny"] = {}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("limited-group", "GET", "/download")
            assert.is_false(result)
        end)

        it("denies DELETE for read-only permission", function()
            mock_redis_store = {
                ["nginx_auth:readonly-group:allow"] = {"read:/download"},
                ["nginx_auth:readonly-group:deny"] = {}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("readonly-group", "DELETE", "/download")
            assert.is_false(result)
        end)

        it("allows PUT for all permission", function()
            mock_redis_store = {
                ["nginx_auth:full-group:allow"] = {"all:/download"},
                ["nginx_auth:full-group:deny"] = {}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("full-group", "PUT", "/download")
            assert.is_true(result)
        end)

        it("allows HEAD for read permission", function()
            mock_redis_store = {
                ["nginx_auth:read-group:allow"] = {"read:/download"},
                ["nginx_auth:read-group:deny"] = {}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("read-group", "HEAD", "/download")
            assert.is_true(result)
        end)

        it("write deny rule denies PUT and DELETE but not GET", function()
            mock_redis_store = {
                ["nginx_auth:no-write-group:allow"] = {"all:/download"},
                ["nginx_auth:no-write-group:deny"] = {"write:/download"}
            }
            mock_shared_dict._data = { initialized = true }

            -- GET should still be allowed (write deny doesn't affect read methods)
            local get_result = authorize.checkAuthorize("no-write-group", "GET", "/download")
            assert.is_true(get_result)

            -- PUT should be denied by write deny rule
            mock_shared_dict._data = { initialized = true }
            local put_result = authorize.checkAuthorize("no-write-group", "PUT", "/download")
            assert.is_false(put_result)

            -- DELETE should also be denied by write deny rule
            mock_shared_dict._data = { initialized = true }
            local delete_result = authorize.checkAuthorize("no-write-group", "DELETE", "/download")
            assert.is_false(delete_result)
        end)

        it("all deny rule denies all methods including GET", function()
            mock_redis_store = {
                ["nginx_auth:blocked-group:allow"] = {"all:/download"},
                ["nginx_auth:blocked-group:deny"] = {"all:/download"}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("blocked-group", "GET", "/download")
            assert.is_false(result)
        end)

        it("handles empty allow and deny lists", function()
            mock_redis_store = {
                ["nginx_auth:empty-group:allow"] = {},
                ["nginx_auth:empty-group:deny"] = {}
            }
            mock_shared_dict._data = { initialized = true }

            local result = authorize.checkAuthorize("empty-group", "GET", "/download")
            assert.is_false(result)
        end)
    end)

    describe("authorize", function()
        local original_getenv
        local original_get_method
        local original_get_headers

        before_each(function()
            original_getenv = os.getenv
            original_get_method = ngx_mock.req.get_method
            original_get_headers = ngx_mock.req.get_headers

            -- Reset mock
            ngx_mock.req.get_method = function()
                return "GET"
            end
            ngx_mock.req.get_headers = function()
                return {}
            end
            ngx_mock.var.uri = "/download/file.txt"

            -- Reset redis data and cache
            reset_redis_data()
            mock_shared_dict._data = { initialized = true }
        end)

        after_each(function()
            os.getenv = original_getenv
            ngx_mock.req.get_method = original_get_method
            ngx_mock.req.get_headers = original_get_headers
        end)

        it("allows access when AUTH_REQUIRED is false", function()
            os.getenv = function(key)
                if key == "AUTH_REQUIRED" then return "false" end
                return original_getenv(key)
            end

            local result = authorize.authorize("GET", "/download")
            assert.is_true(result)
        end)

        it("allows authenticated user with admin group", function()
            os.getenv = function(key)
                if key == "AUTH_REQUIRED" then return "true" end
                if key == "OIDC_CLIENT_ID" then return "test-client" end
                if key == "OIDC_CLIENT_SECRET" then return "test-secret" end
                if key == "OIDC_DISCOVERY_URL" then return "https://keycloak.example.com/realms/test" end
                return original_getenv(key)
            end

            -- Simulate OIDC authenticated session with admin group
            ngx_mock.req.get_headers = function()
                return {
                    ["X-USER-GROUPS"] = "fileserver_admin"
                }
            end

            local result = authorize.authorize("GET", "/download")
            assert.is_true(result)
        end)

        it("denies access with invalid Bearer token", function()
            os.getenv = function(key)
                if key == "AUTH_REQUIRED" then return "true" end
                if key == "OIDC_CLIENT_ID" then return "test-client" end
                if key == "OIDC_CLIENT_SECRET" then return "test-secret" end
                if key == "OIDC_DISCOVERY_URL" then return "https://keycloak.example.com/realms/test" end
                return original_getenv(key)
            end

            package.loaded["access-token"].verify = function(token)
                return false, "Invalid token"
            end

            ngx_mock.req.get_headers = function()
                return {
                    ["authorization"] = "Bearer bad-token"
                }
            end

            local result = authorize.authorize("GET", "/download")
            assert.is_false(result)
        end)
    end)

end)
