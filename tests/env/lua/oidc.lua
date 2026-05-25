local _M = {}

function _M.authenticate(checkOnly)
    if os.getenv("AUTH_REQUIRED") == "true" then
        local oidc = require("resty.openidc")
        -- delegate to real oidc
        local opts = {
            client_id = os.getenv("OIDC_CLIENT_ID"),
            client_secret = os.getenv("OIDC_CLIENT_SECRET"),
            discovery = os.getenv("OIDC_DISCOVERY_URL"),
            redirect_uri = os.getenv("OIDC_REDIRECT_URI"),
            logout_path = os.getenv("OIDC_LOGOUT_PATH"),
            post_logout_redirect_uri = os.getenv("OIDC_LOGOUT_REDIRECT_URI"),
            ssl_verify = os.getenv("OIDC_SSL_VERIFY") or "yes",
            scope = "openid email profile"
        }
        local session_opts = {
            secret = "YsiTBGxHcWKsERDWVzAiDYvh9pq4BGF0jMKCmcMF8F0=",
            remember = true,
            storage = "redis",
            redis = {
                host = os.getenv("REDIS_HOST") or "127.0.0.1",
                password = os.getenv("REDIS_PASSWORD") or nil,
                port = tonumber(os.getenv("REDIS_PORT") or 6379),
                prefix = "fileserver"
            }
        }
        if checkOnly then
            local res, err = oidc.authenticate(opts, nil, "deny", session_opts)
            if err then
                ngx.req.set_header("X-USER", "")
                ngx.req.set_header("X-USER-GROUPS", "")
                ngx.req.set_header("X-USER-NAME", "")
                ngx.req.set_header("X-USER-EMAIL", "")
            else
                ngx.req.set_header("X-USER", res.id_token.sub)
                ngx.req.set_header("X-USER-GROUPS", table.concat(res.id_token.groups or {}, ", "))
                ngx.req.set_header("X-USER-NAME", res.id_token.preferred_username or "unknown")
                ngx.req.set_header("X-USER-EMAIL", res.id_token.email or "unknown")
            end
        else
            local res, err = oidc.authenticate(opts, nil, nil, session_opts)
            if err then
                ngx.log(ngx.ERR, err)
                ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
            end
            ngx.req.set_header("X-USER", res.id_token.sub)
            ngx.req.set_header("X-USER-GROUPS", table.concat(res.id_token.groups or {}, ", "))
            ngx.req.set_header("X-USER-NAME", res.id_token.preferred_username or "unknown")
            ngx.req.set_header("X-USER-EMAIL", res.id_token.email or "unknown")
        end
    else
        -- Auth disabled: preserve any incoming user headers (for e2e tests),
        -- otherwise default to guest
        local headers = ngx.req.get_headers()
        ngx.req.set_header("X-USER", headers["X-USER"] or "guest")
        ngx.req.set_header("X-USER-GROUPS", headers["X-USER-GROUPS"] or "/.default")
        ngx.req.set_header("X-USER-NAME", headers["X-USER-NAME"] or "Guest")
        ngx.req.set_header("X-USER-EMAIL", headers["X-USER-EMAIL"] or "guest@localhost")
    end
end

return _M
