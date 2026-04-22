local _M = {}

-- File type icon mappings (extension -> icon class)
-- Used by get_file_icon() function in handler.lua
_M.specific_icons = {
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

-- File types that should be opened in browser (inline) with their MIME types
-- Used for Content-Type header and inline display logic
_M.inline_mime_types = {
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
    csv = "text/csv",
    -- Images
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
    gif = "image/gif",
    webp = "image/webp",
    ico = "image/x-icon",
    bmp = "image/bmp",
    -- PDF
    pdf = "application/pdf"
}

return _M