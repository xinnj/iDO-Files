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

-- Immediate subdirectories of <base_path><bucket>/<rel_path>.
--
-- rel_path is bucket-relative: "", "/" and "/a/b" are all accepted. Returns a
-- list of { name, rel_path, has_children } sorted by name, where rel_path is
-- bucket-relative with a leading slash ("/a/b"). Returns an empty list when the
-- directory is missing or is not a directory.
--
-- Traversal outside the bucket is impossible by construction: the caller-supplied
-- path is appended after a hard-coded bucket, and any ".." is rejected here.
function _M.list_subdirs(base_path, bucket, rel_path)
    local dirs = {}

    if not _M.BUCKETS[bucket] then
        return dirs
    end

    -- Strip every leading slash, so "//download//docs" style paths from a
    -- sloppy URL resolve to the same place as well-formed ones.
    local clean_path = (rel_path or ""):gsub("^/+", "")
    if clean_path:find("%.%.") then
        return dirs
    end

    local fs_path
    if clean_path == "" then
        fs_path = base_path .. bucket
    else
        fs_path = base_path .. bucket .. "/" .. clean_path
    end

    -- lfs.attributes (not symlinkattributes) here: the bucket root may itself
    -- be reached through a symlink and that is fine.
    local attr = lfs.attributes(fs_path)
    if not attr or attr.mode ~= "directory" then
        return dirs
    end

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
