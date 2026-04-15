local redis = require "resty.redis"

local REDIS_HOST = os.getenv("REDIS_HOST") or "127.0.0.1"
local REDIS_PORT = os.getenv("REDIS_PORT") or 6379
local REDIS_PASSWORD = os.getenv("REDIS_PASSWORD") or nil
local REDIS_TIMEOUT = 5000

local _M = {}

function _M.get_conn()
    local red = redis:new()
    red:set_timeout(REDIS_TIMEOUT)

    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis: ", err)
        return nil, err
    end

    if REDIS_PASSWORD then
        local res, err = red:auth(REDIS_PASSWORD)
        if not res then
            ngx.log(ngx.ERR, "Failed to authenticate with Redis: ", err)
            return nil, err
        end
    end

    return red
end

function _M.close(red)
    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.ERR, "Failed to release Redis connection: ", err)
    end
end

return _M
