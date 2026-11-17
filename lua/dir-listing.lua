-- Shared directory enumeration for the admin APIs.
--
-- Both the housekeeping rule editor and the access-control path picker list the
-- immediate subdirectories of a storage bucket. The traversal rules — which
-- buckets are listable, what counts as an escape attempt, and how symlinks are
-- treated — live here so the two callers cannot drift apart.

local lfs = require "lfs"

local _M = {}

-- internal-download and internal-archive are deliberately excluded: they are
-- symlinks used internally by the file server, not browsable locations.
_M.BUCKETS = { download = true, archive = true, public = true }

local function is_directory(path)
    local attr = lfs.symlinkattributes(path)
    return attr ~= nil and attr.mode == "directory"
end

local function has_subdirectory(path)
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            if is_directory(path .. "/" .. entry) then
                return true
            end
        end
    end
    return false
end

-- Absolute path for <base_path><bucket>/<rel_path>, or nil plus a reason.
--
-- Shared by every admin API that takes a bucket + relative path, so the
-- traversal rules have one implementation. rel_path "", "/" and "/a/b" are all
-- accepted; extra leading slashes are ignored. lfs.attributes (not
-- symlinkattributes) here: the bucket root may itself be a symlink.
function _M.resolve_dir(base_path, bucket, rel_path)
    if not _M.BUCKETS[bucket] then
        return nil, "invalid bucket"
    end

    local clean_path = (rel_path or ""):gsub("^/+", "")
    if clean_path:find("%.%.") then
        return nil, "invalid path"
    end

    local fs_path
    if clean_path == "" then
        fs_path = base_path .. bucket
    else
        fs_path = base_path .. bucket .. "/" .. clean_path
    end

    local attr = lfs.attributes(fs_path)
    if not attr or attr.mode ~= "directory" then
        return nil, "not found"
    end

    return fs_path, nil
end

-- Immediate subdirectories of <base_path><bucket>/<rel_path>.
--
-- rel_path is bucket-relative: "", "/" and "/a/b" are all accepted. Returns a
-- list of { name, rel_path, has_children } sorted by name, where rel_path is
-- bucket-relative with a leading slash ("/a/b"). Returns an empty list when the
-- directory is missing or is not a directory.
--
-- Traversal outside the bucket is impossible by construction: the caller-supplied
-- path is appended after a hard-coded bucket, and any ".." is rejected in
-- resolve_dir.
function _M.list_subdirs(base_path, bucket, rel_path)
    local dirs = {}

    local fs_path = _M.resolve_dir(base_path, bucket, rel_path)
    if not fs_path then
        return dirs
    end

    local clean_path = (rel_path or ""):gsub("^/+", "")

    for entry in lfs.dir(fs_path) do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local full = fs_path .. "/" .. entry
            if is_directory(full) then
                local child_rel
                if clean_path == "" then
                    child_rel = "/" .. entry
                else
                    child_rel = "/" .. clean_path .. "/" .. entry
                end

                table.insert(dirs, {
                    name = entry,
                    rel_path = child_rel,
                    has_children = has_subdirectory(full),
                })
            end
        end
    end

    table.sort(dirs, function(a, b) return a.name < b.name end)
    return dirs
end

return _M
