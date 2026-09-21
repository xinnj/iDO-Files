/* File Server App - Client-side interactivity */

// State
let currentPath = '';
let fileData = { files: [], stats: {} };
let selectedItem = null;
let currentSort = { col: 'modified', dir: 'desc' };
let searchQuery = '';
let searchController = null;     // aborts the in-flight search request
let searchTimer = null;          // debounce timer
let searchSeq = 0;               // discards responses that arrive out of order
let urlPrefix = '<URL_PREFIX>';  // Store URL prefix (e.g., '/myteam')

// ==================== THEME MANAGEMENT ====================

function getSystemTheme() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function getStoredTheme() {
    return localStorage.getItem('theme');
}

function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    const btn = document.getElementById('themeToggle');
    if (btn) {
        btn.innerHTML = theme === 'dark'
            ? '<i class="ti ti-sun"></i>'
            : '<i class="ti ti-moon"></i>';
        btn.title = theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
    }
}

function toggleTheme() {
    const current = document.documentElement.getAttribute('data-theme') || 'light';
    const next = current === 'dark' ? 'light' : 'dark';
    localStorage.setItem('theme', next);
    applyTheme(next);
}

// Listen for system theme changes (when user hasn't manually selected)
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
    if (!getStoredTheme()) {
        applyTheme(e.matches ? 'dark' : 'light');
    }
});

// ==================== END THEME MANAGEMENT ====================

// Extract bucket name from current URL path
function getBucketFromUrl() {
    const path = window.location.pathname;
    // Match both /bucket and /prefix/bucket patterns
    const match = path.match(/^\/([^/]+\/(public|download|archive)|public|download|archive)/);
    if (match) {
        // Extract the bucket name from the full match
        const fullPath = match[1];
        const parts = fullPath.split('/');
        return parts[parts.length - 1]; // Last part is always the bucket
    }
    return 'public';
}

// Get API base URL for current bucket
function getApiBase() {
    return urlPrefix + getBucketFromUrl();  // No trailing slash to avoid double slashes
}

// Navigate to folder
function navigateToFolder(folderPath) {
    const bucket = getBucketFromUrl();
    const newUrl = urlPrefix + bucket + folderPath;
    window.location.href = encodeURI(newUrl);
}

// Navigate to parent folder
function navigateToParent() {
    const bucket = getBucketFromUrl();
    const parts = currentPath.split('/').filter(Boolean);
    parts.pop();
    const parentPath = '/' + parts.join('/');
    window.location.href = encodeURI(urlPrefix + bucket + parentPath);
}

// Files that browser can render natively (open directly)
const nativeTypes = ['html', 'htm', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'svg', 'ico', 'pdf'];

// Open file (inline or download)
function openFile(item) {
    const apiBase = getApiBase();

    if (item.type === 'directory') {
        navigateToFolder(item.path);
    } else if (item.inline) {
        const fileUrl = apiBase + item.path;
        const ext = item.name.split('.').pop().toLowerCase();
        if (nativeTypes.includes(ext)) {
            // Browser can render natively: open directly
            window.location.href = encodeURI(fileUrl);
        } else {
            // Other inline files: open in syntax-highlighted viewer
            const viewerUrl = urlPrefix + 'fileserver/viewer?url=' + encodeURIComponent(fileUrl);
            window.location.href = viewerUrl;
        }
    } else {
        window.location.href = encodeURI(apiBase + item.path);
    }
}

// Download file
function downloadFile(item) {
    const apiBase = getApiBase();
    window.location.href = encodeURI(apiBase + item.path);
}

// Copy file link to clipboard
function copyLink(item) {
    const url = window.location.origin + encodeURI(getApiBase() + item.path);
    navigator.clipboard.writeText(url).then(() => {
        showToast('Link copied!', 'success');
    }).catch(() => {
        showToast('Failed to copy link', 'error');
    });
}

// Share file (create share link)
function shareFile(item) {
    // For now, just copy the link - can be extended with actual share token generation
    const url = window.location.origin + encodeURI(getApiBase() + item.path);
    navigator.clipboard.writeText(url).then(() => {
        showToast(`Share link created for: ${item.name}`, 'success');
    }).catch(() => {
        showToast('Failed to create share link', 'error');
    });
}

// Share file by name (called from action button)
function shareFileByName(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (item) {
        shareFile(item);
    }
}

