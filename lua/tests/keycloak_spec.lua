-- Tests for keycloak.lua
--
-- Run with:
--   LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/keycloak_spec.lua
--
-- The module requires "resty.http" at load time, so every test installs its
-- scripted mock before requiring the module, and clears package.loaded.

local ngx_mock = require("mock_ngx")
_G.ngx = ngx_mock
ngx_mock.null = {}
ngx_mock.log = function() end

-- Keys we do not control fall through to the real environment, so this mock
-- cannot break specs that busted loads after this file. `false` means
-- "explicitly absent".
local real_getenv = os.getenv
local env = {}
os.getenv = function(k)
    local value = env[k]
    if value == nil then return real_getenv(k) end
    if value == false then return nil end
    return value
end

-- ---------------------------------------------------------------- environment

local function set_oidc_env(opts)
    env = {
        OIDC_DISCOVERY_URL = opts.discovery or false,
        OIDC_CLIENT_ID = opts.client_id or false,
        OIDC_CLIENT_SECRET = opts.client_secret or false,
        OIDC_SSL_VERIFY = opts.ssl_verify or false,
    }
end

local TOKEN_ENDPOINT = "https://kc.example.com/auth/realms/mycorp/protocol/openid-connect/token"
local ADMIN_ROLES_URL = "https://kc.example.com/auth/admin/realms/mycorp/roles"

-- ---------------------------------------------------------------- redis mock

local redis_state = {}

local function install_redis(opts)
    opts = opts or {}
    redis_state = { store = opts.store or {}, setex_calls = {}, closed = 0 }

    local red = {
        get = function(_, key) return redis_state.store[key] end,
        setex = function(_, key, ttl, value)
            table.insert(redis_state.setex_calls, { key = key, ttl = ttl, value = value })
            redis_state.store[key] = value
            return "OK"
        end,
        set_keepalive = function() return true end,
    }

    package.loaded["resty.redis"] = {}
    package.loaded["redis_conn"] = {
        get_conn = function()
            if opts.down then return nil, "connection refused" end
            return red, nil
        end,
        -- Deliberately strict: the module used to call close() on a nil
        -- connection when Redis was unreachable.
        close = function(conn)
            if conn == nil then
                error("redis_conn.close() called with a nil connection")
            end
            redis_state.closed = redis_state.closed + 1
            return true
        end,
    }
end

-- ---------------------------------------------------------------- http mock

-- responses is a list of { status = n, body = "..." } consumed in call order.
local http_calls = {}

local function install_http(responses)
    http_calls = {}
    local queue = responses

    package.loaded["resty.http"] = {
        new = function()
            return {
                request_uri = function(_, url, opts)
                    local call = { url = url, opts = opts }
                    table.insert(http_calls, call)
                    local next_response = table.remove(queue, 1)
                    if not next_response then
                        return nil, "no scripted response for " .. url
                    end
                    return { status = next_response.status, body = next_response.body }
                end
            }
        end
    }
end

-- An install_http that also proves the module never reached the network,
-- mirroring tests/env/lua/resty/http.lua which is literally `return {}`.
local function install_http_that_must_not_be_used()
    http_calls = {}
    package.loaded["resty.http"] = {}
end

local function discovery_body()
    return '{"token_endpoint":"' .. TOKEN_ENDPOINT .. '"}'
end

local function token_body()
    return '{"access_token":"test-token"}'
end

local function roles_body(names)
    local parts = {}
    for _, name in ipairs(names) do
        table.insert(parts, '{"id":"' .. name .. '","name":"' .. name .. '","composite":false}')
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Reconstruct a urlencoded form body into a table, so we can assert the
-- values survive encoding rather than comparing raw strings.
local function parse_form(body)
    local out = {}
    for pair in body:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]*)=(.*)$")
        if key then
            value = value:gsub("+", " ")
            value = value:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            out[key] = value
        end
    end
    return out
end

-- ---------------------------------------------------------------- setup

local function load_module()
    package.loaded["keycloak"] = nil
    return require("keycloak")
end

