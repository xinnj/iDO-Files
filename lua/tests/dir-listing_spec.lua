-- Tests for dir-listing.lua
--
-- Run with:
--   LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/dir-listing_spec.lua

local ngx_mock = require("mock_ngx")
_G.ngx = ngx_mock
ngx_mock.log = function() end

-- Mock filesystem: path -> { mode = "directory" }, entries derived per directory.
local mock_fs_entries = {}
local mock_fs_attrs = {}

local function setup_mock_fs(entries)
    mock_fs_entries = {}
    mock_fs_attrs = {}
    for path, attr in pairs(entries) do
        mock_fs_attrs[path] = attr
        local parent, name = path:match("^(.*)/([^/]+)$")
        if parent then
            mock_fs_entries[parent] = mock_fs_entries[parent] or {}
            table.insert(mock_fs_entries[parent], name)
        end
    end
end

package.loaded["lfs"] = {
    dir = function(path)
        local entries = mock_fs_entries[path] or {}
        local i = 0
        return function()
            i = i + 1
            return entries[i]
        end
    end,
    attributes = function(path) return mock_fs_attrs[path] end,
    symlinkattributes = function(path) return mock_fs_attrs[path] end,
}

package.loaded["dir-listing"] = nil
local dir_listing = require("dir-listing")

local BASE = "/data/"

describe("dir-listing", function()
    describe("list_subdirs", function()
        it("lists immediate subdirectories sorted by name", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/zebra"] = { mode = "directory" },
                ["/data/download/apple"] = { mode = "directory" },
                ["/data/download/notes.txt"] = { mode = "file" },
            })

            local dirs = dir_listing.list_subdirs(BASE, "download", "")

            assert.are.equal(2, #dirs)
            assert.are.equal("apple", dirs[1].name)
            assert.are.equal("zebra", dirs[2].name)
        end)

        it("returns a bucket-relative rel_path with a leading slash", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/releases"] = { mode = "directory" },
            })

            local dirs = dir_listing.list_subdirs(BASE, "download", "")

            assert.are.equal("/releases", dirs[1].rel_path)
        end)

        it("nests rel_path for a subdirectory listing", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/team-a"] = { mode = "directory" },
                ["/data/download/team-a/releases"] = { mode = "directory" },
            })

            local dirs = dir_listing.list_subdirs(BASE, "download", "/team-a")

            assert.are.equal(1, #dirs)
            assert.are.equal("releases", dirs[1].name)
            assert.are.equal("/team-a/releases", dirs[1].rel_path)
        end)

        it("treats '/', '' and a leading slash as the bucket root", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/docs"] = { mode = "directory" },
            })

            for _, rel in ipairs({ "", "/", "//" }) do
                local dirs = dir_listing.list_subdirs(BASE, "download", rel)
                assert.are.equal(1, #dirs)
                assert.are.equal("/docs", dirs[1].rel_path)
            end
        end)

        it("reports has_children only for directories containing directories", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/deep"] = { mode = "directory" },
                ["/data/download/deep/nested"] = { mode = "directory" },
                ["/data/download/leaf"] = { mode = "directory" },
                ["/data/download/leaf/file.txt"] = { mode = "file" },
                ["/data/download/empty"] = { mode = "directory" },
            })

            local by_name = {}
            for _, entry in ipairs(dir_listing.list_subdirs(BASE, "download", "")) do
                by_name[entry.name] = entry
            end

            assert.is_true(by_name["deep"].has_children)
            assert.is_false(by_name["leaf"].has_children)
            assert.is_false(by_name["empty"].has_children)
        end)

        it("skips dot-files and dot-directories", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/.hidden"] = { mode = "directory" },
                ["/data/download/visible"] = { mode = "directory" },
            })

            local dirs = dir_listing.list_subdirs(BASE, "download", "")

            assert.are.equal(1, #dirs)
            assert.are.equal("visible", dirs[1].name)
        end)

        it("lists symlinked directories", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/linked"] = { mode = "directory" },
            })

            local dirs = dir_listing.list_subdirs(BASE, "download", "")

            assert.are.equal(1, #dirs)
            assert.are.equal("linked", dirs[1].name)
        end)

        it("handles non-ASCII directory names", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/测试目录"] = { mode = "directory" },
            })

            local dirs = dir_listing.list_subdirs(BASE, "download", "")

            assert.are.equal(1, #dirs)
            assert.are.equal("测试目录", dirs[1].name)
            assert.are.equal("/测试目录", dirs[1].rel_path)
        end)

        it("returns an empty list for a non-existent directory", function()
            setup_mock_fs({})

            assert.are.same({}, dir_listing.list_subdirs(BASE, "download", ""))
        end)

        it("returns an empty list when the path is a file", function()
            setup_mock_fs({
                ["/data/download/afile"] = { mode = "file" },
            })

            assert.are.same({}, dir_listing.list_subdirs(BASE, "download", "/afile"))
        end)

        it("rejects traversal with ..", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data"] = { mode = "directory" },
            })

            assert.are.same({}, dir_listing.list_subdirs(BASE, "download", "/../../etc"))
            assert.are.same({}, dir_listing.list_subdirs(BASE, "download", ".."))
        end)

        it("rejects buckets outside the allow-list", function()
            setup_mock_fs({
                ["/data/internal-download"] = { mode = "directory" },
                ["/data/internal-download/secret"] = { mode = "directory" },
            })

            assert.are.same({}, dir_listing.list_subdirs(BASE, "internal-download", ""))
            assert.are.same({}, dir_listing.list_subdirs(BASE, "hacked", ""))
            assert.are.same({}, dir_listing.list_subdirs(BASE, nil, ""))
        end)

        it("lists all three buckets", function()
            setup_mock_fs({
                ["/data/download"] = { mode = "directory" },
                ["/data/download/a"] = { mode = "directory" },
                ["/data/public"] = { mode = "directory" },
                ["/data/public/b"] = { mode = "directory" },
                ["/data/archive"] = { mode = "directory" },
                ["/data/archive/c"] = { mode = "directory" },
            })

            assert.are.equal("a", dir_listing.list_subdirs(BASE, "download", "")[1].name)
            assert.are.equal("b", dir_listing.list_subdirs(BASE, "public", "")[1].name)
            assert.are.equal("c", dir_listing.list_subdirs(BASE, "archive", "")[1].name)
        end)
    end)
end)