// Toast notification is now in toast.js

// ==================== CONTEXT MENU FUNCTIONS ====================

let currentContextFileName = null;

// Create context menu with same structure as three-dot dropdown
function showContextMenu(e, fileItem) {
    e.preventDefault();

    const name = fileItem.getAttribute('data-name');
    if (!name) return;

    currentContextFileName = name;

    // Hide three-dot menus first
    closeAllFileMenus();

    // Remove existing context menu
    const existingMenu = document.getElementById('contextMenuContent');
    if (existingMenu) existingMenu.remove();

    // Create context menu container
    const menu = document.createElement('div');
    menu.id = 'contextMenuContent';
    menu.className = 'context-menu visible';

    // Menu items configuration (same as three-dot dropdown)
    const menuItems = [
        { icon: 'ti-copy', label: 'Copy link', action: () => copyLinkByName(name) },
        { icon: 'ti-download', label: 'Download', action: () => downloadFileByName(name), showForFolder: false },
        { icon: 'ti-share', label: 'Share', action: () => showShareModal(name), writeable: true, showForFolder: false, hideForPublicBucket: true },
        { separator: true },
        { icon: 'ti-edit', label: 'Rename', action: () => showRenameModal(name), writeable: true },
        { icon: 'ti-arrows-move', label: 'Copy / Move', action: () => showCopyMoveModal(name), writeable: true },
        { icon: 'ti-trash', label: 'Delete', action: () => showDeleteModal(name), writeable: true, danger: true }
    ];

    // Check if user is writeable (check for writeable-specific items)
    const hasWriteableItems = menuItems.some(item => item.writeable);
    const isWriteable = hasWriteableItems ? fileItem.closest('.file-list')?.querySelector('.dropdown-separator') !== null : true;
    // Simplified: just check if the three-dot menu has the items
    const threeDotDropdown = fileItem.querySelector('.file-three-dot-dropdown');
    if (!threeDotDropdown) return;

    // Check what items exist in the three-dot dropdown
    const hasShare = threeDotDropdown.querySelector('.ti-share') !== null;
    const hasWriteable = threeDotDropdown.querySelector('.ti-edit') !== null;

    let lastAddedWasSeparator = false;
    menuItems.forEach(item => {
        // Check visibility conditions first
        if (item.writeable && !hasWriteable) return;
        if (item.showForFolder === false && fileItem.classList.contains('folder')) return;
        if (item.hideForPublicBucket && getBucketFromUrl() === 'public') return;

        if (item.separator) {
            // Add separator only if at least one item was already added
            if (menu.children.length > 0) {
                const sep = document.createElement('div');
                sep.className = 'dropdown-separator';
                menu.appendChild(sep);
                lastAddedWasSeparator = true;
            }
            return;
        }

        lastAddedWasSeparator = false;
        const menuItem = document.createElement('div');
        menuItem.className = 'dropdown-item' + (item.danger ? ' danger' : '');
        menuItem.innerHTML = `<i class="ti ${item.icon}"></i><span>${item.label}</span>`;
        menuItem.addEventListener('click', (evt) => {
            evt.stopPropagation();
            hideContextMenu();
            item.action();
        });
        menu.appendChild(menuItem);
    });

    // Remove trailing separator if present
    const lastChild = menu.lastElementChild;
    if (lastChild && lastChild.classList.contains('dropdown-separator')) {
        lastChild.remove();
    }

    // Append first (hidden) so we can measure, then position relative to cursor
    document.body.appendChild(menu);

    const menuWidth = 180;
    const menuHeight = menu.scrollHeight;
    let x = e.clientX;
    let y = e.clientY;

    const fileListEl = document.querySelector('.file-list');
    const clipBottom = fileListEl ? fileListEl.getBoundingClientRect().bottom : window.innerHeight;

    // Flip horizontally if menu would go off right edge
    if (x + menuWidth > window.innerWidth) {
        x = window.innerWidth - menuWidth - 10;
    }
    // Flip above cursor if menu would go off bottom edge
    if (y + menuHeight > clipBottom) {
        y = y - menuHeight;
    }

    menu.style.left = x + 'px';
    menu.style.top = y + 'px';
}

function hideContextMenu() {
    const menu = document.getElementById('contextMenuContent');
    if (menu) {
        menu.remove();
    }
    currentContextFileName = null;
}

