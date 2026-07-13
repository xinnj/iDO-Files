local upload = require "upload_file"
local files = require "files"

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

local chunk_size = 4096
local form = upload:new(chunk_size)
form:set_timeout(5000)
local file
local store_path
local ok, read_err = pcall(function()
    while true do
        local typ, res, err = form:read()

        if not typ then
            error("failed to read: " .. err)
        end

        if typ == "header" then
            local file_name = get_file_name(res)
            if file_name then
                -- Allow letters (Unicode), numbers, spaces, underscores, hyphens, and dots
                file_name = file_name:gsub("[^%w\u{4E00}-\u{9FFF}\u{3040}-\u{309F}\u{30A0}-\u{30FF}\u{AC00}-\u{D7AF}%._-]", "")
                if file_name == "" then
                    error("invalid filename")
                end

                -- Decode URL-encoded path (e.g., Chinese characters)
                local decoded_path = ngx.unescape_uri(ngx.var.store_path)
                local path = decoded_path .. (decoded_path:sub(-1) == "/" and "" or "/")
                local safe_path = files.sanitize_path(path)
                local ok, err = files.exec_command("mkdir -p " .. safe_path)
                if not ok then
                    error("failed to create directory: " .. err)
                end

                store_path = path .. file_name
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
if store_path and not ok then
    os.remove(store_path)
    ngx.log(ngx.ERR, "upload aborted, removed partial file: " .. store_path .. " - " .. tostring(read_err))
end
if not ok then
    ngx.log(ngx.ERR, "upload failed: " .. tostring(read_err))
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end
