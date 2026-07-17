#!/bin/bash
set -e

DATA_DIR="${1:-$(cd "$(dirname "$0")/../../env/data" && pwd)}"
URL_PREFIX="${URL_PREFIX:-/}"

echo "=== Seeding test data into $DATA_DIR ==="

# Create directory structure
mkdir -p "$DATA_DIR/download/documents"
mkdir -p "$DATA_DIR/download/code"
mkdir -p "$DATA_DIR/download/images"
mkdir -p "$DATA_DIR/download/archives"
mkdir -p "$DATA_DIR/download/empty_folder"
mkdir -p "$DATA_DIR/download/many_files"
mkdir -p "$DATA_DIR/download/deep/nested/path"
mkdir -p "$DATA_DIR/public"
mkdir -p "$DATA_DIR/archive/old_reports"
mkdir -p "$DATA_DIR/archive/backup"

# --- download/ ---

# Text files
echo "Hello World" > "$DATA_DIR/download/documents/notes.txt"
echo "This is a test file." >> "$DATA_DIR/download/documents/notes.txt"

cat > "$DATA_DIR/download/documents/README.md" << 'MARKDOWN'
# Test File Server

## Overview
This is a **markdown** test file.

- Item 1
- Item 2

| Header | Value |
|--------|-------|
| Key    | Data  |
MARKDOWN

# Minimal valid PDF
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\nxref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \ntrailer<</Size 3/Root 1 0 R>>\nstartxref\n107\n%%%%EOF' > "$DATA_DIR/download/documents/report.pdf"

# Code files for syntax highlighting
cat > "$DATA_DIR/download/code/script.js" << 'JS'
function greet(name) {
  const message = `Hello, ${name}!`;
  console.log(message);
  return message;
}
greet("World");
JS

cat > "$DATA_DIR/download/code/style.css" << 'CSS'
.container {
  display: flex;
  justify-content: center;
  background: #f0f0f0;
}
CSS

cat > "$DATA_DIR/download/code/main.lua" << 'LUA'
local function hello(name)
    return string.format("Hello, %s!", name)
end
print(hello("World"))
LUA

# Minimal 1x1 PNG
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' > "$DATA_DIR/download/images/logo.png"

# Archive file
echo "zip content" > /tmp/seed_zip_content.txt
tar -czf "$DATA_DIR/download/archives/project.tar.gz" -C /tmp seed_zip_content.txt 2>/dev/null || \
  (cd /tmp && tar -czf "$DATA_DIR/download/archives/project.tar.gz" seed_zip_content.txt)
rm -f /tmp/seed_zip_content.txt

# Chinese filenames
echo "Chinese content test" > "$DATA_DIR/download/中文测试文件.txt"

# UTF-8 directory
mkdir -p "$DATA_DIR/download/测试目录"
echo "nested content" > "$DATA_DIR/download/测试目录/nested_file.txt"

# Many files for pagination testing (> PAGE_LIMIT default 10)
for i in $(seq -w 1 30); do
  echo "File $i content" > "$DATA_DIR/download/many_files/file_${i}.txt"
done

# Deeply nested path
echo "deep file" > "$DATA_DIR/download/deep/nested/path/deep_file.txt"

# --- public/ ---
echo "Public shared note" > "$DATA_DIR/public/public-note.txt"
echo "Another public file" > "$DATA_DIR/public/readme.txt"

# --- archive/ ---
echo "Old report data" > "$DATA_DIR/archive/old_reports/2023-report.pdf"
echo "New report data" > "$DATA_DIR/archive/old_reports/2024-report.pdf"
echo "Backup config data" > "$DATA_DIR/archive/backup/config-backup.tar.gz"

# Copy static fileserver assets (needed for CSS, JS, images)
echo "=== Copying static assets ==="
rm -rf "$DATA_DIR/fileserver"
cp -r "$(cd "$(dirname "$0")/../../../fileserver" && pwd)" "$DATA_DIR/fileserver"

# Replace URL_PREFIX placeholders in static files
if [ "$URL_PREFIX" != "/" ]; then
  find "$DATA_DIR/fileserver" -type f \( -name "*.html" -o -name "*.js" \) -exec sed -i '' "s#<URL_PREFIX>#${URL_PREFIX}#g" {} \;
else
  find "$DATA_DIR/fileserver" -type f \( -name "*.html" -o -name "*.js" \) -exec sed -i '' "s#<URL_PREFIX>#/#g" {} \;
fi

# Replace LOGO_TEXT
find "$DATA_DIR/fileserver" -name "*.html" -exec sed -i '' "s#<LOGO_TEXT>#Test Files#g" {} \;

# Create auth_config.json
mkdir -p "$DATA_DIR/config"
cat > "$DATA_DIR/config/auth_config.json" << 'AUTH'
{
  "version": 1,
  "rules": {
    ".default": {
      "allow": [
        "all:/download",
        "all:/public",
        "all:/archive"
      ],
      "deny": []
    },
    "fileserver_admin": {
      "allow": [
        "all:/download",
        "all:/public",
        "all:/archive"
      ],
      "deny": []
    }
  }
}
AUTH

echo "=== Seed complete ==="
echo "Files in download: $(find "$DATA_DIR/download" -type f | wc -l)"
echo "Dirs in download: $(find "$DATA_DIR/download" -type d | wc -l)"
echo "Files in public: $(find "$DATA_DIR/public" -type f | wc -l)"
echo "Files in archive: $(find "$DATA_DIR/archive" -type f | wc -l)"
