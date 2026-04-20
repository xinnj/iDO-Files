local cjson = require "cjson.safe"
local resty_string = require "resty.string"
local random = require "random"
local redis_conn = require "redis_conn"

local TOKEN_EXPIRE_MINUTES = tonumber(os.getenv("TOKEN_EXPIRE_MINUTES")) or 6

local _M = {}

local function generate_token()
    local bytes = random.bytes(32)
    return resty_string.to_hex(bytes)
end

function _M.generate()
    local path = ngx.var.arg_path
    if not path then
        ngx.log(ngx.ERR, "Path parameter missing")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    path = ngx.unescape_uri(path)

    local red, err = redis_conn.get_conn()
    if not red then
        ngx.log(ngx.ERR, "Server error: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local token = generate_token()
    local ok, err = red:setex("manifest:" .. token, TOKEN_EXPIRE_MINUTES * 60, path)
    redis_conn.close(red)

    if not ok then
        ngx.log(ngx.ERR, "Failed to generate token: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ token = token, expiredMinutes = TOKEN_EXPIRE_MINUTES }))
end

local function verify_token(token)
    local red, err = redis_conn.get_conn()
    if not red then
        ngx.log(ngx.ERR, "Redis connection failed: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local path, err = red:get("manifest:" .. token)
    redis_conn.close(red)

    if not path then
        ngx.log(ngx.ERR, "Redis query failed: " .. err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if path == ngx.null then
        ngx.log(ngx.WARN, "Invalid token: ", token)
        ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end

    --red = redis_conn.get_conn()
    --red:del("manifest:" .. token)
    --redis_conn.close(red)

    return path
end

local function store_download_link(base_uri)
    local red = redis_conn.get_conn()
    if not red then
        ngx.log(ngx.ERR, "Redis connection failed: ", err)
        return
    end

    local res, err = red:setex("download:" .. base_uri, TOKEN_EXPIRE_MINUTES * 60, "1")
    if not res then
        ngx.log(ngx.ERR, "Failed to set Redis key: ", err)
    end

    redis_conn.close(red)
end

local function check_download_link(base_uri)
    local red = redis_conn.get_conn()
    if not red then
        ngx.log(ngx.ERR, "Redis connection failed: ", err)
        return false
    end

    local exists, err = red:exists("download:" .. base_uri)
    if err then
        ngx.log(ngx.ERR, "Redis EXISTS command failed: ", err)
        redis_conn.close(red)
        return false
    end

    redis_conn.close(red)
    return exists == 1
end

local function get_base_uri(uri)
    local last_dot_pos = string.find(uri, "%.[^%.]*$")
    if last_dot_pos then
        return string.sub(uri, 1, last_dot_pos - 1)
    end
    return uri
end

function _M.authorize()
    local uri = ngx.var.uri
    local fileName = uri:match("/([^/]+)/?$") or uri:match("^([^/]+)/?$")

    -- Check for .ipa or .hap or .app extension first
    if fileName:match("%.ipa$") or fileName:match("%.hap$") or fileName:match("%.app$") then
        local base_uri = get_base_uri(uri)
        local exists = check_download_link(base_uri)
        if exists then
            ngx.log(ngx.NOTICE, "Authentication via cache successful: " .. uri)
            ngx.var.store_path = uri
            ngx.var.file_name = fileName
            return
        end
    end

    -- If not found in Redis or not .ipa/.hap/.app, proceed with token verification
    local token = get_base_uri(fileName)
    if not token then
        ngx.log(ngx.ERR, "Token missing")
        ngx.status = ngx.HTTP_UNAUTHORIZED
        ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end

    local manifestPath = verify_token(token)
    local manifestUri = manifestPath:match("://[^/]+(/.*)") or manifestPath:match("(/.*)") or "/"
    local manifestName = manifestUri:match("/([^/]+)/?$") or manifestUri:match("^([^/]+)/?$")

    -- If verification passed and it's a .plist or .json5 request, store in Redis
    if manifestUri:match("%.plist$") or manifestUri:match("%.json5$") then
        local base_uri = get_base_uri(manifestUri)
        store_download_link(base_uri)
    end

    ngx.log(ngx.NOTICE, "Authentication successful: " .. manifestUri)

    ngx.var.store_path = manifestUri
    ngx.var.file_name = manifestName
end

return _M