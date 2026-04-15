local cjson = require "cjson.safe"
local authorize = require "authorize"

ngx.header.content_type = 'application/json'

local userinfo = { isAdmin = false, writeable = false, username = '', userid = '' }

local private = string.lower(os.getenv("PRIVATE")) == "true"
if not private then
    ngx.say(cjson.encode(userinfo))
    return
end

userinfo.username = ngx.req.get_headers()["X-USER-NAME"] or ''
userinfo.userid = ngx.req.get_headers()["X-USER"] or ''

local groups = ngx.req.get_headers()["X-USER-GROUPS"] or ''
local ADMIN_GROUP = os.getenv("ADMIN_GROUP")
if groups then
    for group in string.gmatch(groups, "([^,]+)") do
        group = group:gsub("%s+", "")
        if group == ADMIN_GROUP then
            userinfo.isAdmin = true
            break
        end
    end
end

local args = ngx.req.get_uri_args()
local path_param = args.path

if not path_param then
    userinfo.writeable = false
else
    local decoded_path = ngx.unescape_uri(path_param)
    ngx.log(ngx.NOTICE, "Check path: ", decoded_path)
    userinfo.writeable = authorize.checkAuthorize(groups, "PUT", decoded_path)
end

ngx.say(cjson.encode(userinfo))
