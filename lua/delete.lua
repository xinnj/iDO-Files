local files = require "files"

-- Return err,  target_path
local function get_data()
    local target_path = ngx.var.store_path
    if not target_path then
        return "No target path specified"
    end

    local sanitized_target_path, err = files.sanitize_path(target_path)
    if not sanitized_target_path then
        return target_path .. ": " .. err
    end

    return nil, sanitized_target_path
end

ngx.header.content_type = "text/plain"
local err, target_path = get_data()
if err then
    ngx.log(ngx.ERR, err)
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

local success, err = files.delete(target_path)

if success then
    ngx.log(ngx.NOTICE, "Successfully deleted: " .. target_path)
else
    ngx.log(ngx.ERR, err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
