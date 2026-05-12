local cjson = require "cjson.safe"
local lfs = require "lfs"  -- luacheck: read environment
local user_info = require "user_info"
local config = require "config"

local safe_file_open, safe_lfs_attributes, safe_lfs_dir

-- Security: Safe file operations with pcall wrapper
safe_file_open = function(path, mode)
    local f, err
    local ok = pcall(function()
        f, err = io.open(path, mode)
    end)
    
    if not ok then
        return nil, "File operation failed: " .. (err or "unknown error")
    end
    
    return f, err
end

-- Security: Safe lfs.attributes with pcall wrapper
safe_lfs_attributes = function(path, attr_name)
    local attr, err
    local ok = pcall(function()
        attr, err = lfs.attributes(path, attr_name)
    end)
    
    if not ok then
        return nil, "File system operation failed: " .. (err or "unknown error")
    end
    
    return attr, err
end

-- Security: Safe lfs.dir with pcall wrapper
safe_lfs_dir = function(path)
    local iter, state, ctrl
    local ok, pcall_err = pcall(function()
        iter, state, ctrl = lfs.dir(path)
    end)
    
    if not ok then
        return nil, "Directory operation failed: " .. (pcall_err or "unknown error")
    end
    
    if not iter then
        -- state contains error message from lfs.dir
        return nil, "Directory operation failed: " .. (state or "unknown error")
    end
    
    -- Return the iterator function, state, and control variable for use in for loop
    return iter, state, ctrl
end

-- Get file icon class based on extension
local function get_file_icon(filename)
    local ext = filename:match("%.(%w+)$")
    if not ext then return "ti-file"
    end
    ext = ext:lower()

    if config.specific_icons[ext] then
        return config.specific_icons[ext]
    end

    return "ti-file"
end

-- Format file size to human-readable
local function format_size(size)
    if not size then
        return "-"
    end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local i = 1
    while size >= 1024 and i < #units do
        size = size / 1024
        i = i + 1
    end
    return string.format("%.1f %s", size, units[i])
end

-- Check if path is a directory
local function is_directory(path)
    local attr, err = safe_lfs_attributes(path, "mode")
    if not attr then
        ngx.log(ngx.ERR, "Failed to get directory attributes: ", err)
        return false
    end
    return attr == "directory"
end

-- File types that should be opened in browser (inline) with their MIME types
-- Configuration moved to config.lua (config.inline_mime_types)

-- Format timestamp for display
local function format_timestamp(epoch)
    if not epoch then return "-" end
    local t = os.date("*t", epoch)
    return string.format("%04d-%02d-%02d %02d:%02d", t.year, t.month, t.day, t.hour, t.min)
end

-- Serve file for download or inline display
local function serve_file(store_path)
    local filename = store_path:match("([^/]+)$")
    local ext = filename:match("%.(%w+)$")
    ext = ext and ext:lower()

    -- Check if forced download is requested
    local args = ngx.req.get_uri_args()
    local force_download = args.download == "1"

    -- Escape filename for Content-Disposition header
    local escaped_filename = filename:gsub('"', '\\"')

    -- Set headers - force download if requested
    if force_download then
        ngx.header["Content-Type"] = "application/octet-stream"
        ngx.header["Content-Disposition"] = "attachment; filename=\"" .. escaped_filename .. "\""
    elseif ext and config.inline_mime_types[ext] then
        ngx.header["Content-Type"] = config.inline_mime_types[ext]
    else
        ngx.header["Content-Type"] = "application/octet-stream"
        ngx.header["Content-Disposition"] = "attachment; filename=\"" .. escaped_filename .. "\""
    end

    -- Open file with safe wrapper
    local f, err = safe_file_open(store_path, "rb")
    if not f then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.say(cjson.encode({ error = "File not found: " .. (err or "unknown error") }))
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- Set Content-Length for download progress
    local file_size = safe_lfs_attributes(store_path, "size")
    if file_size then
        ngx.header["Content-Length"] = file_size
    end

    -- Send in chunks with error handling
    local chunk_size = 8192
    local success, file_err = pcall(function()
        while true do
            local chunk, read_err
            local ok = pcall(function()
                chunk, read_err = f:read(chunk_size)
            end)
            
            if not ok then
                error("File read error: " .. (read_err or "unknown error"))
            end
            
            if not chunk then break end
            ngx.print(chunk)
            ngx.flush(true)
        end
    end)
    
    -- Always close the file, even on error
    local close_ok, close_err = pcall(function()
        f:close()
    end)
    
    if not close_ok then
        ngx.log(ngx.ERR, "Failed to close file: ", close_err)
    end
    
    if not success then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say(cjson.encode({ error = "Failed to read file: " .. (file_err or "unknown error") }))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    
    return ngx.exit(ngx.HTTP_OK)
end