// ==================== THREE-DOT MENU FUNCTIONS ====================

// Toggle file action dropdown menu
function toggleFileMenu(btn) {
    const menu = btn.closest('.file-three-dot-menu');
    const fileItem = btn.closest('.file-item');
    const isActive = menu.classList.contains('active');

    // Close all other menus first
    hideContextMenu();
    document.querySelectorAll('.file-three-dot-menu.active').forEach(m => {
        if (m !== menu) {
            m.classList.remove('active');
            const parent = m.closest('.file-item');
            if (parent) parent.classList.remove('has-active-dropdown');
        }
    });

    // Toggle current menu and manage z-index class
    if (isActive) {
        menu.classList.remove('active');
        if (fileItem) fileItem.classList.remove('has-active-dropdown');
    } else {
        // Check if dropdown fits below; flip above if not
        const dropdown = menu.querySelector('.file-three-dot-dropdown');
        if (dropdown) {
            const btnRect = btn.getBoundingClientRect();
            const items = dropdown.querySelectorAll('.dropdown-item');
            const separators = dropdown.querySelectorAll('.dropdown-separator');
            const estimatedHeight = items.length * 40 + separators.length * 13 + 12 + 10;
            const fileList = document.querySelector('.file-list');
            const clipBottom = fileList ? fileList.getBoundingClientRect().bottom : window.innerHeight;
            const clipTop = fileList ? fileList.getBoundingClientRect().top : 0;

            const fitsBelow = btnRect.bottom + estimatedHeight <= clipBottom;
            const fitsAbove = btnRect.top - estimatedHeight >= clipTop;

            if (!fitsBelow && fitsAbove) {
                dropdown.classList.add('drop-up');
            } else {
                dropdown.classList.remove('drop-up');
            }
        }

        menu.classList.add('active');
        if (fileItem) fileItem.classList.add('has-active-dropdown');
    }
}

// Close all file action menus
function closeAllFileMenus() {
    document.querySelectorAll('.file-three-dot-menu.active').forEach(m => {
        m.classList.remove('active');
        const parent = m.closest('.file-item');
        if (parent) parent.classList.remove('has-active-dropdown');
        // Remove focus from the button to prevent outline
        const btn = m.querySelector('.file-three-dot-btn');
        if (btn) btn.blur();
    });
}

// ==================== SEARCH ====================
//
// Search runs on the server. The page only ever holds one page of entries, so
// a query has to be answered by the directory listing itself — see
// list_directory() in lua/handler.lua. The client asks for the two regions it
// needs and swaps them in, so rows stay rendered in one place.

// The view URL for a query: the current params (so sort, dir and limit follow
// the view) with the query applied and the page reset to the first one.
function searchViewUrl(query) {
    const url = new URL(window.location.href);
    url.searchParams.delete('partial');
    url.searchParams.set('page', '1');
    const limit = fileData.pagination && fileData.pagination.limit;
    if (limit) url.searchParams.set('limit', limit);
    url.searchParams.set('sort', currentSort.col);
    url.searchParams.set('dir', currentSort.dir);
    if (query) {
        url.searchParams.set('q', query);
    } else {
        url.searchParams.delete('q');
    }
    return url;
}

// Swap in the server's regions and take over the data blob.
function applySearchPayload(payload, query) {
    const fileList = document.querySelector('.file-list');
    // innerHTML, not outerHTML: the element itself carries the scroll listener
    // that drives the edge-fade mask.
    if (fileList) fileList.innerHTML = payload.list;

    const bottomBar = document.querySelector('.bottom-bar');
    if (bottomBar) bottomBar.innerHTML = payload.bottom;

    if (payload.data) {
        fileData = payload.data;
        // actions.js resolves its target through fileData.files, so this has to
        // describe what is on screen or every row menu silently stops working.
        if (!Array.isArray(fileData.files)) fileData.files = [];
        const dataEl = document.getElementById('file-data');
        if (dataEl) dataEl.textContent = JSON.stringify(fileData);
    }

    const info = document.getElementById('search-results-info');
    const clearBtn = document.getElementById('search-clear');
    if (info) {
        if (query) {
            const count = document.getElementById('search-count');
            const term = document.getElementById('search-term');
            if (count) count.textContent = payload.count;
            if (term) term.textContent = query;
            info.classList.add('visible');
            if (clearBtn) clearBtn.classList.add('visible');
        } else {
            info.classList.remove('visible');
            if (clearBtn) clearBtn.classList.remove('visible');
        }
    }
}

