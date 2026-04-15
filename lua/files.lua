local _M = {}

function _M.exec_command(command)
    ngx.log(ngx.NOTICE, "Executing command: " .. command)
    local handle, err = io.popen(command .. " 2>&1; echo \"EXIT_CODE:$?\"", 'r')
    if not handle then
        return false, "Failed to execute command: " .. (err or "unknown error")
    end

    local output = handle:read('*a')
    handle:close()

    -- Parse the exit code from the output (more reliable method)
    local exit_code_match = output:match("EXIT_CODE:(%d+)")
    local actual_exit_code = exit_code_match and tonumber(exit_code_match) or -1

    -- Remove the exit code marker from the output
    local clean_output = output:gsub("EXIT_CODE:%d+", ""):gsub("%s+$", "")

    if actual_exit_code ~= 0 then
        return false, clean_output
    end

    return true
end

-- Return true if path is directory/file, otherwise return false
local function check_path(path)
    local success = _M.exec_command("test -d '" .. path .. "'")
    if success then
        return true, "directory"
    end

    success = _M.exec_command("test -f '" .. path .. "'")
    if success then
        return true, "file"
    end

    return false
end

function _M.combine_paths(path1, path2)
    -- Remove trailing slashes from path1
    path1 = path1:gsub("/+$", "")
    -- Remove leading slashes from path2
    path2 = path2:gsub("^/+", "")
    return path1 .. "/" .. path2
end

function _M.sanitize_path(input_path)
    local unescape_path = ngx.unescape_uri(input_path)
    -- Security checks
    if unescape_path:match("%.%.") then
        return nil, "Path contains invalid '..' sequence"
    end

    if not (unescape_path:match("^/data/download/") or unescape_path:match("^/data/public/") or unescape_path:match("^/data/archive/")) then
        return nil, "Path outside document root"
    end

    return unescape_path:gsub("'", "'\\''")
end

function _M.delete(path)
    return _M.exec_command("rm -rf -- '" .. path .. "'")
end

function _M.move_copy(source_path, target_path, action)
    local exist = check_path(source_path)
    if not exist then
        return false, "Path not accessible: " .. source_path
    end

    local commands
    if action == "move" then
        local exist, type = check_path(target_path)
        if exist and type == "directory" then
            -- If target is an existing directory, merge source into target directory
            commands = {
                "cp -af -- '" .. source_path .. "' \"$(dirname '" .. target_path .. "')/\"",
                "rm -rf -- '" .. source_path .. "'"
            }
        else
            commands = {
                "mkdir -p -- \"$(dirname '" .. target_path .. "')\"",
                "mv -f -- '" .. source_path .. "' \"$(dirname '" .. target_path .. "')/\""
            }
        end
    elseif action == "copy" then
        commands = {
            "mkdir -p -- \"$(dirname '" .. target_path .. "')\"",
            "cp -af -- '" .. source_path .. "' \"$(dirname '" .. target_path .. "')/\""
        }
    else
        return false, "Invalid action: " .. action
    end

    for _, command in ipairs(commands) do
        local success, err_msg = _M.exec_command(command)
        if not success then
            return false, err_msg
        end
    end
    return true
end

return _M