-- Mock ngx module for testing
local ngx_mock = {
    var = {},
    log = function() end,
    header = {},
    req = {
        read_body = function() end,
        get_body_data = function() return nil end,
        get_headers = function() return {} end
    },
    unescape_uri = function(s) return s end,
    HTTP_OK = 200,
    HTTP_BAD_REQUEST = 400,
    HTTP_FORBIDDEN = 403,
    HTTP_NOT_FOUND = 404,
    HTTP_INTERNAL_SERVER_ERROR = 500,
    NOTICE = 1,
    WARN = 2,
    ERR = 3
}

-- Make ngx globally available
_G.ngx = ngx_mock

return ngx_mock
