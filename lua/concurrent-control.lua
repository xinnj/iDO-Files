local cjson = require "cjson.safe"
local limit_conn = require "resty.limit.conn"

local ENABLE_CONCURRENT_CONTROL = os.getenv("ENABLE_CONCURRENT_CONTROL") or "true"
local MAX_CONCURRENT_DOWNLOADS = tonumber(os.getenv("MAX_CONCURRENT_DOWNLOADS") or 5)
local CONCURRENT_BURST = tonumber(os.getenv("CONCURRENT_BURST") or 2)
local CONCURRENT_DELAY = tonumber(os.getenv("CONCURRENT_DELAY") or 1)
local SHARED_DICT_NAME = "concurrent_control"

local _M = {}

-- Get user ID from request
local function get_user_id()
    local headers = ngx.req.get_headers()
    
    -- First try to get user ID from OIDC headers
    local user_id = headers["X-USER"]
    if user_id and user_id ~= "" then
        return user_id
    end
    
    -- Try to get user ID from Authorization header (Bearer token)
    local auth_header = headers["authorization"] or headers["Authorization"]
    if auth_header then
        -- Extract token from Authorization header
        local token = string.sub(auth_header, 8) -- Remove "Bearer " prefix
        if token then
            -- Try to verify access token to get user ID
            local access_token = require "access-token"
            local ok, data = access_token.verify(token)
            if ok and data.userid then
                return data.userid
            end
        end
    end
    
    -- Try to get user ID from share token or time token
    -- For share tokens, we can extract from the token itself
    local uri = ngx.var.uri
    if uri and uri:match("share%-download") then
        -- Extract token from URI pattern: /share-download/{token}
        local token = uri:match("share%-download/([^/]+)")
        if token then
            -- For share tokens, we can use the token as user identifier
            return "share_" .. token
        end
    end
    
    -- If no user ID found, use a default identifier based on client IP
    local client_ip = ngx.var.remote_addr
    if client_ip then
        return "ip_" .. client_ip:gsub("[.:]", "_")
    end
    
    return "unknown"
end

-- Initialize the connection limiter
local function init_conn_limiter()
    local limiter, err = limit_conn.new(SHARED_DICT_NAME, MAX_CONCURRENT_DOWNLOADS, CONCURRENT_BURST, CONCURRENT_DELAY)
    if not limiter then
        ngx.log(ngx.ERR, "Failed to create connection limiter: ", err)
        return nil
    end
    return limiter
end

-- Check if this request should apply concurrent control
local function should_apply_concurrent_control()
    -- First check if concurrent control is enabled
    if ENABLE_CONCURRENT_CONTROL:lower() ~= "true" then
        ngx.log(ngx.DEBUG, "Concurrent control is disabled via environment variable")
        return false
    end

    local uri = ngx.var.uri
    
    -- File extension
    local download_extensions = {
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar",
        "exe", "dmg", "pkg", "msi", "iso", "img",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "deb", "ipa", "apk", "hap", "app", "tgz"
    }
    
    local file_ext = string.match(uri, "%.(%w+)$")
    if file_ext then
        file_ext = file_ext:lower()
        for _, ext in ipairs(download_extensions) do
            if file_ext == ext then
                ngx.log(ngx.DEBUG, "Applying concurrent control for download extension: .", file_ext)
                return true
            end
        end
    end
    
    -- Check if this is share-download location
    if uri and uri:match("share%-download") then
        ngx.log(ngx.DEBUG, "Applying concurrent control for share-download location: ", uri)
        return true
    end

    ngx.log(ngx.DEBUG, "Not to apply concurrent control")
    return false
end

-- Check if user can start a new download
function _M.can_start_download()
    if not should_apply_concurrent_control() then
        return true, "skip"
    end
    
    local user_id = get_user_id()
    local limiter = init_conn_limiter()
    
    if not limiter then
        ngx.log(ngx.ERR, "Failed to initialize connection limiter")
        return false, "Internal server error"
    end
    
    -- Use the connection limiter to check if user can start a new download
    local delay, err = limiter:incoming(user_id, true)
    
    if not delay then
        if err == "rejected" then
            ngx.log(ngx.WARN, "User ", user_id, " exceeded concurrent download limit: ", MAX_CONCURRENT_DOWNLOADS)
            return false, "Too many concurrent downloads. Maximum allowed: " .. MAX_CONCURRENT_DOWNLOADS
        else
            ngx.log(ngx.ERR, "Connection limiter error: ", err)
            return false, "Internal server error"
        end
    end
    
    -- Store user_id in nginx variable for cleanup
    ngx.var.concurrent_user_id = user_id
    
    if delay >= 0.001 then
        -- If there's a delay, we need to wait before proceeding
        ngx.log(ngx.NOTICE, "User ", user_id, " download delayed by ", delay, " seconds")
        ngx.sleep(delay)
    end
    
    ngx.log(ngx.DEBUG, "User ", user_id, " started new download (delay: ", delay, ")")
    return true, "ok"
end

-- Cleanup after download completes
function _M.cleanup_download()
    local user_id = ngx.var.concurrent_user_id
    if not user_id or user_id == "" then
        return true
    end
    
    local limiter = init_conn_limiter()
    if not limiter then
        ngx.log(ngx.ERR, "Failed to initialize connection limiter for cleanup")
        return false
    end
    
    -- Leave the connection (release the slot)
    local ok, err = limiter:leaving(user_id)
    
    if ok then
        ngx.log(ngx.DEBUG, "Cleaned up concurrent download for user: ", user_id)
    else
        ngx.log(ngx.ERR, "Failed to cleanup concurrent download for user: ", user_id, " - ", err)
    end
    
    return ok
end

-- Get current usage statistics
function _M.get_usage_stats()
    local dict = ngx.shared[SHARED_DICT_NAME]
    if not dict then
        ngx.log(ngx.ERR, "Failed to get shared dictionary: ", SHARED_DICT_NAME)
        return nil
    end
    
    local keys = dict:get_keys(0)
    local stats = {
        total_concurrent = 0,
        users = {}
    }
    
    -- Parse the shared dictionary to extract usage statistics
    -- The lua-resty-limit-conn library stores active connections with their counts
    for _, key in ipairs(keys) do
        -- Look for keys that represent active connections
        -- The library uses keys like "conn:user_id" for active connections
        if key:match("^conn:") then
            local user_id = key:match("^conn:(.+)")
            if user_id then
                local value, flags = dict:get(key)
                if value then
                    -- Value contains the connection count for this user
                    local count = tonumber(value) or 0
                    stats.total_concurrent = stats.total_concurrent + count
                    stats.users[user_id] = count
                end
            end
        end
    end
    
    return stats
end

return _M