// Ask the server for the filtered list and swap it in.
function runSearch(query) {
    const seq = ++searchSeq;
    if (searchController) searchController.abort();
    searchController = new AbortController();

    const viewUrl = searchViewUrl(query);
    const fetchUrl = new URL(viewUrl);
    fetchUrl.searchParams.set('partial', '1');

    fetch(fetchUrl.toString(), {
        signal: searchController.signal,
        headers: { 'Accept': 'application/json' }
    })
        .then(response => {
            if (!response.ok) throw new Error('HTTP ' + response.status);
            return response.json();
        })
        .then(payload => {
            // A newer search has already been applied; this response is stale.
            if (seq !== searchSeq) return;
            searchQuery = query;
            applySearchPayload(payload, query);
            history.replaceState(null, '', viewUrl.toString());
        })
        .catch(err => {
            if (err.name === 'AbortError' || seq !== searchSeq) return;
            console.error('Search failed:', err);
            // Leave the previous list in place rather than clearing it.
            showToast('Search failed. Please try again.', 'error');
        });
}

// Debounce keystrokes: the request that matters is the last one.
function scheduleSearch(query, delay) {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => runSearch(query), delay === undefined ? 200 : delay);
}

// Attach event listeners to file items (no longer needed - using inline handlers)
// Kept for potential dynamic content in the future
function attachFileItemEvents() {
    // Event handlers are now inline in HTML from SSR
}

// Handle file click (single click)
function handleFileClick(event, path, name) {
    // Don't trigger if clicking on three-dot menu or its dropdown
    if (event.target.closest('.file-three-dot-menu')) {
        return;
    }

    // If context menu is open, just close it without triggering file action
    const contextMenu = document.getElementById('contextMenuContent');
    if (contextMenu) {
        hideContextMenu();
        return;
    }

    // If three-dot dropdown menu is open, just close it without triggering file action
    if (document.querySelector('.file-three-dot-menu.active')) {
        closeAllFileMenus();
        return;
    }

    const fileItem = fileData.files.find(f => f.name === name);
    if (fileItem) {
        openFile(fileItem);
    }
}

// Handle file double-click
function handleFileDblClick(event, name, isFolder) {
    if (event.target.closest('.file-three-dot-menu')) return;

    // If context menu is open, just close it without triggering file action
    const contextMenu = document.getElementById('contextMenuContent');
    if (contextMenu) {
        hideContextMenu();
        return;
    }

    // If three-dot dropdown menu is open, just close it without triggering file action
    if (document.querySelector('.file-three-dot-menu.active')) {
        closeAllFileMenus();
        return;
    }

    const fileItem = fileData.files.find(f => f.name === name);
    if (fileItem) {
        if (isFolder === 'true') {
            navigateToFolder(fileItem.path);
        } else {
            openFile(fileItem);
        }
    }
}

