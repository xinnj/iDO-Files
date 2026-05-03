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
            local dest = "/tmp/test_move_dst2/file.txt"

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

            local success, err = files.move_copy(source, dest, "rename")
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

        -- Tests with existing destination (no force)
        it("copy: returns exists when dest file already present", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_cp_exist 2>/dev/null")
            os.execute("printf 'src' > /tmp/test_cp_exist/src.txt")
            os.execute("printf 'dst' > /tmp/test_cp_exist/dst.txt")

            local success, err, ctype = files.move_copy(
                "/tmp/test_cp_exist/src.txt",
                "/tmp/test_cp_exist/dst.txt",
                "copy"
            )
            assert.is_nil(success)
            assert.are.equal("exists", err)
            assert.are.equal("file", ctype)

            os.execute("rm -rf /tmp/test_cp_exist")
        end)

        it("copy: succeeds when dest file exists and force=true", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_cp_force 2>/dev/null")
            os.execute("printf 'src content' > /tmp/test_cp_force/src.txt")
            os.execute("printf 'old content' > /tmp/test_cp_force/dst.txt")

            local success, err = files.move_copy(
                "/tmp/test_cp_force/src.txt",
                "/tmp/test_cp_force/dst.txt",
                "copy",
                true
            )
            assert.is_true(success)
            assert.is_nil(err)

            -- Verify content was overwritten
            local f = io.open("/tmp/test_cp_force/dst.txt", "r")
            local content = f:read("*a")
            f:close()
            assert.are.equal("src content", content)

            -- Source should still exist (copy)
            assert.is_not_nil(io.open("/tmp/test_cp_force/src.txt", "r"))

            os.execute("rm -rf /tmp/test_cp_force")
        end)

        it("copy: returns exists when dest folder already present", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_cp_fexist/src /tmp/test_cp_fexist/dst 2>/dev/null")
            os.execute("printf 'a' > /tmp/test_cp_fexist/src/a.txt")

            local success, err, ctype = files.move_copy(
                "/tmp/test_cp_fexist/src",
                "/tmp/test_cp_fexist/dst",
                "copy"
            )
            assert.is_nil(success)
            assert.are.equal("exists", err)
            assert.are.equal("directory", ctype)

            os.execute("rm -rf /tmp/test_cp_fexist")
        end)

        it("copy: merges when dest folder exists and force=true", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_cp_src/folder /tmp/test_cp_dst/folder 2>/dev/null")
            os.execute("printf 'a' > /tmp/test_cp_src/folder/a.txt")
            os.execute("printf 'b' > /tmp/test_cp_dst/folder/b.txt")

            local success, err = files.move_copy(
                "/tmp/test_cp_src/folder",
                "/tmp/test_cp_dst/folder",
                "copy",
                true
            )
            assert.is_true(success)
            assert.is_nil(err)

            -- Both files should exist (merged into dest)
            assert.is_not_nil(io.open("/tmp/test_cp_dst/folder/a.txt", "r"))
            assert.is_not_nil(io.open("/tmp/test_cp_dst/folder/b.txt", "r"))
            -- Source still exists (copy)
            assert.is_not_nil(io.open("/tmp/test_cp_src/folder/a.txt", "r"))

            os.execute("rm -rf /tmp/test_cp_src /tmp/test_cp_dst")
        end)

        it("move: returns exists when dest file already present", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_mv_exist 2>/dev/null")
            os.execute("printf 'src' > /tmp/test_mv_exist/src.txt")
            os.execute("printf 'dst' > /tmp/test_mv_exist/dst.txt")

            local success, err, ctype = files.move_copy(
                "/tmp/test_mv_exist/src.txt",
                "/tmp/test_mv_exist/dst.txt",
                "move"
            )
            assert.is_nil(success)
            assert.are.equal("exists", err)
            assert.are.equal("file", ctype)

            os.execute("rm -rf /tmp/test_mv_exist")
        end)

        it("move: overwrites when dest file exists and force=true", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_mv_src /tmp/test_mv_dst 2>/dev/null")
            os.execute("printf 'src content' > /tmp/test_mv_src/report.txt")
            os.execute("printf 'old' > /tmp/test_mv_dst/report.txt")

            local success, err = files.move_copy(
                "/tmp/test_mv_src/report.txt",
                "/tmp/test_mv_dst/report.txt",
                "move",
                true
            )
            assert.is_true(success)
            assert.is_nil(err)

            local f = io.open("/tmp/test_mv_dst/report.txt", "r")
            assert.are.equal("src content", f:read("*a"))
            f:close()
            -- Source should be gone (move)
            assert.is_nil(io.open("/tmp/test_mv_src/report.txt", "r"))

            os.execute("rm -rf /tmp/test_mv_src /tmp/test_mv_dst")
        end)

        it("move: returns exists when dest folder already present", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_mv_fexist/src /tmp/test_mv_fexist/dst 2>/dev/null")
            os.execute("printf 'a' > /tmp/test_mv_fexist/src/a.txt")

            local success, err, ctype = files.move_copy(
                "/tmp/test_mv_fexist/src",
                "/tmp/test_mv_fexist/dst",
                "move"
            )
            assert.is_nil(success)
            assert.are.equal("exists", err)
            assert.are.equal("directory", ctype)

            os.execute("rm -rf /tmp/test_mv_fexist")
        end)

        it("move: merges when dest folder exists and force=true", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_mv_src2/data /tmp/test_mv_dst2/data 2>/dev/null")
            os.execute("printf 'a' > /tmp/test_mv_src2/data/a.txt")
            os.execute("printf 'b' > /tmp/test_mv_dst2/data/b.txt")

            local success, err = files.move_copy(
                "/tmp/test_mv_src2/data",
                "/tmp/test_mv_dst2/data",
                "move",
                true
            )
            assert.is_true(success)
            assert.is_nil(err)

            -- Both files should exist in dest (merged)
            assert.is_not_nil(io.open("/tmp/test_mv_dst2/data/a.txt", "r"))
            assert.is_not_nil(io.open("/tmp/test_mv_dst2/data/b.txt", "r"))
            -- Source should be gone (move)
            assert.is_nil(io.open("/tmp/test_mv_src2/data", "r"))

            os.execute("rm -rf /tmp/test_mv_src2 /tmp/test_mv_dst2")
        end)

        it("rename: returns exists when dest file already present", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_rn_exist 2>/dev/null")
            os.execute("printf 'src' > /tmp/test_rn_exist/old.txt")
            os.execute("printf 'dst' > /tmp/test_rn_exist/new.txt")

            local success, err, ctype = files.move_copy(
                "/tmp/test_rn_exist/old.txt",
                "/tmp/test_rn_exist/new.txt",
                "rename"
            )
            assert.is_nil(success)
            assert.are.equal("exists", err)
            assert.are.equal("file", ctype)

            os.execute("rm -rf /tmp/test_rn_exist")
        end)

        it("rename: overwrites when dest file exists and force=true", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_rn_force 2>/dev/null")
            os.execute("printf 'src content' > /tmp/test_rn_force/old.txt")
            os.execute("printf 'old' > /tmp/test_rn_force/new.txt")

            local success, err = files.move_copy(
                "/tmp/test_rn_force/old.txt",
                "/tmp/test_rn_force/new.txt",
                "rename",
                true
            )
            assert.is_true(success)
            assert.is_nil(err)

            local f = io.open("/tmp/test_rn_force/new.txt", "r")
            assert.are.equal("src content", f:read("*a"))
            f:close()
            -- Old name should be gone
            assert.is_nil(io.open("/tmp/test_rn_force/old.txt", "r"))

            os.execute("rm -rf /tmp/test_rn_force")
        end)

        it("rename: returns exists when dest folder already present", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_rn_fexist/old /tmp/test_rn_fexist/new 2>/dev/null")
            os.execute("printf 'a' > /tmp/test_rn_fexist/old/a.txt")
            os.execute("printf 'b' > /tmp/test_rn_fexist/new/b.txt")

            local success, err, ctype = files.move_copy(
                "/tmp/test_rn_fexist/old",
                "/tmp/test_rn_fexist/new",
                "rename"
            )
            assert.is_nil(success)
            assert.are.equal("exists", err)
            assert.are.equal("directory", ctype)

            os.execute("rm -rf /tmp/test_rn_fexist")
        end)

        it("rename: replaces dest folder entirely when force=true", function()
            ngx_mock.var.url_prefix = "/"
            package.loaded["files"] = nil
            files = require("files")

            os.execute("mkdir -p /tmp/test_rn_replace/old /tmp/test_rn_replace/new 2>/dev/null")
            os.execute("printf 'a' > /tmp/test_rn_replace/old/a.txt")
            os.execute("printf 'b' > /tmp/test_rn_replace/new/b.txt")

            local success, err = files.move_copy(
                "/tmp/test_rn_replace/old",
                "/tmp/test_rn_replace/new",
                "rename",
                true
            )
            assert.is_true(success)
            assert.is_nil(err)

            -- Only a.txt should exist (new was replaced), not b.txt
            assert.is_not_nil(io.open("/tmp/test_rn_replace/new/a.txt", "r"))
            assert.is_nil(io.open("/tmp/test_rn_replace/new/b.txt", "r"))
            -- Old name should be gone
            assert.is_nil(io.open("/tmp/test_rn_replace/old", "r"))

            os.execute("rm -rf /tmp/test_rn_replace")
        end)
    end)

    describe("check_path", function()
        it("returns true, 'file' for an existing file", function()
            os.execute("mkdir -p /tmp/test_check 2>/dev/null")
            os.execute("printf 'x' > /tmp/test_check/f.txt")

            local exists, ftype = files.check_path("/tmp/test_check/f.txt")
            assert.is_true(exists)
            assert.are.equal("file", ftype)

            os.execute("rm -rf /tmp/test_check")
        end)

        it("returns true, 'directory' for an existing directory", function()
            os.execute("mkdir -p /tmp/test_check_dir 2>/dev/null")

            local exists, ftype = files.check_path("/tmp/test_check_dir")
            assert.is_true(exists)
            assert.are.equal("directory", ftype)

            os.execute("rm -rf /tmp/test_check_dir")
        end)

        it("returns false for a non-existent path", function()
            local exists = files.check_path("/tmp/nonexistent_xyz_check")
            assert.is_false(exists)
        end)
    end)
end)
