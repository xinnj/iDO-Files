-- Upload overwrite policy.
--
-- Split out of upload.lua so the two rules that are easy to get wrong are
-- testable without an ngx, a socket or a filesystem: which request channel is
-- allowed to replace an existing file, and what a client may ask us about.
--
-- Note this is a *consent* protocol, not an authorization control: `overwrite`
-- is a query argument the client controls, so anyone who can POST can send it.
-- Its value is that a stale cached client can no longer silently destroy a
-- file, and that the destructive act is explicit on the wire. Do not grow it
-- into something a reader would mistake for a permission check.

local M = {}

-- Characters a filename may keep. Copied verbatim from the streaming handler,
-- which is where uploads have always been sanitized; the \u{...} escapes need
-- Lua 5.3+ and are what lets CJK names through.
local DISALLOWED = "[^%w\u{4E00}-\u{9FFF}\u{3040}-\u{309F}\u{30A0}-\u{30FF}\u{AC00}-\u{D7AF}%._-]"

-- Strip the configured URL prefix from a request URI.
function M.bucket_relative(uri, prefix)
    uri = uri or ""
    if prefix and prefix ~= "" and prefix ~= "/" then
        local trimmed = prefix:gsub("/$", "")
        if trimmed ~= "" and uri:sub(1, #trimmed) == trimmed then
            uri = uri:sub(#trimmed + 1)
        end
    end
    return (uri:gsub("^/", ""))
end

-- True for the /internal-download/ location, the documented unauthenticated
-- service-to-service channel.
--
-- This has to be decided from the URI and by first path segment. It cannot come
-- from $store_path: that location rewrites store_path to the download bucket,
-- so the filesystem path carries no trace of which location matched. And it
-- cannot be a substring search, or a real bucket subdirectory that happens to
-- be named "internal-download" would be exempted too.
function M.is_internal_channel(uri, prefix)
    return M.bucket_relative(uri, prefix):match("^([^/]+)") == "internal-download"
end

-- Whether this request may replace an existing file.
--
-- The internal channel is exempt so service-to-service uploads keep working
-- exactly as they did; every browser-facing request has to say so. The flag is
-- spelled "1" here, unlike move-copy.lua's `force == "true"` -- the two are
-- deliberately different, not a typo to reconcile.
function M.overwrite_allowed(uri, prefix, args)
    if M.is_internal_channel(uri, prefix) then
        return true
    end
    return type(args) == "table" and args.overwrite == "1"
end

-- Reduce a raw filename to something safe to append to a directory path, or
-- nil when nothing usable survives. Dots are allowed, so "." and ".." have to
-- be rejected on their own account.
function M.sanitize_name(raw)
    if type(raw) ~= "string" then
        return nil
    end

    local name = raw:gsub(DISALLOWED, "")
    if name == "" or name == "." or name == ".." then
        return nil
    end

    return name
end

-- Which of `names` already exist in `dir`, as { { name = ..., type = ... } }.
-- `exists(path)` returns nil, "file" or "directory", injected so the caller
-- owns the filesystem.
function M.conflicts(dir, names, exists)
    local found = {}
    if type(names) ~= "table" then
        return found
    end

    dir = dir or ""
    if dir ~= "" and dir:sub(-1) ~= "/" then
        dir = dir .. "/"
    end

    for _, raw in ipairs(names) do
        local name = M.sanitize_name(raw)
        if name then
            local kind = exists(dir .. name)
            if kind then
                found[#found + 1] = { name = name, type = kind }
            end
        end
    end

    return found
end

return M