// Handle sort header click
function handleSortClick(sortKey) {
    // Toggle direction if same column, otherwise reset to asc
    if (currentSort.col === sortKey) {
        currentSort.dir = currentSort.dir === 'asc' ? 'desc' : 'asc';
    } else {
        currentSort.col = sortKey;
        currentSort.dir = 'asc';
    }

    // Update UI
    document.querySelectorAll('.sort-col').forEach(c => {
        c.classList.remove('active', 'asc', 'desc');
        const icon = c.querySelector('.sort-icon i');
        if (icon) icon.className = 'ti ti-arrow-up';
    });
    
    const activeCol = document.querySelector(`.sort-col[data-sort="${sortKey}"]`);
    if (activeCol) {
        activeCol.classList.add('active', currentSort.dir);
        const icon = activeCol.querySelector('.sort-icon i');
        if (icon) {
            icon.className = currentSort.dir === 'asc' ? 'ti ti-arrow-up' : 'ti ti-arrow-down';
        }
    }

    // Sort file items in the DOM (folders always on top)
    const fileList = document.querySelector('.file-list');
    const items = Array.from(fileList.querySelectorAll('.file-item'));
    const folders = items.filter(item => item.classList.contains('folder'));
    const files = items.filter(item => !item.classList.contains('folder'));

    const sortItems = (arr) => {
        return arr.sort((a, b) => {
            let valA, valB;
            switch (sortKey) {
                case 'name':
                    valA = a.querySelector('.file-name').textContent.toLowerCase();
                    valB = b.querySelector('.file-name').textContent.toLowerCase();
                    break;
                case 'modified':
                    valA = a.querySelector('.file-date').textContent;
                    valB = b.querySelector('.file-date').textContent;
                    break;
                case 'size':
                    valA = a.querySelector('.file-size').textContent;
                    valB = b.querySelector('.file-size').textContent;
                    break;
                default:
                    return 0;
            }
            if (valA < valB) return currentSort.dir === 'asc' ? -1 : 1;
            if (valA > valB) return currentSort.dir === 'asc' ? 1 : -1;
            return 0;
        });
    };

    // Sort folders and files separately, then combine (folders first)
    const sortedFolders = sortItems(folders);
    const sortedFiles = sortItems(files);

    // Nothing to reorder when the list is showing an empty state: clearing it
    // would leave a blank area with nothing to explain it. Sort state still
    // updates below, so a reload applies the new sort to the real listing.
    if (sortedFolders.length + sortedFiles.length > 0) {
        // Clear and re-append in sorted order
        fileList.innerHTML = '';
        [...sortedFolders, ...sortedFiles].forEach(item => fileList.appendChild(item));
    }

    // Persist sort state in URL so it survives page reload (delete, rename, etc.)
    const url = new URL(window.location.href);
    url.searchParams.set('sort', currentSort.col);
    url.searchParams.set('dir', currentSort.dir);
    history.replaceState(null, '', url.toString());
}

// Escape HTML special characters (used for dynamic content in search)
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Capitalize first letter (currently unused but kept for potential future use)
function capitalize(str) {
    if (!str) return '';
    return str.charAt(0).toUpperCase() + str.slice(1);
}

