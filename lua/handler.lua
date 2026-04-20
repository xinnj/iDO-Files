local cjson = require "cjson.safe"
local lfs = require "lfs"  -- luacheck: read environment
local user_info = require "user_info"

-- Get file icon class based on extension
local function get_file_icon(filename)
    local ext = filename:match("%.(%w+)$")
    if not ext then return "ti-file"
    end
    ext = ext:lower()

    -- Specific file type icons
    local specific_icons = {
        -- Web & Code
        html = "ti-file-type-html",
        htm = "ti-file-type-html",
        xhtml = "ti-file-type-html",
        css = "ti-file-type-css",
        js = "ti-file-type-js",
        json = "ti-file-type-json",
        svg = "ti-file-type-svg",
        xml = "ti-file-code",
        yaml = "ti-file-code",
        yml = "ti-file-code",
        md = "ti-markdown",
        
        -- Documents & Data
        pdf = "ti-file-type-pdf",
        txt = "ti-file-text",
        log = "ti-file-text",
        csv = "ti-table",
        xls = "ti-table",
        xlsx = "ti-table",
        doc = "ti-file-text",
        docx = "ti-file-text",
        ppt = "ti-presentation",
        pptx = "ti-presentation",
        sql = "ti-database",
        db = "ti-database",
        
        -- Archives
        zip = "ti-archive",
        rar = "ti-archive",
        tar = "ti-archive",
        gz = "ti-archive",
        bz2 = "ti-archive",
        xz = "ti-archive",
        tgz = "ti-archive",
        iso = "ti-disc",
        img = "ti-disc",
        
        -- Executables & Installers
        exe = "ti-settings",
        msi = "ti-settings",
        dmg = "ti-apple",
        pkg = "ti-apple",
        deb = "ti-package",
        rpm = "ti-package",
        apk = "ti-brand-android",
        ipa = "ti-brand-apple",
        
        -- Media
        jpg = "ti-photo",
        jpeg = "ti-photo",
        png = "ti-photo",
        gif = "ti-photo",
        bmp = "ti-photo",
        webp = "ti-photo",
        mp4 = "ti-video",
        avi = "ti-video",
        mkv = "ti-video",
        mov = "ti-video",
        mp3 = "ti-music",
        wav = "ti-music",
        flac = "ti-music",
        
        -- Programming Languages
        py = "ti-brand-python",
        java = "ti-brand-java",
        go = "ti-language",
        rs = "ti-language",
        cpp = "ti-brand-cpp",
        c = "ti-language",
        cs = "ti-brand-c-sharp",
        php = "ti-brand-php",
        rb = "ti-language",
        ts = "ti-file-code",
        lua = "ti-file-code",
        sh = "ti-terminal",
        bash = "ti-terminal",
    }

    if specific_icons[ext] then
        return specific_icons[ext]
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
    local mode = lfs.attributes(path, "mode")
    return mode == "directory"
end

-- File types that should be opened in browser (inline) with their MIME types
local inline_mime_types = {
    html = "text/html",
    htm = "text/html",
    xhtml = "application/xhtml+xml",
    svg = "image/svg+xml",
    xml = "application/xml",
    json = "application/json",
    yaml = "text/yaml",
    yml = "text/yaml",
    txt = "text/plain",
    md = "text/markdown",
    log = "text/plain",
    css = "text/css",
    js = "application/javascript",
    csv = "text/csv"
}

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

    -- Escape filename for Content-Disposition header
    local escaped_filename = filename:gsub('"', '\\"')

    -- Set headers
    if ext and inline_mime_types[ext] then
        ngx.header["Content-Type"] = inline_mime_types[ext]
    else
        ngx.header["Content-Type"] = "application/octet-stream"
        ngx.header["Content-Disposition"] = "attachment; filename=\"" .. escaped_filename .. "\""
    end

    -- Send the file using Nginx's internal mechanism
    -- We use ngx.location.capture to let Nginx serve the file efficiently
    -- But first, we need a location that can serve it. 
    -- Since we are in content_by_lua, we can't easily jump to a static handler without a specific setup.
    
    -- Alternative: Use ngx.print to send file content (less efficient for huge files but works)
    local f, err = io.open(store_path, "rb")
    if not f then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.say("File not found: " .. err)
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- Send in chunks to avoid memory issues
    local chunk_size = 8192
    while true do
        local chunk = f:read(chunk_size)
        if not chunk then break end
        ngx.print(chunk)
        ngx.flush(true)
    end
    f:close()
    
    return ngx.exit(ngx.HTTP_OK)
