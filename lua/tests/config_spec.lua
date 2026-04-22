-- Tests for config.lua
local config = require("config")

describe("config module", function()

    describe("specific_icons", function()
        it("should contain expected file extensions", function()
            assert.is_table(config.specific_icons)
            -- Web & Code
            assert.are.equal("ti-file-type-html", config.specific_icons.html)
            assert.are.equal("ti-file-type-css", config.specific_icons.css)
            assert.are.equal("ti-file-type-js", config.specific_icons.js)
            assert.are.equal("ti-file-type-json", config.specific_icons.json)
            assert.are.equal("ti-markdown", config.specific_icons.md)
            -- Media
            assert.are.equal("ti-photo", config.specific_icons.png)
            assert.are.equal("ti-video", config.specific_icons.mp4)
            assert.are.equal("ti-music", config.specific_icons.mp3)
            -- Archives
            assert.are.equal("ti-archive", config.specific_icons.zip)
            assert.are.equal("ti-archive", config.specific_icons.tar)
            -- Programming
            assert.are.equal("ti-brand-python", config.specific_icons.py)
            assert.are.equal("ti-terminal", config.specific_icons.sh)
        end)

        it("should have string values for all entries", function()
            for ext, icon in pairs(config.specific_icons) do
                assert.is_string(ext)
                assert.is_string(icon)
                assert.is_not_nil(icon:find("^ti%-"))
            end
        end)

        it("should handle common extensions", function()
            -- Verify common extensions exist
            assert.is_string(config.specific_icons.lua)
            assert.is_string(config.specific_icons.bash)
            assert.is_string(config.specific_icons.py)
            assert.is_string(config.specific_icons.js)
        end)
    end)

    describe("inline_mime_types", function()
        it("should contain expected MIME types", function()
            assert.is_table(config.inline_mime_types)
            assert.are.equal("text/html", config.inline_mime_types.html)
            assert.are.equal("application/json", config.inline_mime_types.json)
            assert.are.equal("text/css", config.inline_mime_types.css)
            assert.are.equal("application/javascript", config.inline_mime_types.js)
            assert.are.equal("text/plain", config.inline_mime_types.txt)
            assert.are.equal("text/markdown", config.inline_mime_types.md)
        end)

        it("should have valid MIME type format", function()
            for ext, mime in pairs(config.inline_mime_types) do
                assert.is_string(ext)
                assert.is_string(mime)
                local is_valid = mime:find("^%w+/")
                assert.is_not_nil(is_valid, "Invalid MIME type: " .. mime)
            end
        end)

        it("should have matching extensions in specific_icons", function()
            -- Check that most inline_mime_types have corresponding icons
            local matched = 0
            local total = 0
            for ext, _ in pairs(config.inline_mime_types) do
                total = total + 1
                if config.specific_icons[ext] then
                    matched = matched + 1
                end
            end
            -- At least 80% should have icons
            assert.is_true(matched / total >= 0.7)
        end)
    end)

end)