// Initialize on DOM load
document.addEventListener('DOMContentLoaded', function() {
    // Apply theme (toggle button icon update)
    const storedTheme = getStoredTheme();
    const theme = storedTheme || getSystemTheme();
    applyTheme(theme);

    // Build regex pattern that matches both /bucket and /prefix/bucket
    let pathMatch;
    if (urlPrefix !== '/') {
        // With prefix: /myteam/download/...
        pathMatch = window.location.pathname.match(new RegExp('^' + urlPrefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(public|download|archive)(.*)'));
    } else {
        // Without prefix: /download/...
        pathMatch = window.location.pathname.match(/^\/(public|download|archive)(.*)/);
    }
    
    if (pathMatch) {
        // Decode the path to handle Chinese characters properly
        currentPath = decodeURIComponent(pathMatch[2]) || '/';
    }

    // Initialize sort state from URL query params (preserved across page reloads)
    const urlParams = new URLSearchParams(window.location.search);
    const urlSort = urlParams.get('sort');
    const urlDir = urlParams.get('dir');
    if (urlSort && ['name', 'size', 'modified'].includes(urlSort)) {
        currentSort.col = urlSort;
    }
    if (urlDir && ['asc', 'desc'].includes(urlDir)) {
        currentSort.dir = urlDir;
    }

    // Load file metadata from embedded JSON (used for search, sort, and file operations)
    const dataEl = document.getElementById('file-data');
    if (dataEl) {
        try {
            fileData = JSON.parse(dataEl.textContent);
        } catch (e) {
            console.error('Failed to parse file data:', e);
            fileData = { files: [], stats: {} };
        }
    } else {
        console.warn('File data element not found');
        fileData = { files: [], stats: {} };
    }

    // Setup simple upload (single file, inline progress bar)
    const simpleUploadInput = document.getElementById('simpleUploadInput');
    const uploadBtn = document.getElementById('upload-btn');
    const uploadBanner = document.getElementById('uploadBanner');
    const uploadBannerFill = document.getElementById('uploadBannerFill');
    const uploadBannerPct = document.getElementById('uploadBannerPct');
    const uploadBannerFilename = document.getElementById('uploadBannerFilename');
    const uploadBannerIcon = document.getElementById('uploadBannerIcon');
    const uploadCancelBtn = document.getElementById('uploadCancelBtn');

    if (simpleUploadInput) {
        let uploadInProgress = false;
        let currentXhr = null;

        function setUploadProgress(percent, filename) {
            uploadBannerFill.style.width = percent + '%';
            uploadBannerPct.textContent = percent + '%';
            uploadBannerFilename.textContent = filename;
        }

        function startUpload(filename) {
            uploadInProgress = true;
            if (uploadBtn) uploadBtn.disabled = true;
            uploadBanner.style.display = 'flex';
            uploadBanner.classList.remove('complete');
            uploadBannerFill.style.width = '0%';
            uploadBannerPct.textContent = '0%';
            uploadBannerFilename.textContent = filename;
            uploadBannerIcon.textContent = '📄';
            uploadCancelBtn.style.display = '';
        }

        function finishUpload(success) {
            uploadInProgress = false;
            currentXhr = null;
            if (uploadBtn) uploadBtn.disabled = false;
            if (success) {
                uploadBanner.classList.add('complete');
                uploadBannerIcon.textContent = '✅';
                uploadBannerPct.textContent = 'Done';
                setTimeout(function () { location.reload(); }, 800);
            } else {
                uploadBanner.style.display = 'none';
                uploadCancelBtn.style.display = 'none';
            }
        }

        // Cancel button click handler
        if (uploadCancelBtn) {
            uploadCancelBtn.addEventListener('click', function () {
                if (currentXhr && confirm('Cancel this upload?')) {
                    currentXhr.abort();
                }
            });
        }

        // beforeunload guard: prevent accidental navigation during upload
        function beforeUnloadHandler(e) {
            if (uploadInProgress) {
                e.preventDefault();
                e.returnValue = '';
            }
        }

        function doUploadFile(file) {
            window.addEventListener('beforeunload', beforeUnloadHandler);

            var formData = new FormData();
            formData.append('file', file);

            var xhr = new XMLHttpRequest();
            currentXhr = xhr;
            xhr.open('POST', window.location.href, true);

            xhr.upload.addEventListener('progress', function (e) {
                if (e.lengthComputable) {
                    var percent = Math.round((e.loaded / e.total) * 100);
                    setUploadProgress(percent, file.name);
                }
            });

            xhr.addEventListener('load', function () {
                window.removeEventListener('beforeunload', beforeUnloadHandler);
                if (xhr.status >= 200 && xhr.status < 300) {
                    finishUpload(true);
                } else if (xhr.status === 401) {
                    finishUpload(false);
                    showToast('Session expired. Please refresh the page and log in again.', 'error');
                } else if (xhr.status === 400) {
                    // The backend rejects a filename it cannot sanitize with a
                    // 400 and an empty body, so a bare "HTTP 400" gave the user
                    // nothing to act on.
                    finishUpload(false);
                    showToast(
                        'Upload failed: the filename was not accepted. Only letters, ' +
                        'numbers, CJK characters, spaces, dots, underscores and hyphens are allowed.',
                        'error'
                    );
                } else {
                    finishUpload(false);
                    showToast('Upload failed: HTTP ' + xhr.status, 'error');
                }
            });

            xhr.addEventListener('error', function () {
                window.removeEventListener('beforeunload', beforeUnloadHandler);
                finishUpload(false);
                showToast('Upload failed: network error', 'error');
            });

            xhr.addEventListener('abort', function () {
                window.removeEventListener('beforeunload', beforeUnloadHandler);
                finishUpload(false);
                showToast('Upload cancelled', 'warning');
            });

            startUpload(file.name);
            xhr.send(formData);
        }

        simpleUploadInput.addEventListener('change', function () {
            var file = this.files[0];
            if (!file) return;

            // Guard against concurrent uploads
            if (uploadInProgress) {
                this.value = '';
                showToast('An upload is already in progress', 'warning');
                return;
            }

            // Reset input so re-selecting the same file triggers change again
            this.value = '';

            // Pre-flight: check session validity before uploading to avoid
            // wasting time on an upload that will fail due to expired session.
            // probeSession() times out and fails open, so a stalled check can no
            // longer leave the upload silently unstarted.
            probeSession(urlPrefix + 'fileserver/userinfo', function (sessionValid) {
                if (!sessionValid) {
                    showToast(SESSION_EXPIRED_MSG, 'error');
                    return;
                }
                doUploadFile(file);
            });
        });
    }

    // Setup event listeners
    const searchInput = document.getElementById('search-input');
    const searchClear = document.getElementById('search-clear');
    const searchResultsInfo = document.getElementById('search-results-info');
    const clearSearchBtn = document.getElementById('clear-search');

    // A ?q= URL arrives already filtered from the server, so adopt it as the
    // current query: typing after it is then an edit, not a reset.
    if (searchInput) searchQuery = searchInput.value.trim();

    if (searchInput) {
        // Use composition events for better IME (Chinese/Japanese/Korean) support
        let isComposing = false;
        
        searchInput.addEventListener('compositionstart', () => {
            isComposing = true;
        });
        
        searchInput.addEventListener('compositionend', (e) => {
            isComposing = false;
            // Trigger search after IME composition ends
            performSearch(e.target.value);
        });
        
        searchInput.addEventListener('input', (e) => {
            // Only search if not composing (IME in progress)
            if (!isComposing) {
                performSearch(e.target.value);
            }
        });
    }

    if (searchClear) {
        searchClear.addEventListener('click', clearSearch);
    }

    if (clearSearchBtn) {
        clearSearchBtn.addEventListener('click', clearSearch);
    }

    // The server renders the filtered list and reports how many entries match;
    // typing only schedules a request for it. The banner is filled in from the
    // response, so its count is the number of matches in the folder rather than
    // the number of rows that happen to be on this page.
    function performSearch(query) {
        const q = query.trim();
        if (q === searchQuery) return;
        scheduleSearch(q);
    }

    function clearSearch() {
        if (searchInput) searchInput.value = '';
        if (searchClear) searchClear.classList.remove('visible');
        if (searchResultsInfo) searchResultsInfo.classList.remove('visible');
        searchQuery = '';
        scheduleSearch('', 0);
        if (searchInput) searchInput.focus();
    }

    // User dropdown menu
    const userMenu = document.getElementById('userMenu');
    const userTrigger = document.getElementById('userTrigger');

    if (userTrigger && userMenu) {
        userTrigger.addEventListener('click', (e) => {
            e.stopPropagation();
            userMenu.classList.toggle('active');
            closeAllFileMenus();
        });

        // Close user dropdown when clicking outside
        document.addEventListener('click', (e) => {
            if (!userMenu.contains(e.target)) {
                userMenu.classList.remove('active');
            }
            // Close file menus when clicking outside
            if (!e.target.closest('.file-three-dot-menu')) {
                closeAllFileMenus();
            }
            // Close context menu when clicking outside
            const contextMenu = document.getElementById('contextMenuContent');
            if (contextMenu && !e.target.closest('.context-menu')) {
                hideContextMenu();
            }
        });

        // Prevent dropdown close when clicking inside
        userMenu.addEventListener('click', (e) => {
            e.stopPropagation();
        });
    }

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
        // Ctrl+K to focus search
        if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
            e.preventDefault();
            const searchInput = document.getElementById('search-input');
            if (searchInput) {
                searchInput.focus();
                searchInput.select();
            }
        }

        // Escape to close menus and clear search
        if (e.key === 'Escape') {
            // Close user dropdown if open
            const userMenu = document.getElementById('userMenu');
            if (userMenu && userMenu.classList.contains('active')) {
                userMenu.classList.remove('active');
            }
            // Close file menus if open
            closeAllFileMenus();
            // Close context menu if open
            hideContextMenu();
            // Close any open modals
            document.querySelectorAll('.modal-overlay.visible').forEach(modal => {
                modal.classList.remove('visible');
            });
            // Clear search if focused
            const searchInput = document.getElementById('search-input');
            if (document.activeElement === searchInput) {
                clearSearch();
                searchInput.blur();
            }
        }

        // Backspace to go to parent (when not in input)
        if (e.key === 'Backspace' && document.activeElement.tagName !== 'INPUT') {
            navigateToParent();
        }
    });

    // Toggle edge-fade mask based on scroll position
    const fileList = document.querySelector('.file-list');
    if (fileList) {
        function updateFadeEdges() {
            const scrolledDown = fileList.scrollTop > 2;
            const hasMoreBelow = fileList.scrollTop + fileList.clientHeight < fileList.scrollHeight - 2;
            fileList.classList.toggle('scrollable-before', scrolledDown);
            fileList.classList.toggle('scrollable-after', hasMoreBelow);
        }
        updateFadeEdges();
        fileList.addEventListener('scroll', updateFadeEdges, { passive: true });
        window.addEventListener('resize', updateFadeEdges, { passive: true });
    }
});
