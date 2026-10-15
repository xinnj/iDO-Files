-- Specs for the upload overwrite policy.
--
-- This module is deliberately free of ngx globals so the two rules that are
-- easy to get wrong -- which request channel is exempt, and what counts as an
-- explicit consent to overwrite -- are pinned here rather than only end to end.

local policy = require("upload-policy")

describe("bucket_relative", function()
    it("strips a multi-segment url prefix", function()
        assert.are.equal("download/a", policy.bucket_relative("/myteam/download/a", "/myteam/"))
    end)

    it("handles the root prefix", function()
        assert.are.equal("download/a", policy.bucket_relative("/download/a", "/"))
    end)

    it("strips a prefix that is not slash-terminated", function()
        assert.are.equal("download/a", policy.bucket_relative("/myteam/download/a", "/myteam"))
    end)

    it("falls back to the bare uri when the prefix does not match", function()
        assert.are.equal("download/a", policy.bucket_relative("/download/a", "/myteam/"))
    end)

    it("does not raise on a nil uri or prefix", function()
        assert.are.equal("", policy.bucket_relative(nil, "/"))
        assert.are.equal("download/a", policy.bucket_relative("/download/a", nil))
    end)
end)

describe("is_internal_channel", function()
    it("recognises the internal-download location", function()
        assert.is_true(policy.is_internal_channel("/internal-download/a", "/"))
    end)

    it("recognises it under a url prefix", function()
        assert.is_true(policy.is_internal_channel("/myteam/internal-download/a", "/myteam/"))
    end)

    it("recognises it with no trailing path", function()
        assert.is_true(policy.is_internal_channel("/internal-download", "/"))
    end)

    -- The trap: store_path is rewritten to the download bucket for
    -- internal-download, so the path cannot tell the locations apart -- and a
    -- substring search would exempt a real directory that happens to be named
    -- internal-download.
    it("does not exempt a bucket subdirectory with the same name", function()
        assert.is_false(policy.is_internal_channel("/download/internal-download/a", "/"))
        assert.is_false(policy.is_internal_channel("/myteam/download/internal-download/a", "/myteam/"))
    end)

    it("does not exempt the other buckets", function()
        assert.is_false(policy.is_internal_channel("/download/a", "/"))
        assert.is_false(policy.is_internal_channel("/public/a", "/"))
        assert.is_false(policy.is_internal_channel("/archive/a", "/"))
    end)

    it("does not raise on a nil uri or prefix", function()
        assert.is_false(policy.is_internal_channel(nil, "/"))
        assert.is_false(policy.is_internal_channel("/download/a", nil))
    end)
end)

describe("overwrite_allowed", function()
    it("always allows the service-to-service channel", function()
        assert.is_true(policy.overwrite_allowed("/internal-download/a", "/", {}))
    end)

    it("refuses a browser upload that did not ask", function()
        assert.is_false(policy.overwrite_allowed("/download/a", "/", {}))
        assert.is_false(policy.overwrite_allowed("/download/a", "/", { check = "1" }))
    end)

    it("allows a browser upload that asked", function()
        assert.is_true(policy.overwrite_allowed("/download/a", "/", { overwrite = "1" }))
    end)

    -- The sibling flag in move-copy.lua is spelled `force == "true"`. This one
    -- is deliberately `== "1"`: pin it so nobody "fixes" one into the other.
    it("only accepts the exact flag value", function()
        assert.is_false(policy.overwrite_allowed("/download/a", "/", { overwrite = "true" }))
        assert.is_false(policy.overwrite_allowed("/download/a", "/", { overwrite = 1 }))
        assert.is_false(policy.overwrite_allowed("/download/a", "/", { overwrite = "yes" }))
    end)
end)

describe("sanitize_name", function()
    it("keeps ordinary names", function()
        assert.are.equal("notes.txt", policy.sanitize_name("notes.txt"))
        assert.are.equal("a_b-c.txt", policy.sanitize_name("a_b-c.txt"))
    end)

    it("keeps CJK names", function()
        assert.are.equal("中文测试文件.txt", policy.sanitize_name("中文测试文件.txt"))
    end)

    it("drops path separators rather than traversing", function()
        assert.are.equal("ab.txt", policy.sanitize_name("a/b.txt"))
        assert.are.equal("ab.txt", policy.sanitize_name("a\\b.txt"))
    end)

    it("drops quotes and shell metacharacters", function()
        assert.are.equal("ab.txt", policy.sanitize_name("a'b.txt"))
        assert.are.equal("ab.txt", policy.sanitize_name("a;b.txt"))
        assert.are.equal("ab.txt", policy.sanitize_name("a$(b).txt"))
    end)

    it("rejects traversal and empty results", function()
        assert.is_nil(policy.sanitize_name(".."))
        assert.is_nil(policy.sanitize_name("."))
        assert.is_nil(policy.sanitize_name(""))
        assert.is_nil(policy.sanitize_name("///"))
        assert.is_nil(policy.sanitize_name(nil))
    end)
end)

describe("conflicts", function()
    local function probe(existing)
        return function(path)
            return existing[path]
        end
    end

    it("returns nothing when no name is taken", function()
        local found = policy.conflicts("/data/download/", { "a.txt", "b.txt" }, probe({}))
        assert.are.equal(0, #found)
    end)

    it("reports only the names that exist, with their type", function()
        local found = policy.conflicts(
            "/data/download/",
            { "a.txt", "b.txt", "c" },
            probe({
                ["/data/download/a.txt"] = "file",
                ["/data/download/c"] = "directory",
            })
        )
        assert.are.equal(2, #found)
        assert.are.equal("a.txt", found[1].name)
        assert.are.equal("file", found[1].type)
        assert.are.equal("c", found[2].name)
        assert.are.equal("directory", found[2].type)
    end)

    it("joins the directory and name exactly once", function()
        local seen = {}
        policy.conflicts("/data/download", { "a.txt" }, function(path)
            seen[#seen + 1] = path
            return nil
        end)
        assert.are.equal("/data/download/a.txt", seen[1])
    end)

    it("skips names that sanitize away", function()
        local seen = {}
        policy.conflicts("/data/download/", { "..", ".", "", "ok.txt" }, function(path)
            seen[#seen + 1] = path
            return nil
        end)
        assert.are.equal(1, #seen)
        assert.are.equal("/data/download/ok.txt", seen[1])
    end)

    it("tolerates a missing or non-table name list", function()
        assert.are.equal(0, #policy.conflicts("/data/download/", nil, probe({})))
        assert.are.equal(0, #policy.conflicts("/data/download/", "nope", probe({})))
    end)

    it("reports the sanitized name, not the raw one", function()
        local found = policy.conflicts("/data/download/", { "a b.txt" }, probe({
            ["/data/download/ab.txt"] = "file",
        }))
        assert.are.equal(1, #found)
        assert.are.equal("ab.txt", found[1].name)
    end)
end)
