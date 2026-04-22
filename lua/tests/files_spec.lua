-- Tests for files.lua
local ngx_mock = require("mock_ngx")

-- Set up globals before requiring files module
_G.ngx = ngx_mock
ngx_mock.var.url_prefix = "/"
ngx_mock.var.document_root = "/tmp/test_files"

-- Fresh require of files module
package.loaded["files"] = nil
local files = require("files")

describe("files module", function()

    describe("combine_paths", function()
        it("combines two paths correctly", function()
            local result = files.combine_paths("/data/public", "folder/file.txt")
            assert.are.equal("/data/public/folder/file.txt", result)
        end)

        it("removes trailing slash from first path", function()
            local result = files.combine_paths("/data/public/", "file.txt")
            assert.are.equal("/data/public/file.txt", result)
        end)

        it("removes leading slash from second path", function()
            local result = files.combine_paths("/data", "/public/file.txt")
            assert.are.equal("/data/public/file.txt", result)
        end)
    end)

    describe("sanitize_path", function()
        it("accepts valid public path", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/public/folder/file.txt")
            assert.is_not_nil(result)
            assert.is_nil(err)
        end)

        it("accepts valid download path", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/download/file.txt")
            assert.is_not_nil(result)
            assert.is_nil(err)
        end)

        it("accepts valid archive path", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/archive/file.txt")
            assert.is_not_nil(result)
            assert.is_nil(err)
        end)

        it("rejects path with ..", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/public/../../../etc/passwd")
            assert.is_nil(result)
            assert.are.equal("Path contains invalid '..' sequence", err)
        end)

        it("rejects path outside document root", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/etc/passwd")
            assert.is_nil(result)
            assert.are.equal("Path outside document root", err)
        end)

        it("escapes single quotes for shell safety", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/public/file's name.txt")
            assert.is_not_nil(result)
            assert.is_string(result)
            -- Single quotes should be escaped (file'\''s name)
            assert.matches("file'\\''s name", result)
        end)
    end)

    describe("sanitize_path with url_prefix", function()
        it("accepts path with matching url_prefix", function()
            ngx_mock.var.url_prefix = "/myteam"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/myteam/public/file.txt")
            assert.is_not_nil(result)
            assert.is_nil(err)
        end)

        it("rejects path without matching url_prefix", function()
            ngx_mock.var.url_prefix = "/myteam"
            package.loaded["files"] = nil
            files = require("files")
            
            local result, err = files.sanitize_path("/data/public/file.txt")
            assert.is_nil(result)
            assert.are.equal("Path outside document root", err)
        end)
    end)

    describe("exec_command", function()
        it("returns true for successful command", function()
            local success, err = files.exec_command("echo test")
            assert.is_true(success)
            assert.is_nil(err)
        end)

        it("captures command output", function()
            local success = files.exec_command("printf hello")
            assert.is_true(success)
        end)
    end)

    describe("delete", function()
        it("deletes an existing file", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            os.execute("printf 'test' > /tmp/test_delete.txt")
            local success, err = files.delete("/tmp/test_delete.txt")
            assert.is_true(success)
            assert.is_nil(err)
        end)

        it("handles non-existent file gracefully", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local success = files.delete("/tmp/nonexistent_file_xyz.txt")
            assert.is_true(success)
        end)
    end)

    describe("move_copy", function()
        it("copies a file to new location", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            os.execute("mkdir -p /tmp/test_move_src /tmp/test_move_dst 2>/dev/null")
            os.execute("printf 'test content' > /tmp/test_move_src/testfile.txt")

            local source = "/tmp/test_move_src/testfile.txt"
            local dest = "/tmp/test_move_dst/testfile_copy.txt"

            local success, err = files.move_copy(source, dest, "copy")
            assert.is_true(success)
            assert.is_nil(err)

            local f = io.open(dest, "r")
            assert.is_not_nil(f)
            f:close()

            os.execute("rm -rf /tmp/test_move_src /tmp/test_move_dst")
        end)

        it("moves a file to new location", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            os.execute("mkdir -p /tmp/test_move_src2 /tmp/test_move_dst2 2>/dev/null")
            os.execute("printf 'test content' > /tmp/test_move_src2/file.txt")

            local source = "/tmp/test_move_src2/file.txt"
            local dest = "/tmp/test_move_dst2/file_moved.txt"

            local success, err = files.move_copy(source, dest, "move")
            assert.is_true(success)
            assert.is_nil(err)

            local f = io.open(dest, "r")
            assert.is_not_nil(f)
            f:close()

            local src = io.open(source, "r")
            assert.is_nil(src)

            os.execute("rm -rf /tmp/test_move_src2 /tmp/test_move_dst2")
        end)

        it("renames file by moving to new name", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            os.execute("mkdir -p /tmp/test_rename 2>/dev/null")
            os.execute("printf 'test' > /tmp/test_rename/oldname.txt")

            local source = "/tmp/test_rename/oldname.txt"
            local dest = "/tmp/test_rename/newname.txt"

            local success, err = files.move_copy(source, dest, "move")
            assert.is_true(success)
            assert.is_nil(err)

            assert.is_nil(io.open(source, "r"))
            assert.is_not_nil(io.open(dest, "r"))

            os.execute("rm -rf /tmp/test_rename")
        end)

        it("returns error for non-existent source", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            local success, err = files.move_copy(
                "/tmp/nonexistent_source_xyz.txt",
                "/tmp/dest.txt",
                "copy"
            )
            assert.is_false(success)
            assert.is_string(err)
        end)

        it("returns error for invalid action", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")
            
            os.execute("printf 'test' > /tmp/test_invalid.txt")
            local success, err = files.move_copy(
                "/tmp/test_invalid.txt",
                "/tmp/dest.txt",
                "invalid_action"
            )
            assert.is_false(success)
            assert.is_string(err)
            os.execute("rm -f /tmp/test_invalid.txt")
        end)
    end)
end)
