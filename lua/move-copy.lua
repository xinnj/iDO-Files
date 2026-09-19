local files = require "files"
local authorize = require "authorize"

local VALID_ACTIONS = { move = true, copy = true, rename = true, create = true }

-- store_path has no trailing slash for the bucket root (URL /download) and for
-- folders reached by clicking one (URL /download/foo), but sanitize_path
-- requires one after the bucket name. Normalize before validating it.
local function ensure_trailing_slash(path)
    if path:sub(-1) ~= "/" then
        return path .. "/"
    end
    return path
end

-- Return err, params
local function parse_body()
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

    return nil, params
end

-- Create a folder inside the directory the request was made against: the parent
-- comes from nginx, only the folder name comes from the client.
-- Return err, request
local function build_create_request(params)
    local name = params.name
    if not name then
        return "No folder name specified"
    end

    -- Validate the name before it can reach a shell command. create_dir
    -- validates again; doing it here turns an invalid name into a 400 rather
    -- than the 500 that a filesystem failure would produce.
    local _, name_err = files.validate_name(name)
    if name_err then
        return "Invalid folder name: " .. name_err
    end

    local store_path = ngx.var.store_path
    if not store_path then
        return "No target path specified"
    end

    local parent_path, sanitize_err = files.sanitize_path(ensure_trailing_slash(store_path))
    if not parent_path then
        return store_path .. ": " .. sanitize_err
    end

    local is_dir, parent_type = files.check_path(parent_path)
    if not is_dir or parent_type ~= "directory" then
        return "Target is not a directory: " .. store_path
    end

    local target_url = ensure_trailing_slash(ngx.var.uri) .. name

    local groups = ngx.req.get_headers()["X-USER-GROUPS"] or ''
    if not authorize.checkAuthorize(groups, "PUT", target_url) then
        ngx.log(ngx.NOTICE, "User does not have permission to create folder: " .. target_url)
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    return nil, {
        action = "create",
        parent_path = parent_path,
        name = name,
        target_url = target_url,
    }
end

-- Return err, request
local function build_move_copy_request(params)
    local source_path = ngx.var.store_path
    if not source_path then
        return "No source path specified"
    end

    local target_path = params.dest
    if not target_path then
        return "No target path specified"
    end

    local action = params.action
    local force = params.force == "true"

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

    if sanitized_source_path == sanitized_target_path then
        return "Source and destination are the same"
    end

    return nil, {
        action = action,
        source = sanitized_source_path,
        target = sanitized_target_path,
        force = force,
    }
end

-- Return err, request
local function get_data()
    local err, params = parse_body()
    if err then
        return err
    end

    if not VALID_ACTIONS[params.action] then
        return "Invalid action specified"
    end

    if params.action == "create" then
        return build_create_request(params)
    end

    return build_move_copy_request(params)
end

ngx.header.content_type = "text/plain"
local err, request = get_data()
if err then
    ngx.log(ngx.ERR, err)
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

local success, op_err, conflict_type
if request.action == "create" then
    success, op_err, conflict_type = files.create_dir(request.parent_path, request.name)
else
    success, op_err, conflict_type = files.move_copy(request.source, request.target, request.action, request.force)
end

if success then
    ngx.log(ngx.NOTICE, "Successfully " .. request.action .. ": " .. (request.source or request.target_url))
elseif op_err == "exists" then
    ngx.header.content_type = "application/json"
    ngx.status = ngx.HTTP_CONFLICT
    ngx.say('{"exists":true,"type":"' .. conflict_type .. '"}')
    return
else
    ngx.log(ngx.ERR, op_err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