end

-- List files in directory
local function list_directory(dir_path, current_request_path)
    local files_list = {}
    local total_size = 0
    local folder_count = 0
    local file_count = 0

    for entry in lfs.dir(dir_path) do
        -- Skip . and .. entries
        if entry ~= "." and entry ~= ".." then
            -- Normalize path to avoid double slashes (handle root "/" case)
            local full_path = dir_path:gsub("/+$", "")
            if full_path == "" then full_path = "/" end
            full_path = full_path .. "/" .. entry
            local attr = lfs.attributes(full_path)

            if attr then
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
                        icon = "folder"
                    })
                elseif attr.mode == "file" then
                    file_count = file_count + 1
                    local file_size = attr.size or 0
                    total_size = total_size + file_size
                    table.insert(files_list, {
                        name = entry,
                        path = rel_path,
                        size = file_size,
                        size_formatted = format_size(file_size),
                        modified = format_timestamp(attr.modification),
                        icon_class = get_file_icon(entry)
                    })
                end
            end
        end
    end

    -- Sort files by modified date (newest first), folders always on top
    table.sort(files_list, function(a, b)
        -- Folders always come first
        if a.type == "directory" and b.type ~= "directory" then return true end
        if a.type ~= "directory" and b.type == "directory" then return false end
        
        -- For items of the same type, sort by modification time (newest first)
        local a_time = 0
        local b_time = 0
        
        -- Extract epoch time from formatted timestamp or use raw attributes
        -- Since we don't have raw epoch here, we'll sort by the formatted string in reverse
        -- The format is "YYYY-MM-DD HH:MM", so string comparison works for descending
        if a.modified and b.modified then
            return a.modified > b.modified
        end
        return false
    end)

    return {
        files = files_list,
        stats = {
            total = #files_list,
            folders = folder_count,
            files = file_count,
            size = total_size,
            size_formatted = format_size(total_size)
        }
    }, nil
end

-- Read template file
local function read_template()
    local url_prefix = ngx.var.url_prefix or ""
    local template_path = "/data" .. url_prefix .. "fileserver/template.html"
    local file = io.open(template_path, "r")
    if not file then
        return nil, "Failed to open template: " .. template_path
    end
    local content = file:read("*a")
    file:close()
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

