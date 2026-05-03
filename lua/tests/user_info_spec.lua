-- Tests for user_info.lua
local ngx_mock = require("mock_ngx")

-- Set up globals before requiring modules
_G.ngx = ngx_mock

ngx_mock.var.url_prefix = "/"

-- Mock all dependencies that authorize.lua and user_info.lua need
package.loaded["cjson.safe"] = {
    encode = function(t) return "{}" end,
    decode = function(s) return {} end
}
package.loaded["resty.redis"] = {}
package.loaded["redis_conn"] = {
    get_conn = function() return nil, "mock: no redis" end,
    close = function() end
}
package.loaded["resty.openidc"] = {}
package.loaded["oidc"] = {
    authenticate = function() end
}
package.loaded["resty.http"] = {}
package.loaded["keycloak"] = {
    get_user_groups = function() return nil end,
    get_username_from_userid = function() return nil end
}
package.loaded["resty.string"] = {
    to_hex = function(s) return s end
}
package.loaded["random"] = {
    bytes = function(n) return string.rep("a", n) end,
    token = function(n) return string.rep("t", n) end
}
package.loaded["access-token"] = {
    verify = function() return false, "mock" end,
    generate = function() end,
    list = function() end,
    delete = function() end
}

-- Mock authorize module
package.loaded["authorize"] = {
    checkAuthorize = function(groups, method, path)
        return true
    end,
    authorize = function() return true end
}

-- Fresh require of user_info module
package.loaded["user_info"] = nil
local user_info = require("user_info")

