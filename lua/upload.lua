local cjson = require "cjson.safe"
local json = require "json"
local lfs = require "lfs"
local upload = require "upload_file"
local files = require "files"
local policy = require "upload-policy"

-- Return the kind of thing at `path`, or nil when nothing is there.
--
-- lfs rather than files.check_path: that one shells out twice per name through
-- io.popen, which blocks the worker, and a pre-flight asks about every name in
-- the batch. Nothing here is interpolated into a shell command, so no escaping
-- applies -- which is also why the probes below pass the unescaped path.
local function path_kind(path)
    local attr = lfs.attributes(path)
    if not attr then
        return nil
    end
    return attr.mode == "directory" and "directory" or "file"
end

-- The destination directory, as the path the upload writes to and as the
-- shell-safe form. Shared so the pre-flight and the upload cannot disagree
-- about where the file is going. `safe_path` is nil when sanitize_path rejects
-- the path; the caller decides what that means.
local function resolve_dest_dir()
    local decoded_path = ngx.unescape_uri(ngx.var.store_path)
    local path = decoded_path .. (decoded_path:sub(-1) == "/" and "" or "/")
    return path, files.sanitize_path(path)
end

-- Read the rest of the multipart body before answering.
--
-- The client is still writing when we decide to refuse, and upload_file holds
-- the socket directly, so a response emitted into a socket we then close
-- reaches the browser as a network error rather than as the status we just
-- sent. No byte budget: a partial drain recreates the race for exactly the
-- large uploads where it hurts. form:set_timeout bounds the wait, and a
-- stalled client falls into the existing 400 path.
local function drain(form)
    while true do
        local typ = form:read()
        if typ == nil or typ == "eof" then
            return
        end
    end
end

local function get_file_name(header)
    local file_name
    for i, ele in ipairs(header) do
        file_name = string.match(ele, 'filename="(.*)"')
        if file_name and file_name ~= '' then
            -- Extract the filename from the path (handles both Windows '\' and Unix '/')
            return file_name:match("[^\\/]+$")
        end
    end
    return nil
end

local args = ngx.req.get_uri_args()

-- A pre-flight is a list of names -- 200 of them is well under 64KB. Anything
-- larger is not one, and client_max_body_size is 0 here, so reading it into
-- memory just because the endpoint asked nicely is a way to be told to allocate
-- until the worker dies. The upload path streams instead, which is why it needs
-- no equivalent.
local MAX_CHECK_BYTES = 1024 * 1024

-- Pre-flight: which of these names are already taken?
--
-- Answered before upload:new() on purpose -- that call takes the request socket
-- (upload_file.lua's req_socket), so building the streaming parser and then
-- replying without reading from it is exactly the ordering that goes wrong.
-- Deliberately no mkdir here: a question must not have side effects, or a
-- check would conjure the destination directory out of nothing.
if args.check == "1" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        -- Spilled past client_body_buffer_size, which a few hundred names will.
        local body_file = ngx.req.get_body_file()
        local size = body_file and lfs.attributes(body_file, "size")
        if size and size <= MAX_CHECK_BYTES then
            local fh = io.open(body_file, "rb")
            if fh then
                body = fh:read("*a")
                fh:close()
            end
        end
    end

    if not body or #body > MAX_CHECK_BYTES then
        ngx.log(ngx.ERR, "overwrite check needs a small JSON body")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local names = {}
    local payload = body and cjson.decode(body)
    if type(payload) == "table" and type(payload.names) == "table" then
        names = payload.names
    end

    local path, safe_path = resolve_dest_dir()
    if not safe_path then
        ngx.log(ngx.ERR, "refusing to check outside the data root: " .. tostring(ngx.var.store_path))
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    ngx.header.content_type = "application/json"
    -- encode_array, not cjson: an empty list has to reach the client as [] and
    -- cjson would render it as {} on the image we ship. Probed with `path`, not
    -- `safe_path` -- the latter is escaped for the shell, which lfs would take
    -- literally.
    ngx.say(json.encode_object({
        { "existing", json.encode_array(policy.conflicts(path, names, path_kind)) },
    }))
    return
end

local chunk_size = 4096
local form = upload:new(chunk_size)
form:set_timeout(5000)
local file
local store_path
local opened_path
local conflict_type
local ok, read_err = pcall(function()
    while true do
        local typ, res, err = form:read()

        if not typ then
            error("failed to read: " .. err)
        end

        if typ == "header" then
            local file_name = get_file_name(res)
            if file_name then
                file_name = policy.sanitize_name(file_name)
                if not file_name then
                    error("invalid filename")
                end

                local path, safe_path = resolve_dest_dir()
                if not safe_path then
                    error("destination path rejected: " .. tostring(ngx.var.store_path))
                end

                -- Decide before creating or truncating anything. A directory in
                -- the way is always a conflict: io.open cannot replace one, and
                -- ?overwrite=1 must not turn that into a bare 400.
                local existing = path_kind(path .. file_name)
                if existing and (existing == "directory"
                        or not policy.overwrite_allowed(ngx.var.uri, ngx.var.url_prefix, args)) then
                    conflict_type = existing
                    drain(form)
                    break
                end

                local ok, err = files.exec_command("mkdir -p " .. safe_path)
                if not ok then
                    error("failed to create directory: " .. err)
                end

                store_path = path .. file_name
                opened_path = store_path
                file = io.open(store_path, "wb+")
                if not file then
                    error("failed to open file: " .. store_path)
                end
            end
        elseif typ == "body" then
            if file then
                file:write(res)
            end
        elseif typ == "part_end" then
            if file then
                file:close()
                file = nil
                ngx.say("upload successfully!")
            end
        elseif typ == "eof" then
            break
        else
            -- do nothing
        end
    end
end)

-- Clean up partial file on any error (client disconnect, cancel, etc.)
if file then
    file:close()
end
-- Only ever the file this request opened: on the conflict path store_path is
-- still nil, and removing anything else here would delete the very file we
-- just refused to overwrite.
if opened_path and not ok then
    os.remove(opened_path)
    ngx.log(ngx.ERR, "upload aborted, removed partial file: " .. opened_path .. " - " .. tostring(read_err))
end
if not ok then
    ngx.log(ngx.ERR, "upload failed: " .. tostring(read_err))
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

-- The file is untouched; say so in the same shape move-copy.lua uses.
if conflict_type then
    ngx.header.content_type = "application/json"
    ngx.status = ngx.HTTP_CONFLICT
    ngx.say('{"exists":true,"type":"' .. conflict_type .. '"}')
end
