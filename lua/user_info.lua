local authorize = require "authorize"

local _M = {}

-- Get user information including permissions
-- Returns: { username, userid, isAdmin, writeable }
function _M.get_user_info(path)
    local userid = ngx.req.get_headers()["X-USER"] or ""
    local auth_required = string.lower(os.getenv("AUTH_REQUIRED") or "") == "true"
    local userinfo = {
        username = ngx.req.get_headers()["X-USER-NAME"] or "Guest",
        userid = userid,
        email = ngx.req.get_headers()["X-USER-EMAIL"] or "",
        isAdmin = false,
        writeable = false,
        isGuest = (userid == "") or not auth_required,
        authRequired = auth_required
    }
    
    -- Check admin status based on group membership
    local groups = ngx.req.get_headers()["X-USER-GROUPS"] or ""
    local ADMIN_GROUP = os.getenv("ADMIN_GROUP")

    if groups and ADMIN_GROUP then
        for group in string.gmatch(groups, "([^,]+)") do
            group = group:gsub("%s+", "")
            if group == ADMIN_GROUP then
                userinfo.isAdmin = true
                break
            end
        end
    end
    
    -- Check writeable permission for the given path
    if path then
        userinfo.writeable = authorize.checkAuthorize(groups, "PUT", path)
    end
    
    return userinfo
end

-- Apply permission-based conditional rendering to HTML
-- Replaces <!--IF_WRITEABLE-->...<!--END_IF_WRITEABLE--> markers
-- Replaces <!--IF_ADMIN-->...<!--END_IF_ADMIN--> markers
function _M.apply_permissions(html, userinfo)
    -- Handle writeable sections
    if userinfo.writeable then
        html = html:gsub("<!%-%-IF_WRITEABLE%-%->", "")
        html = html:gsub("<!%-%-END_IF_WRITEABLE%-%->", "")
    else
        -- Remove entire blocks including content between markers
        html = html:gsub("<!%-%-IF_WRITEABLE%-%->.-<!%-%-END_IF_WRITEABLE%-%->", "")
    end
    
    -- Handle admin sections
    if userinfo.isAdmin then
        html = html:gsub("<!%-%-IF_ADMIN%-%->", "")
        html = html:gsub("<!%-%-END_IF_ADMIN%-%->", "")
    else
        -- Remove entire blocks including content between markers
        html = html:gsub("<!%-%-IF_ADMIN%-%->.-<!%-%-END_IF_ADMIN%-%->", "")
    end
    
    return html
end

-- HTTP endpoint handler for /fileserver/userinfo
-- Returns user info as JSON response
function _M.handle_endpoint()
    local cjson = require "cjson.safe"
    ngx.header.content_type = 'application/json'

    -- Get path parameter from query string
    local args = ngx.req.get_uri_args()
    local path_param = args.path

    -- Decode path if provided
    local decoded_path = nil
    if path_param then
        decoded_path = ngx.unescape_uri(path_param)
        ngx.log(ngx.NOTICE, "Check path: ", decoded_path)
    end

    -- Get user information
    local userinfo = _M.get_user_info(decoded_path)

    ngx.say(cjson.encode(userinfo))
end

return _M
