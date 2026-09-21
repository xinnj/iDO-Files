-- JSON encoding helpers that do not depend on cjson's empty-array extensions.
--
-- cjson.empty_array is an OpenResty-fork addition. The image is nginx + ngx_lua
-- with Alpine's lua5.1-cjson 2.1.0, which has no cjson.empty_array, no
-- cjson.empty_array_mt, no encode_empty_table_as_object, and ignores __jsontype
-- -- so an empty Lua table has no way to reach the wire as [].
--
-- The obvious `t[key] = cjson.empty_array` fails silently there: assigning nil
-- removes the key rather than raising, so an empty rule list vanished from the
-- payload and a role whose allow and deny were both empty was written to disk
-- as the bare {} that authorize.read_config() then refuses on the next start.
--
-- These helpers spell the array out and hand each element to cjson, so escaping
-- stays cjson's job and the result is identical on every cjson.

local cjson = require "cjson.safe"

local M = {}

-- A JSON array for `list`, [] when there is nothing in it.
function M.encode_array(list)
    if type(list) ~= "table" then
        return "[]"
    end

    local parts = {}
    for i = 1, #list do
        parts[i] = cjson.encode(list[i])
    end

    return "[" .. table.concat(parts, ",") .. "]"
end

-- A JSON object from ordered { key, fragment } pairs, where `fragment` is
-- already-encoded JSON. A field whose fragment is nil is omitted, which is how
-- an absent value stays absent instead of becoming null.
function M.encode_object(fields)
    local parts = {}
    for i = 1, #fields do
        local key, fragment = fields[i][1], fields[i][2]
        if fragment ~= nil then
            parts[#parts + 1] = cjson.encode(key) .. ":" .. fragment
        end
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

return M