-- List files in directory
local function list_directory(dir_path, current_request_path, page, limit)
    local files_list = {}
    local total_size = 0
    local folder_count = 0
    local file_count = 0

    -- Default pagination values
    page = page or 1

    -- Get safe directory iterator
    local iter, state, ctrl = safe_lfs_dir(dir_path)
    if not iter then
        -- state contains error message
        return nil, "Failed to open directory: " .. (state or "unknown error")
    end

    -- Safe iterator wrapper
    local function safe_iter()
        local entry, iter_err
        local ok, err = pcall(function()
            entry = iter(state, ctrl)
            ctrl = entry  -- update control variable for next call
        end)

        if not ok then
            ngx.log(ngx.WARN, "Directory iteration error: ", err)
            return nil
        end

        if entry then
            ngx.log(ngx.DEBUG, "Directory entry: ", entry)
        end

        return entry
    end

    -- Iterate through directory entries
    for entry in safe_iter do
        if entry and entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            -- Normalize path to avoid double slashes (handle root "/" case)
            local full_path = dir_path:gsub("/+$", "")
            if full_path == "" then full_path = "/" end
            full_path = full_path .. "/" .. entry

            -- Get file attributes safely
            local attr, attr_err = safe_lfs_attributes(full_path)
            if not attr then
                ngx.log(ngx.WARN, "Skipping entry due to attribute error: ", entry, " - ", attr_err or "unknown error")
                goto continue
            end

            -- Build path relative to the bucket root
            local rel_path = current_request_path
            if rel_path ~= "/" then
                rel_path = rel_path .. "/" .. entry
            else
                rel_path = "/" .. entry
            end

            if attr.mode == "directory" then
                folder_count = folder_count + 1
                table.insert(files_list, {
                    name = entry,
                    path = rel_path,
                    type = "directory",
                    size = nil,
                    modified = format_timestamp(attr.modification),
                    modified_epoch = attr.modification or 0,
                    icon = "folder"
                })
            elseif attr.mode == "file" then
                file_count = file_count + 1
                local file_size = attr.size or 0
                total_size = total_size + file_size
                local ext = entry:match("%.(%w+)$")
                local is_inline = ext and config.inline_mime_types[ext:lower()] and true or false
                table.insert(files_list, {
                    name = entry,
                    path = rel_path,
                    type = "file",
                    size = file_size,
                    size_formatted = format_size(file_size),
                    modified = format_timestamp(attr.modification),
                    modified_epoch = attr.modification or 0,
                    icon_class = get_file_icon(entry),
                    inline = is_inline
                })
            end

            ::continue::
        end
    end

    -- Sort files by modified date (newest first), folders always on top
    table.sort(files_list, function(a, b)
        -- Folders always come first
        if a.type == "directory" and b.type ~= "directory" then return true end
        if a.type ~= "directory" and b.type == "directory" then return false end

        -- For items of the same type, sort by modification time (newest first)
        local a_time = a.modified_epoch or 0
        local b_time = b.modified_epoch or 0

        if a_time ~= b_time then
            return a_time > b_time  -- newer first
        end

        -- If same modification time, sort by name (case-insensitive)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    -- Calculate pagination
    local total_items = #files_list
    local total_pages = math.max(1, math.ceil(total_items / limit))
    page = math.min(page, total_pages)
    local offset = (page - 1) * limit

    -- Slice files for current page
    local paginated_files = {}
    for i = offset + 1, math.min(offset + limit, total_items) do
        table.insert(paginated_files, files_list[i])
    end

    return {
        files = paginated_files,
        stats = {
            total = total_items,
            folders = folder_count,
            files = file_count,
            size = total_size,
            size_formatted = format_size(total_size)
        },
        pagination = {
            page = page,
            limit = limit,
            total = total_items,
            pages = total_pages
        }
    }, nil
end

-- Read template file
local function read_template()
    local url_prefix = ngx.var.url_prefix or ""
    local template_path = "/data" .. url_prefix .. "fileserver/template.html"
    local file, err = safe_file_open(template_path, "r")
    if not file then
        return nil, "Failed to open template: " .. template_path .. " - " .. (err or "unknown error")
    end
    
    local content, read_err
    local ok = pcall(function()
        content, read_err = file:read("*a")
    end)
    
    local close_ok, close_err = pcall(function()
        file:close()
    end)
    
    if not close_ok then
        ngx.log(ngx.ERR, "Failed to close template file: ", close_err)
    end
    
    if not ok or not content then
        return nil, "Failed to read template: " .. (read_err or "unknown error")
    end
    
    return content
end

-- Escape HTML special characters
local function escape_html(str)
    if not str then return "" end
    str = str:gsub("&", "&amp;")
    str = str:gsub("<", "&lt;")
    str = str:gsub(">", "&gt;")
    str = str:gsub('"', "&quot;")
    str = str:gsub("'", "&#39;")
    return str
end

-- Security: Validate and normalize file system path
local function validate_fs_path(fs_path, url_prefix)
    -- Ensure path starts with /data
    if not fs_path:match("^/data/") then
        return nil, "Invalid path: must start with /data"
    end
    
    -- Normalize URL prefix: ensure it starts with / and doesn't end with /
    local normalized_prefix = url_prefix
    if normalized_prefix ~= "" and normalized_prefix ~= "/" then
        -- Ensure starts with /
        if not normalized_prefix:match("^/") then
            normalized_prefix = "/" .. normalized_prefix
        end
        -- Remove trailing slash if present (except for root)
        if normalized_prefix ~= "/" then
            normalized_prefix = normalized_prefix:gsub("/+$", "")
        end
    else
        normalized_prefix = ""
    end
    
    -- Construct allowed root directories
    local allowed_roots = {
        "/data" .. normalized_prefix .. "/download",
        "/data" .. normalized_prefix .. "/public", 
        "/data" .. normalized_prefix .. "/archive"
    }
    
    -- Escape regex special characters for safe pattern matching
    local function escape_pattern(text)
        return text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    end
    
    -- Check if path starts with any allowed root
    local is_allowed = false
    for _, root in ipairs(allowed_roots) do
        local escaped_root = escape_pattern(root)
        -- Match either exact root or root followed by /
        if fs_path:match("^" .. escaped_root .. "/") or fs_path == root then
            is_allowed = true
            break
        end
    end
    
    if not is_allowed then
        return nil, "Access denied: path not in allowed directories"
    end
    
    -- Check for directory traversal attempts
    if fs_path:match("%.%.%/") then
        return nil, "Invalid path: directory traversal detected"
    end
    
    -- Check for control characters or other dangerous patterns
    if fs_path:match("[%c]") then
        return nil, "Invalid path: dangerous characters detected"
    end
    local dangerous_chars = "<>|$&;`"
    for i = 1, #dangerous_chars do
        if fs_path:find(dangerous_chars:sub(i, i), 1, true) then
            return nil, "Invalid path: dangerous characters detected"
        end
    end
    
    -- Normalize path: remove duplicate slashes, resolve . and ..
    -- Simple normalization for safety
    local normalized = fs_path:gsub("/+", "/"):gsub("/%./", "/")
    -- Note: We don't fully resolve .. to keep it simple and rely on the root check
    
    return normalized, nil
end



-- Render header HTML with user menu
local function render_header(userinfo)
    local username = userinfo.username or "Guest"
    local email = userinfo.email or ""
    local initials = username:sub(1,2):upper()
    local url_prefix = ngx.var.url_prefix or "/"
    local logo_text = os.getenv("LOGO_TEXT") or "My Files"
    
    -- Build email display conditionally
    local email_html = ""
    if email and email ~= "" and email ~= "unknown" then
        email_html = string.format([[<div class="user-email" style="font-size:12px;color:var(--text-secondary);word-break:break-all;">%s</div>]], email)
    end

    -- Build admin menu items conditionally
    local admin_items = ""
    if userinfo.isAdmin then
        admin_items = string.format([[
                        <div class="dropdown-separator"></div>
                        <a href="%sfileserver/access-control.html" class="dropdown-item" target="_blank">
                            <i class="ti ti-shield-lock"></i>
                            <span>Access Control</span>
                        </a>
                        <a href="%sfileserver/share-links.html" class="dropdown-item" target="_blank">
                            <i class="ti ti-link"></i>
                            <span>Share Links</span>
                        </a>]], url_prefix, url_prefix)
    end
    
    return string.format([[
        <header class="header">
            <div class="logo-section">
                <div class="logo"><i class="ti ti-cloud-download"></i></div>
                <span class="logo-text">%s</span>
            </div>
            <div class="user-section">
                <button class="theme-toggle" id="themeToggle" onclick="toggleTheme()" title="Toggle theme">
                    <i class="ti ti-moon"></i>
                </button>
                <div class="user-menu" id="userMenu">
                    <div class="user-trigger" id="userTrigger">
                        <div class="user-avatar">%s</div>
                        <span class="user-name">%s</span>
                        <i class="ti ti-chevron-down user-arrow"></i>
                    </div>
                    <div class="user-dropdown">
                        <div class="dropdown-header">
                            <div class="user-name">%s</div>
                            %s
                        </div>
                        <a href="%sfileserver/access-token.html" class="dropdown-item" target="_blank">
                            <i class="ti ti-key"></i>
                            <span>Access Token</span>
                            <span class="dropdown-badge">API</span>
                        </a>%s
                        <div class="dropdown-separator"></div>
                        <a href="%sfileserver/logout" class="dropdown-item danger">
                            <i class="ti ti-logout"></i>
                            <span>Logout</span>
                        </a>
                    </div>
                </div>
            </div>
        </header>
    ]], logo_text, initials, username, username, email_html, url_prefix, admin_items, url_prefix)
end

-- Render breadcrumb HTML
local function render_breadcrumb(bucket, path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    
    -- Get URL prefix (always ends with /)
    local url_prefix = ngx.var.url_prefix or "/"
    
    -- Build breadcrumb HTML with home dropdown
    local html = string.format([[
        <div class="breadcrumb-home-dropdown">
            <a href="#" class="breadcrumb-item breadcrumb-home-btn" onclick="event.preventDefault()">
                <i class="ti ti-home"></i>
            </a>
            <div class="bucket-dropdown-menu" id="bucketDropdown">
                <a href="%sdownload/" class="bucket-dropdown-item">
                    <i class="ti ti-download"></i>
                    <span>Download</span>
                </a>
                <a href="%sarchive/" class="bucket-dropdown-item">
                    <i class="ti ti-archive"></i>
                    <span>Archive</span>
                </a>
                <a href="%spublic/" class="bucket-dropdown-item">
                    <i class="ti ti-folder"></i>
                    <span>Public</span>
                </a>
            </div>
        </div>
    ]], url_prefix, url_prefix, url_prefix)
    
    -- Add bucket as first item
    html = html .. string.format('<span class="breadcrumb-separator"><i class="ti ti-chevron-right"></i></span>')
    html = html .. string.format('<a href="%s%s/" class="breadcrumb-item">%s</a>', url_prefix, escape_html(bucket), escape_html(bucket))
    
    -- Add path segments
    local current_path = ""
    for i, part in ipairs(parts) do
        current_path = current_path .. "/" .. part
        html = html .. '<span class="breadcrumb-separator"><i class="ti ti-chevron-right"></i></span>'
        
        if i == #parts then
            -- Last segment is active (not a link)
            html = html .. string.format('<span class="breadcrumb-item active">%s</span>', escape_html(part))
        else
            -- Intermediate segments are links
            html = html .. string.format('<a href="%s%s%s/" class="breadcrumb-item">%s</a>', url_prefix, escape_html(bucket), escape_html(current_path), escape_html(part))
        end
    end
    
    return html
end

-- Render toolbar HTML
local function render_toolbar(bucket, path, url_prefix, userinfo)
    -- Build upload button conditionally
    local upload_button = ""
    if userinfo.writeable then
        upload_button = string.format([[
                <button class="btn btn-primary" id="upload-btn" onclick="window.open('%sfileserver/upload.html', '_blank')">
                    <i class="ti ti-upload"></i>
                    Upload
                </button>]], url_prefix)
    end
    
    return string.format([[
        <div class="toolbar">
            <nav class="breadcrumb" id="breadcrumb">%s</nav>
            <div class="toolbar-actions">
                <div class="search-box">
                    <i class="ti ti-search search-icon"></i>
                    <input type="text" class="search-input" id="search-input" placeholder="Search files...">
                    <button class="search-clear" id="search-clear" title="Clear search">
                        <i class="ti ti-x"></i>
                    </button>
                </div>%s
            </div>
        </div>
    ]], render_breadcrumb(bucket, path), upload_button)
end

-- Capitalize first letter
local function capitalize(str)
    if not str then return "" end
    return str:sub(1,1):upper() .. str:sub(2)
end

-- Render file row HTML
local function render_file_row(item, index, userinfo, bucket)
    local size = item.size_formatted or "-"

    -- Determine the icon to use
    local icon
    if item.type == "directory" then
        icon = "ti-folder"
    else
        icon = item.icon_class or "ti-file"
    end

    -- Check if file should open inline (based on extension)
    local ext = item.name:match("%.(%w+)$")
    local is_inline = ext and config.inline_mime_types[ext:lower()] and "true" or "false"

    -- Build three-dot menu button and dropdown HTML
    local three_dot_menu = string.format([[
        <div class="file-three-dot-menu" onclick="event.stopPropagation(); toggleFileMenu(this)">
            <button class="file-three-dot-btn" title="More options">
                <i class="ti ti-dots-vertical"></i>
            </button>
            <div class="file-three-dot-dropdown">
                <div class="dropdown-item" onclick="event.stopPropagation(); copyLinkByName('%s')">
                    <i class="ti ti-copy"></i>
                    <span>Copy link</span>
                </div>]], escape_html(item.name))

    -- Add Download option for non-folders only
    if item.type ~= "directory" then
        three_dot_menu = three_dot_menu .. string.format([[
                <div class="dropdown-item" onclick="event.stopPropagation(); downloadFileByName('%s')">
                    <i class="ti ti-download"></i>
                    <span>Download</span>
                </div>]], escape_html(item.name))
    end

    -- Add write-only options if user has write permission (including Share, but not for public bucket)
    if userinfo.writeable then
        local share_item = ""
        -- Hide Share action in public bucket
        if item.type ~= "directory" and bucket ~= "public" then
            share_item = string.format([[
                <div class="dropdown-item" onclick="event.stopPropagation(); showShareModal('%s')">
                    <i class="ti ti-share"></i>
                    <span>Share</span>
                </div>]], escape_html(item.name))
        end
        three_dot_menu = three_dot_menu .. string.format([[
                <div class="dropdown-separator"></div>%s
                <div class="dropdown-item" onclick="event.stopPropagation(); showRenameModal('%s')">
                    <i class="ti ti-edit"></i>
                    <span>Rename</span>
                </div>
                <div class="dropdown-item" onclick="event.stopPropagation(); showCopyMoveModal('%s')">
                    <i class="ti ti-arrows-move"></i>
                    <span>Copy / Move</span>
                </div>
                <div class="dropdown-item danger" onclick="event.stopPropagation(); showDeleteModal('%s')">
                    <i class="ti ti-trash"></i>
                    <span>Delete</span>
                </div>]], share_item, escape_html(item.name), escape_html(item.name), escape_html(item.name))
    end

    three_dot_menu = three_dot_menu .. [[
            </div>
        </div>]]

    -- Add inline event handlers for click and dblclick
    local onclick_handler = string.format("handleFileClick(event, '%s', '%s')", escape_html(item.path), escape_html(item.name))
    local ondblclick_handler = string.format("handleFileDblClick(event, '%s', '%s')", escape_html(item.name), item.type == "directory" and "true" or "false")

    -- Build file row HTML - all users get the three-dot menu
    -- Three-dot menu is inside .file-info (NAME column)
    return string.format([[
        <div class="file-item%s" data-name="%s" data-inline="%s" onclick="%s" ondblclick="%s" oncontextmenu="showContextMenu(event, this)">
            <div class="file-info">
                <div class="file-icon %s"><i class="ti %s"></i></div>
                <span class="file-name" title="%s">%s</span>
                %s
            </div>
            <span class="file-size">%s</span>
            <span class="file-date">%s</span>
        </div>
    ]],
        item.type == "directory" and " folder" or "",
        escape_html(item.name),
        is_inline,
        onclick_handler,
        ondblclick_handler,
        item.icon_class and "" or (item.icon or "file"),
        icon,
        escape_html(item.name),
        escape_html(item.name),
        three_dot_menu,
        size,
        escape_html(item.modified or "-")
    )
end

-- Render sort header HTML
local function render_sort_header(userinfo)
    -- No Actions column anymore - using three-dot menu in NAME column
    return [[
        <div class="sort-header">
            <div class="sort-col" data-sort="name" onclick="handleSortClick('name')">
                Name
                <span class="sort-icon"><i class="ti ti-arrow-up"></i></span>
            </div>
            <div class="sort-col" data-sort="size" onclick="handleSortClick('size')">
                Size
                <span class="sort-icon"><i class="ti ti-arrow-up"></i></span>
            </div>
            <div class="sort-col active desc" data-sort="modified" onclick="handleSortClick('modified')">
                Modified
                <span class="sort-icon"><i class="ti ti-arrow-down"></i></span>
            </div>
        </div>
    ]]
end

-- Render search results info HTML
local function render_search_results_info()
    return [[
        <div class="search-results-info" id="search-results-info">
            <i class="ti ti-search"></i>
            <span>Found <strong id="search-count">0</strong> results for "<strong id="search-term"></strong>"</span>
            <button class="clear-search" id="clear-search">Clear</button>
        </div>
    ]]
end

-- Render empty search state HTML
local function render_empty_search()
    return [[
        <div class="empty-state" id="empty-search">
            <i class="ti ti-file-search"></i>
            <h3>No files found</h3>
            <p>Try adjusting your search terms</p>
        </div>
    ]]
end

-- Render stats bar HTML
local function render_stats_bar(files_data)
    local stats = files_data.stats or {}
    return string.format([[
        <div class="stats-bar">
            <div class="stat-item">
                <i class="ti ti-files"></i>
                <span class="stat-value">%d</span> items
            </div>
            <div class="stat-item">
                <i class="ti ti-folder"></i>
                <span class="stat-value">%d</span> folders
            </div>
            <div class="stat-item">
                <i class="ti ti-file"></i>
                <span class="stat-value">%d</span> files
            </div>
            <div class="stat-item">
                <i class="ti ti-database"></i>
                <span class="stat-value">%s</span> total
            </div>
        </div>
    ]], stats.total or 0, stats.folders or 0, stats.files or 0, stats.size_formatted or "0 B")
end

-- Render pagination HTML
local function render_pagination(files_data, bucket, path, url_prefix)
    local pagination = files_data.pagination
    if not pagination or pagination.pages <= 1 then
        return ""
    end

    local page = pagination.page
    local pages = pagination.pages
    local limit = pagination.limit
    local total = pagination.total

    -- Build the base path (without query params)
    local base_path = url_prefix .. bucket .. path
    if path == "/" then
        base_path = url_prefix .. bucket
    end

    -- Build page URL
    local function page_url(p)
        return base_path .. "?page=" .. p .. "&limit=" .. limit
    end

    -- Generate page numbers to show
    local page_numbers = {}
    local max_visible = 7

    if pages <= max_visible then
        for i = 1, pages do
            table.insert(page_numbers, i)
        end
    else
        -- Always show first page
        table.insert(page_numbers, 1)

        if page > 3 then
            table.insert(page_numbers, -1) -- ellipsis marker
        end

        -- Show pages around current
        local start = math.max(2, page - 1)
        local finish = math.min(pages - 1, page + 1)
        for i = start, finish do
            table.insert(page_numbers, i)
        end

        if page < pages - 2 then
            table.insert(page_numbers, -1) -- ellipsis marker
        end

        -- Always show last page
        table.insert(page_numbers, pages)
    end

    -- Build page number HTML
    local page_html = ""
    for _, p in ipairs(page_numbers) do
        if p == -1 then
            page_html = page_html .. '<span class="pagination-ellipsis">...</span>'
        elseif p == page then
            page_html = page_html .. '<span class="pagination-current">' .. p .. '</span>'
        else
            page_html = page_html .. '<a href="' .. page_url(p) .. '" class="pagination-page">' .. p .. '</a>'
        end
    end

    -- Build prev/next buttons
    local prev_btn = ""
    local next_btn = ""

    if page > 1 then
        prev_btn = '<a href="' .. page_url(page - 1) .. '" class="pagination-btn"><i class="ti ti-chevron-left"></i></a>'
    else
        prev_btn = '<span class="pagination-btn disabled"><i class="ti ti-chevron-left"></i></span>'
    end

    if page < pages then
        next_btn = '<a href="' .. page_url(page + 1) .. '" class="pagination-btn"><i class="ti ti-chevron-right"></i></a>'
    else
        next_btn = '<span class="pagination-btn disabled"><i class="ti ti-chevron-right"></i></span>'
    end

    local start_item = (page - 1) * limit + 1
    local end_item = math.min(page * limit, total)

    -- Build limit selector (include current limit if not in standard list)
    local limit_options = ""
    local limits = {10, 25, 50, 100}
    local found = false
    for _, l in ipairs(limits) do
        if l == limit then found = true end
    end
    if not found then
        table.insert(limits, 1, limit)
    end
    for _, l in ipairs(limits) do
        local selected = (l == limit) and ' selected' or ''
        limit_options = limit_options .. '<option value="' .. l .. '"' .. selected .. '>' .. l .. '</option>'
    end

    local limit_selector = string.format([[
        <div class="limit-selector">
            <label>Show:</label>
            <select id="page-limit" onchange="window.location.href='%s&limit=' + this.value">
                %s
            </select>
            <label>per page</label>
        </div>
    ]], base_path .. "?page=1", limit_options)

    return string.format([[
        <div class="pagination-bar">
            <div class="pagination-info">
                %s
                <span class="pagination-total">(%d items total)</span>
            </div>
            <div class="pagination-controls">
                %s
                %s
                %s
            </div>
        </div>
    ]], limit_selector, total, prev_btn, page_html, next_btn)
end

-- Render file list HTML
local function render_file_list(files_data, userinfo)
    local html = '<div class="file-list">'

    local files = files_data.files or {}

    if #files == 0 then
        html = html .. [[
            <div class="empty-state visible">
                <i class="ti ti-folder-open"></i>
                <h3>This folder is empty</h3>
                <p>Upload files to get started</p>
            </div>
        ]]
    else
        for i, item in ipairs(files) do
            html = html .. render_file_row(item, i, userinfo, bucket)
        end
    end

    html = html .. "</div>"

    -- Add embedded file data for JS
    html = html .. '<script type="application/json" id="file-data">' .. cjson.encode(files_data) .. '</script>'

    return html
end

-- Render modals HTML (rename, move, share)
local function render_modals()
    return [[
<!-- Rename Modal -->
<div id="renameModal" class="modal-overlay">
    <div class="modal" style="max-width: 450px;">
        <div class="modal-header">
            <h3 class="modal-title"><i class="ti ti-edit"></i> Rename</h3>
            <button class="modal-close" onclick="closeModal('renameModal')"><i class="ti ti-x"></i></button>
        </div>
        <div class="modal-body">
            <div class="input-group" style="margin-bottom: 16px;">
                <label>Current name:</label>
                <div id="renameCurrentName" style="padding: 10px; background: var(--bg-tertiary); border-radius: var(--radius-md); word-break: break-all; font-size: 13px; color: var(--text-secondary);"></div>
            </div>
            <div class="input-group">
                <label for="renameNewName">New name:</label>
                <input type="text" id="renameNewName" placeholder="Enter new name" style="width: 100%;">
            </div>
        </div>
        <div class="modal-footer">
            <button class="btn btn-secondary" onclick="closeModal('renameModal')">Cancel</button>
            <button class="btn btn-primary" onclick="confirmRename()"><i class="ti ti-check"></i> Rename</button>
        </div>
    </div>
</div>

<!-- Copy / Move Modal -->
<div id="copyMoveModal" class="modal-overlay">
    <div class="modal" style="max-width: 450px;">
        <div class="modal-header">
            <h3 class="modal-title"><i class="ti ti-arrows-move"></i> Copy File</h3>
            <button class="modal-close" onclick="closeModal('copyMoveModal')"><i class="ti ti-x"></i></button>
        </div>
        <div class="modal-body">
            <div class="input-group" style="margin-bottom: 16px;">
                <label>Source:</label>
                <div id="copySourcePath" style="padding: 10px; background: var(--bg-tertiary); border-radius: var(--radius-md); word-break: break-all; font-size: 13px; color: var(--text-secondary);"></div>
            </div>
            <div class="input-group" style="margin-bottom: 16px;">
                <label>Destination:</label>
                <div class="radio-group" id="copyDestSelect">
                    <label class="radio-option">
                        <input type="radio" name="copyDest" value="download" checked>
                        <span>Download</span>
                    </label>
                    <label class="radio-option">
                        <input type="radio" name="copyDest" value="archive">
                        <span>Archive</span>
                    </label>
                    <label class="radio-option">
                        <input type="radio" name="copyDest" value="public">
                        <span>Public</span>
                    </label>
                </div>
            </div>
            <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input type="checkbox" id="copyAsMove">
                <span>Move instead of Copy</span>
            </label>
        </div>
        <div class="modal-footer">
            <button class="btn btn-secondary" onclick="closeModal('copyMoveModal')">Cancel</button>
            <button class="btn btn-primary" onclick="confirmCopyMove()"><i class="ti ti-check"></i> Confirm</button>
        </div>
    </div>
</div>

<!-- Delete Modal -->
<div id="deleteModal" class="modal-overlay">
    <div class="modal" style="max-width: 450px;">
        <div class="modal-header">
            <h3 class="modal-title"><i class="ti ti-trash"></i> Confirm Delete</h3>
            <button class="modal-close" onclick="closeModal('deleteModal')"><i class="ti ti-x"></i></button>
        </div>
        <div class="modal-body">
            <p id="deleteModalMessage" style="word-break: break-all; max-height: 200px; overflow-y: auto; margin: 15px 0; padding: 12px; background: var(--bg-tertiary); border-radius: var(--radius-md); font-size: 14px; color: var(--text-secondary);">Are you sure you want to delete this file?</p>
        </div>
        <div class="modal-footer">
            <button class="btn btn-secondary" id="deleteCancelBtn">Cancel</button>
            <button class="btn btn-danger" id="deleteConfirmBtn"><i class="ti ti-trash"></i> Delete</button>
        </div>
    </div>
</div>

<!-- Share Modal -->
<div id="shareModal" class="modal-overlay">
    <div class="modal" style="max-width: 600px;">
        <div class="modal-header">
            <h3 class="modal-title"><i class="ti ti-share"></i> Share File</h3>
            <button class="modal-close" onclick="closeModal('shareModal')"><i class="ti ti-x"></i></button>
        </div>
        <div class="modal-body">
            <div class="input-group" style="margin-bottom: 16px;">
                <label>File:</label>
                <div id="shareFileName" style="padding: 10px; background: var(--bg-tertiary); border-radius: var(--radius-md); word-break: break-all; font-size: 13px; color: var(--text-secondary); font-weight: 600;"></div>
            </div>

            <!-- Create New Link Section -->
            <div id="shareCreateSection">
                <div class="input-group" style="margin-bottom: 16px;">
                    <label for="shareExpireValue">Expiration Time (max 1 year):</label>
                    <div style="display: flex; gap: 10px;">
                        <input type="number" id="shareExpireValue" value="1" min="1" style="flex: 1;">
                        <select id="shareExpireUnit" style="width: 120px;">
                            <option value="minutes">Minutes</option>
                            <option value="days" selected>Days</option>
                        </select>
                    </div>
                </div>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button class="btn btn-secondary" id="shareCancelBtn">Cancel</button>
                    <button class="btn btn-primary" id="shareCreateBtn"><i class="ti ti-plus"></i> Create Link</button>
                </div>
            </div>

            <!-- Existing Links Section -->
            <div id="shareListSection" style="display: none;">
                <h4 style="margin: 0 0 12px 0; font-size: 14px; color: var(--text-secondary);">Active Share Links</h4>
                <div id="shareLinksContainer" style="max-height: 250px; overflow-y: auto;"></div>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button class="btn btn-secondary" id="shareCloseBtn">Close</button>
                    <button class="btn btn-primary" id="shareCreateNewBtn"><i class="ti ti-plus"></i> Create New Link</button>
                </div>
            </div>
        </div>
    </div>
</div>
    ]]
end

-- Render complete HTML page
local function render_html_page(bucket, path, files_data, url_prefix, userinfo)
    local template, err = read_template()
    if not template then
        ngx.log(ngx.ERR, "Failed to read template: ", err)
        return nil, err
    end

    -- Build path display (for title)
    local path_title = bucket
    if path and path ~= "/" and path ~= "" then
        path_title = path_title .. path
    end

    -- Replace placeholders
    local html = template
    ngx.log(ngx.NOTICE, "path_title: [", escape_html(path_title), "]")
    html = (html:gsub("<!%-%-PATH_TITLE%-%->", escape_html(path_title)))
    html = (html:gsub("<!%-%-HEADER%-%->", render_header(userinfo)))
    html = (html:gsub("<!%-%-TOOLBAR%-%->", render_toolbar(bucket, path, url_prefix, userinfo)))
    html = (html:gsub("<!%-%-SORT_HEADER%-%->", render_sort_header(userinfo)))
    html = (html:gsub("<!%-%-SEARCH_RESULTS_INFO%-%->", render_search_results_info()))
    html = (html:gsub("<!%-%-EMPTY_SEARCH%-%->", render_empty_search()))
    html = (html:gsub("<!%-%-FILE_LIST%-%->", render_file_list(files_data, userinfo)))
    html = (html:gsub("<!%-%-STATS_BAR%-%->", render_stats_bar(files_data)))
    html = (html:gsub("<!%-%-PAGINATION%-%->", render_pagination(files_data, bucket, path, url_prefix)))
    
    -- Add modals before closing body tag (only if user has write permission)
    if userinfo.writeable then
        html = html .. render_modals()
    end

    return html
end

-- Main handler
local function handle()
    -- Explicitly decode URI to ensure UTF-8 paths (like Chinese characters) are handled correctly
    local uri = ngx.var.uri
    uri = ngx.unescape_uri(uri)
    
    -- Build filesystem path directly from decoded URI
    local fs_path = "/data" .. uri

    -- Get URL prefix for path validation
    local url_prefix = ngx.var.url_prefix or ""
    
    -- Validate file system path for security
    local validated_path, validation_err = validate_fs_path(fs_path, url_prefix)
    if not validated_path then
        ngx.log(ngx.WARN, "Path validation failed: ", validation_err, " - URI: ", uri)
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.say(cjson.encode({ error = "Access denied: " .. (validation_err or "invalid path") }))
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
    
    -- Use validated path
    fs_path = validated_path

    -- Extract bucket and path by splitting URI into components
    -- URI patterns: /bucket/... or /prefix/bucket/...
    -- Split by / and find the bucket name
    local bucket = "public"  -- Default
    local path = "/"
    
    local parts = {}
    for part in uri:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    
    -- Find which part is the bucket (public, download, or archive)
    for i, part in ipairs(parts) do
        if part == "public" or part == "download" or part == "archive" then
            bucket = part
            -- Build path from remaining parts after bucket
            if i < #parts then
                local path_parts = {}
                for j = i + 1, #parts do
                    table.insert(path_parts, parts[j])
                end
                path = "/" .. table.concat(path_parts, "/")
            else
                path = "/"
            end
            break
        end
    end
    
    ngx.log(ngx.NOTICE, "URI: ", uri, " -> parts: ", #parts, ", bucket: ", bucket, ", path: ", path)

    -- Parse pagination parameters
    local page = tonumber(ngx.var.arg_page) or 1
    local limit = tonumber(ngx.var.arg_limit) or tonumber(os.getenv("PAGE_LIMIT")) or 25
    -- Sanitize values
    page = math.max(1, page)
    limit = math.max(1, math.min(500, limit))
    ngx.log(ngx.NOTICE, "page: ", page, ", limit: ", limit)

    -- Check if path exists using safe attribute check
    local attr, attr_err = safe_lfs_attributes(fs_path)
    if not attr then
        ngx.log(ngx.WARN, "Path not found or inaccessible: ", fs_path, " - ", attr_err or "unknown error")
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.say(cjson.encode({ error = "Path not found" }))
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- If it's a directory, render HTML page
    if attr.mode == "directory" then
        ngx.log(ngx.DEBUG, "Listing directory: ", fs_path)
        local result, list_err = list_directory(fs_path, path, page, limit)
        if list_err then
            ngx.log(ngx.ERR, "Error listing directory: ", list_err)
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
            ngx.say(cjson.encode({ error = "Failed to list directory" }))
            return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        -- Redirect if page exceeds total pages (e.g. limit was changed from 25 to 100 while on page 2+)
        if result.pagination.page ~= page then
            local new_args = ngx.var.args:gsub("page=%d+", "page=" .. result.pagination.page)
            return ngx.redirect(ngx.var.uri .. "?" .. new_args)
        end

        -- Get user information including permissions
        local userinfo = user_info.get_user_info(uri)
        ngx.log(ngx.NOTICE, "User: ", userinfo.username, " Admin: ", tostring(userinfo.isAdmin), " Writeable: ", tostring(userinfo.writeable))

        -- Get URL prefix for breadcrumb links
        local url_prefix = ngx.var.url_prefix or ""

        ngx.log(ngx.NOTICE, "bucket: ", bucket, " path: ", path, " url_prefix: ", url_prefix)
        ngx.log(ngx.NOTICE, "result.files count: ", #result.files)
        -- Render HTML page
        local html, render_err = render_html_page(bucket, path, result, url_prefix, userinfo)
        if not html then
            ngx.log(ngx.ERR, "Failed to render HTML: ", render_err)
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
            ngx.say("Internal Server Error")
            return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end

        -- Apply permission-based conditional rendering
        html = user_info.apply_permissions(html, userinfo)

        ngx.status = ngx.HTTP_OK
        ngx.header["Content-Type"] = "text/html; charset=utf-8"
        ngx.say(html)
        return ngx.exit(ngx.HTTP_OK)
    end

    -- It's a file, serve for download
    serve_file(fs_path)
end

handle()