-- Render header HTML with user menu
local function render_header(userinfo)
    local username = userinfo.username or "Guest"
    local initials = username:sub(1,2):upper()
    local url_prefix = ngx.var.url_prefix or "/"
    local logo_text = os.getenv("LOGO_TEXT") or "My Files"
    
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
                <div class="user-menu" id="userMenu">
                    <div class="user-trigger" id="userTrigger">
                        <div class="user-avatar">%s</div>
                        <span class="user-name">%s</span>
                        <i class="ti ti-chevron-down user-arrow"></i>
                    </div>
                    <div class="user-dropdown">
                        <div class="dropdown-header">
                            <div class="user-name">%s</div>
                            <div class="user-email">%s@fileserver</div>
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
    ]], logo_text, initials, username, username, username, url_prefix, admin_items, url_prefix)
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
local function render_file_row(item, index, userinfo)
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
    local is_inline = ext and inline_mime_types[ext:lower()] and "true" or "false"
    
    -- Build action buttons HTML conditionally based on permissions
    local action_buttons = ""
    
    if userinfo.writeable then
        -- Move button (opens modal)
        action_buttons = action_buttons .. string.format([[<button class="action-btn" title="Move" onclick="event.stopPropagation(); showMoveModal('%s')"><i class="ti ti-arrows-move"></i></button>]], escape_html(item.name))
        
        -- Delete button (simple confirmation and DELETE request)
        action_buttons = action_buttons .. string.format([[<button class="action-btn danger" title="Delete" onclick="event.stopPropagation(); showDeleteModal('%s')"><i class="ti ti-trash"></i></button>]], escape_html(item.name))
        
        -- Share button (only for files, not folders - opens modal)
        if item.type ~= "directory" then
            action_buttons = action_buttons .. string.format([[<button class="action-btn" title="Share" onclick="event.stopPropagation(); showShareModal('%s')"><i class="ti ti-share"></i></button>]], escape_html(item.name))
        end
    end

    -- Add inline event handlers for click and dblclick
    local onclick_handler = string.format("handleFileClick(event, '%s', '%s')", escape_html(item.path), escape_html(item.name))
    local ondblclick_handler = string.format("handleFileDblClick(event, '%s', '%s')", escape_html(item.name), item.type == "directory" and "true" or "false")

    -- Build file row HTML - only include actions column if user has write permission
    if userinfo.writeable then
        return string.format([[
            <div class="file-item%s" data-name="%s" data-inline="%s" onclick="%s" ondblclick="%s">
                <div class="file-info">
                    <div class="file-icon %s"><i class="ti %s"></i></div>
                    <span class="file-name" title="%s">%s</span>
                </div>
                <span class="file-size">%s</span>
                <span class="file-date">%s</span>
                <div class="file-actions">
                    %s
                </div>
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
            size,
            escape_html(item.modified or "-"),
            action_buttons
        )
    else
        -- Read-only: no actions column
        return string.format([[
            <div class="file-item%s" data-name="%s" data-inline="%s" onclick="%s" ondblclick="%s">
                <div class="file-info">
                    <div class="file-icon %s"><i class="ti %s"></i></div>
                    <span class="file-name" title="%s">%s</span>
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
            size,
            escape_html(item.modified or "-")
        )
    end
end

-- Render sort header HTML
local function render_sort_header(userinfo)
    -- Only include Actions column if user has write permission
    local actions_col = ""
    if userinfo.writeable then
        actions_col = [[
            <div class="sort-col">
                Actions
            </div>]]
    end
    
    return string.format([[
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
            </div>%s
        </div>
    ]], actions_col)
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
            html = html .. render_file_row(item, i, userinfo)
        end
    end

    html = html .. "</div>"

    -- Add embedded file data for JS
    html = html .. '<script type="application/json" id="file-data">' .. cjson.encode(files_data) .. '</script>'

    return html
end

-- Render modals HTML (move, share)
local function render_modals()
    return [[
<!-- Move Modal -->
<div id="moveModal" class="modal-overlay">
    <div class="modal" style="max-width: 450px;">
        <div class="modal-header">
            <h3 class="modal-title"><i class="ti ti-arrows-move"></i> Move File</h3>
            <button class="modal-close" onclick="closeModal('moveModal')"><i class="ti ti-x"></i></button>
        </div>
        <div class="modal-body">
            <div class="input-group" style="margin-bottom: 16px;">
                <label>Source:</label>
                <div id="moveSourcePath" style="padding: 10px; background: var(--bg-tertiary); border-radius: var(--radius-md); word-break: break-all; font-size: 13px; color: var(--text-secondary);"></div>
            </div>
            <div class="input-group" style="margin-bottom: 16px;">
                <label for="moveDestSelect">Destination:</label>
                <select id="moveDestSelect">
                    <option value="download">Download</option>
                    <option value="archive">Archive</option>
                    <option value="public">Public</option>
                </select>
            </div>
            <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input type="checkbox" id="moveAsCopy">
                <span>Copy instead of Move</span>
            </label>
        </div>
        <div class="modal-footer">
            <button class="btn btn-secondary" onclick="closeModal('moveModal')">Cancel</button>
            <button class="btn btn-primary" onclick="confirmMove()"><i class="ti ti-check"></i> Confirm</button>
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

    -- Check if path exists
    local ok = lfs.attributes(fs_path)
    if not ok then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.say(cjson.encode({ error = "Path not found" }))
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- If it's a directory, render HTML page
    if is_directory(fs_path) then
        ngx.log(ngx.DEBUG, "Listing directory: ", fs_path)
        local result, list_err = list_directory(fs_path, path)
        if list_err then
            ngx.log(ngx.ERR, "Error listing directory: ", list_err)
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
            ngx.say(cjson.encode({ error = "Failed to list directory" }))
            return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
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