describe("user_info module", function()

    describe("apply_permissions", function()
        it("keeps writeable section content when user is writeable", function()
            local html = '<div><!--IF_WRITEABLE-->Delete Button<!--END_IF_WRITEABLE--></div>'
            local userinfo = { writeable = true, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div>Delete Button</div>', result)
        end)

        it("removes writeable section when user is not writeable", function()
            local html = '<div><!--IF_WRITEABLE-->Delete Button<!--END_IF_WRITEABLE--></div>'
            local userinfo = { writeable = false, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div></div>', result)
        end)

        it("keeps admin section content when user is admin", function()
            local html = '<div><!--IF_ADMIN-->Admin Panel<!--END_IF_ADMIN--></div>'
            local userinfo = { writeable = false, isAdmin = true }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div>Admin Panel</div>', result)
        end)

        it("removes admin section when user is not admin", function()
            local html = '<div><!--IF_ADMIN-->Admin Panel<!--END_IF_ADMIN--></div>'
            local userinfo = { writeable = false, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div></div>', result)
        end)

        it("handles both writeable and admin sections simultaneously", function()
            local html = '<div><!--IF_WRITEABLE-->Upload<!--END_IF_WRITEABLE--><!--IF_ADMIN-->Settings<!--END_IF_ADMIN--></div>'
            local userinfo = { writeable = true, isAdmin = true }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div>UploadSettings</div>', result)
        end)

        it("removes writeable but keeps admin when only admin", function()
            local html = '<div><!--IF_WRITEABLE-->Upload<!--END_IF_WRITEABLE--><!--IF_ADMIN-->Settings<!--END_IF_ADMIN--></div>'
            local userinfo = { writeable = false, isAdmin = true }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div>Settings</div>', result)
        end)

        it("keeps writeable but removes admin when only writeable", function()
            local html = '<div><!--IF_WRITEABLE-->Upload<!--END_IF_WRITEABLE--><!--IF_ADMIN-->Settings<!--END_IF_ADMIN--></div>'
            local userinfo = { writeable = true, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div>Upload</div>', result)
        end)

        it("removes both sections when neither writeable nor admin", function()
            local html = '<div><!--IF_WRITEABLE-->Upload<!--END_IF_WRITEABLE--><!--IF_ADMIN-->Settings<!--END_IF_ADMIN--></div>'
            local userinfo = { writeable = false, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div></div>', result)
        end)

        it("handles multi-line content within markers", function()
            local html = '<div>\n<!--IF_WRITEABLE-->\n<button>Delete</button>\n<button>Move</button>\n<!--END_IF_WRITEABLE-->\n</div>'
            local userinfo = { writeable = true, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.is_not_nil(result:match("<button>Delete</button>"))
            assert.is_not_nil(result:match("<button>Move</button>"))
            assert.is_nil(result:match("IF_WRITEABLE"))
        end)

        it("removes multi-line content within markers when not permitted", function()
            local html = '<div>\n<!--IF_ADMIN-->\n<button>Delete</button>\n<button>Move</button>\n<!--END_IF_ADMIN-->\n</div>'
            local userinfo = { writeable = false, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.is_nil(result:match("<button>Delete</button>"))
            assert.is_nil(result:match("<button>Move</button>"))
        end)

        it("handles content without any markers", function()
            local html = '<div>Hello World</div>'
            local userinfo = { writeable = false, isAdmin = false }
            local result = user_info.apply_permissions(html, userinfo)
            assert.are.equal('<div>Hello World</div>', result)
        end)

        it("handles empty string", function()
            local userinfo = { writeable = false, isAdmin = false }
            local result = user_info.apply_permissions("", userinfo)
            assert.are.equal("", result)
        end)
    end)

    describe("get_user_info", function()
        local original_get_headers
        local original_getenv

        before_each(function()
            -- Save originals
            original_get_headers = ngx_mock.req.get_headers
            original_getenv = os.getenv

            -- Set up default mock headers
            ngx_mock.req.get_headers = function()
                return {
                    ["X-USER-NAME"] = "testuser",
                    ["X-USER"] = "uid123",
                    ["X-USER-EMAIL"] = "test@example.com",
                    ["X-USER-GROUPS"] = "/fileserver-admin, /fileserver-user"
                }
            end

            -- Mock ADMIN_GROUP env
            os.getenv = function(key)
                if key == "ADMIN_GROUP" then
                    return "/fileserver-admin"
                end
                return original_getenv(key)
            end

            -- Mock authorize.checkAuthorize
            package.loaded["authorize"].checkAuthorize = function()
                return true
            end
        end)

        after_each(function()
            -- Restore originals
            ngx_mock.req.get_headers = original_get_headers
            os.getenv = original_getenv
        end)

        it("returns username from X-USER-NAME header", function()
            local info = user_info.get_user_info()
            assert.are.equal("testuser", info.username)
        end)

        it("returns userid from X-USER header", function()
            local info = user_info.get_user_info()
            assert.are.equal("uid123", info.userid)
        end)

        it("returns email from X-USER-EMAIL header", function()
            local info = user_info.get_user_info()
            assert.are.equal("test@example.com", info.email)
        end)

        it("detects admin when user group matches ADMIN_GROUP", function()
            local info = user_info.get_user_info()
            assert.is_true(info.isAdmin)
        end)

        it("does not mark as admin when group does not match", function()
            ngx_mock.req.get_headers = function()
                return {
                    ["X-USER-NAME"] = "regularuser",
                    ["X-USER"] = "uid456",
                    ["X-USER-EMAIL"] = "regular@example.com",
                    ["X-USER-GROUPS"] = "/fileserver-user"
                }
            end
            local info = user_info.get_user_info()
            assert.is_false(info.isAdmin)
        end)

        it("defaults to Guest when no headers present", function()
            ngx_mock.req.get_headers = function()
                return {}
            end
            local info = user_info.get_user_info()
            assert.are.equal("Guest", info.username)
            assert.are.equal("", info.userid)
        end)

        it("sets writeable to true when authorize.checkAuthorize returns true", function()
            package.loaded["authorize"].checkAuthorize = function()
                return true
            end
            local info = user_info.get_user_info("/download")
            assert.is_true(info.writeable)
        end)

        it("sets writeable to false when authorize.checkAuthorize returns false", function()
            package.loaded["authorize"].checkAuthorize = function()
                return false
            end
            local info = user_info.get_user_info("/download")
            assert.is_false(info.writeable)
        end)

        it("sets writeable to false when no path is provided", function()
            local info = user_info.get_user_info(nil)
            assert.is_false(info.writeable)
        end)

        it("handles groups with whitespace correctly", function()
            ngx_mock.req.get_headers = function()
                return {
                    ["X-USER-NAME"] = "spaceduser",
                    ["X-USER"] = "uid789",
                    ["X-USER-GROUPS"] = "  /fileserver-admin  ,  /other-group  "
                }
            end
            local info = user_info.get_user_info()
            assert.is_true(info.isAdmin)
        end)

        it("returns false isAdmin when ADMIN_GROUP env is not set", function()
            os.getenv = function(key)
                if key == "ADMIN_GROUP" then return nil end
                return original_getenv(key)
            end
            local info = user_info.get_user_info()
            assert.is_false(info.isAdmin)
        end)
    end)

end)
