local files = require "files"
local authorize = require "authorize"

-- Return err, source_path, target_path, action (move/copy)
local function get_data()
    local source_path = ngx.var.store_path
    if not source_path then
        return "No source path specified"
    end

    -- Read the request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return "No request body found"
    end

    -- Parse the URL-encoded form data
    local params = {}
    for key, value in body:gmatch("([^&=]+)=([^&=]*)") do
        params[ngx.unescape_uri(key)] = ngx.unescape_uri(value)
    end

    -- Extract parameters
    local target_path = params.dest
    if not target_path then
        return "No target path specified"
    end

    local action = params.action
    if action ~= "move" and action ~= "copy" and action ~= "rename" then
        return "Invalid action specified"
    end

    local sanitized_source_path, err = files.sanitize_path(source_path)
    if not sanitized_source_path then
        return source_path .. ": " .. err
    end

    -- Authorization check
    local groups = ngx.req.get_headers()["X-USER-GROUPS"] or ''
    if not authorize.checkAuthorize(groups, "PUT", target_path) then
        ngx.log(ngx.NOTICE, "User does not have permission to " .. action .. " to: " .. target_path)
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    target_path = files.combine_paths(ngx.var.document_root, target_path)
    local sanitized_target_path, err = files.sanitize_path(target_path)
    if not sanitized_target_path then
        return target_path .. ": " .. err
    end

    return nil, sanitized_source_path, sanitized_target_path, action
end

ngx.header.content_type = "text/plain"
local err, source_path, target_path, action = get_data()
if err then
    ngx.log(ngx.ERR, err)
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

local success, err = files.move_copy(source_path, target_path, action)
if success then
    ngx.log(ngx.NOTICE, "Successfully " .. action .. ": " .. source_path)
else
    ngx.log(ngx.ERR, err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