describe("keycloak", function()
    describe("token request encoding", function()
        it("round-trips a client secret containing & = and %", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "a&b=c%d+ e",
            })
            install_redis({})
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 200, body = roles_body({ "fileserver_admin" }) },
            })

            local keycloak = load_module()
            local roles = keycloak.get_realm_roles()
            assert.is_not_nil(roles)

            local token_call = http_calls[2]
            assert.are.equal(TOKEN_ENDPOINT, token_call.url)

            local form = parse_form(token_call.opts.body)
            assert.are.equal("a&b=c%d+ e", form.client_secret)
            assert.are.equal("file-server", form.client_id)
            assert.are.equal("client_credentials", form.grant_type)
        end)
    end)

    describe("get_realm_roles", function()
        it("returns an error without touching the network when OIDC is unconfigured", function()
            -- The E2E environment exports every OIDC_* variable as the empty
            -- string, and in Lua "" is truthy, so this must be an explicit check.
            set_oidc_env({ discovery = "", client_id = "", client_secret = "" })
            install_redis({})
            install_http_that_must_not_be_used()

            local keycloak = load_module()
            local roles, err = keycloak.get_realm_roles()

            assert.is_nil(roles)
            assert.is_truthy(err:find("OIDC"))
            assert.are.equal(0, #http_calls)
        end)

        it("returns an error when OIDC variables are absent entirely", function()
            set_oidc_env({})
            install_redis({})
            install_http_that_must_not_be_used()

            local keycloak = load_module()
            local roles, err = keycloak.get_realm_roles()

            assert.is_nil(roles)
            assert.is_truthy(err:find("OIDC"))
            assert.are.equal(0, #http_calls)
        end)

        it("fetches realm roles sorted, and caches them", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({})
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 200, body = roles_body({ "guest", "fileserver_admin", "auditors" }) },
            })

            local keycloak = load_module()
            local roles, source = keycloak.get_realm_roles()

            assert.are.same({ "auditors", "fileserver_admin", "guest" }, roles)
            assert.are.equal("keycloak", source)

            assert.are.equal(ADMIN_ROLES_URL, http_calls[3].url)
            assert.are.equal("Bearer test-token", http_calls[3].opts.headers["Authorization"])

            assert.are.equal(1, #redis_state.setex_calls)
            assert.are.equal("realm_roles:all", redis_state.setex_calls[1].key)
            assert.are.equal(300, redis_state.setex_calls[1].ttl)
            assert.are.equal(1, redis_state.closed)
        end)

        it("serves a cache hit without any HTTP call", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({ store = { ["realm_roles:all"] = '["auditors","guest"]' } })
            install_http_that_must_not_be_used()

            local keycloak = load_module()
            local roles, source = keycloak.get_realm_roles()

            assert.are.same({ "auditors", "guest" }, roles)
            assert.are.equal("cache", source)
            assert.are.equal(0, #http_calls)
        end)

        it("bypasses the cache when refresh is requested", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({ store = { ["realm_roles:all"] = '["stale"]' } })
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 200, body = roles_body({ "fresh" }) },
            })

            local keycloak = load_module()
            local roles, source = keycloak.get_realm_roles(true)

            assert.are.same({ "fresh" }, roles)
            assert.are.equal("keycloak", source)
            assert.are.equal(3, #http_calls)
        end)

        it("explains the permission needed when Keycloak answers 403", function()
            -- Listing realm roles needs view-realm, which the other Admin API
            -- calls here do not. A bare 403 sent an operator hunting through
            -- Keycloak logs, so the message names the role to grant.
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({})
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 403, body = '{"error":"HTTP 403 Forbidden"}' },
            })

            local keycloak = load_module()
            local roles, err = keycloak.get_realm_roles()

            assert.is_nil(roles)
            assert.is_truthy(err:find("403", 1, true))
            assert.is_truthy(err:find("view-realm", 1, true))
            assert.is_truthy(err:find("realm-management", 1, true))
            assert.are.equal(0, #redis_state.setex_calls)
        end)

        it("does not cache a failure", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({})
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 500, body = "boom" },
            })

            local keycloak = load_module()
            local roles, err = keycloak.get_realm_roles()

            assert.is_nil(roles)
            assert.is_truthy(err:find("500"))
            assert.are.equal(0, #redis_state.setex_calls)
        end)

        it("survives Redis being unreachable", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({ down = true })
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 200, body = roles_body({ "guest" }) },
            })

            local keycloak = load_module()
            local roles, source = keycloak.get_realm_roles()

            assert.are.same({ "guest" }, roles)
            assert.are.equal("keycloak", source)
            assert.are.equal(0, redis_state.closed)
        end)

        it("reports an error when resty.http is not usable", function()
            -- In the E2E environment resty.http resolves to `return {}`, so
            -- http.new() would raise rather than return.
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({})
            install_http_that_must_not_be_used()

            local keycloak = load_module()
            local roles, err = keycloak.get_realm_roles()

            assert.is_nil(roles)
            assert.is_truthy(err)
        end)
    end)

    describe("close(red) guards on the existing paths", function()
        it("get_user_groups does not call close with nil when Redis is down", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({ down = true })
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 200, body = roles_body({ "guest" }) },
            })

            local keycloak = load_module()
            local groups = keycloak.get_user_groups("user-1")

            assert.are.equal("guest", groups)
            assert.are.equal(0, redis_state.closed)
        end)

        it("get_username_from_userid does not call close with nil when Redis is down", function()
            set_oidc_env({
                discovery = "https://kc.example.com/auth/realms/mycorp/.well-known/openid-configuration",
                client_id = "file-server",
                client_secret = "secret",
            })
            install_redis({ down = true })
            install_http({
                { status = 200, body = discovery_body() },
                { status = 200, body = token_body() },
                { status = 200, body = '{"username":"alice"}' },
            })

            local keycloak = load_module()
            local username = keycloak.get_username_from_userid("user-1")

            assert.are.equal("alice", username)
            assert.are.equal(0, redis_state.closed)
        end)
    end)
end)
