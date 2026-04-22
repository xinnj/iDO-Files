/* File Server App - Client-side interactivity */

// State
let currentPath = '';
let fileData = { files: [], stats: {} };
let selectedItem = null;
let currentSort = { col: 'modified', dir: 'desc' };
let searchQuery = '';
let urlPrefix = '<URL_PREFIX>';  // Store URL prefix (e.g., '/myteam')

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
        { icon: 'ti-share', label: 'Share', action: () => showShareModal(name), writeable: true, showForFolder: false },
        { separator: true },
        { icon: 'ti-edit', label: 'Rename', action: () => showRenameModal(name), writeable: true },
        { icon: 'ti-arrows-move', label: 'Copy/Move', action: () => showMoveModal(name), writeable: true },
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

    menuItems.forEach(item => {
        if (item.separator) {
            // Only add separator if we have items after it
            const hasItemsAfter = menuItems.slice(menuItems.indexOf(item) + 1).some(i => !i.separator);
            if (hasItemsAfter) {
                const sep = document.createElement('div');
                sep.className = 'dropdown-separator';
                menu.appendChild(sep);
            }
            return;
        }

        // Check visibility conditions
        if (item.writeable && !hasWriteable) return;
        if (item.showForFolder === false && fileItem.classList.contains('folder')) return;

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

    // Position menu
    const menuWidth = 180;
    let x = e.clientX;
    let y = e.clientY;

    // Adjust if menu would go off screen
    if (x + menuWidth > window.innerWidth) {
        x = window.innerWidth - menuWidth - 10;
    }
    if (y + 200 > window.innerHeight) {
        y = window.innerHeight - 220;
    }

    menu.style.left = x + 'px';
    menu.style.top = y + 'px';
    document.body.appendChild(menu);
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

    // Close all other menus first and remove their active classes
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
        menu.classList.add('active');
        if (fileItem) fileItem.classList.add('has-active-dropdown');
    }
}

// Copy link by filename
function copyLinkByName(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (item) {
        const url = window.location.origin + encodeURI(getApiBase() + item.path);
        navigator.clipboard.writeText(url).then(() => {
            showToast('Link copied!', 'success');
        }).catch(() => {
            showToast('Failed to copy link', 'error');
        });
    }
    closeAllFileMenus();
}

// Download file by filename (force save dialog regardless of inline type)
function downloadFileByName(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (item) {
        const apiBase = getApiBase();
        // Add ?download=1 to force save dialog for inline types too
        window.location.href = encodeURI(apiBase + item.path) + '?download=1';
    }
    closeAllFileMenus();
}

// ==================== RENAME FUNCTIONS ====================
let currentRenameFilePath = '';

showRenameModal = function(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (!item) return;

    currentRenameFilePath = item.path;

    // Set current name in modal
    const currentNameEl = document.getElementById('renameCurrentName');
    if (currentNameEl) {
        currentNameEl.textContent = item.name;
    }

    // Set new name input with current name
    const newNameInput = document.getElementById('renameNewName');
    if (newNameInput) {
        newNameInput.value = item.name;
        // Select the filename without extension for easy renaming
        const lastDot = item.name.lastIndexOf('.');
        if (lastDot > 0 && item.type !== 'directory') {
            setTimeout(() => {
                newNameInput.setSelectionRange(0, lastDot);
                newNameInput.focus();
            }, 50);
        } else {
            setTimeout(() => {
                newNameInput.select();
                newNameInput.focus();
            }, 50);
        }
    }

    openModal('renameModal');
    closeAllFileMenus();
};

confirmRename = function() {
    const newNameInput = document.getElementById('renameNewName');
    if (!newNameInput || !currentRenameFilePath) return;

    const newName = newNameInput.value.trim();
    if (!newName) {
        showToast('Please enter a name', 'error');
        return;
    }

    // Get current bucket
    const bucket = getBucketFromUrl();

    // Construct source and destination paths
    const sourcePath = urlPrefix + bucket + currentRenameFilePath;
    const destPath = sourcePath.substring(0, sourcePath.lastIndexOf('/') + 1) + encodeURIComponent(newName);

    showToast('Renaming...', 'info');

    fetch(encodeURI(sourcePath), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `dest=${encodeURIComponent(destPath)}&action=move`
    })
    .then(response => {
        if (response.ok) {
            showToast('Renamed successfully', 'success');
            closeModal('renameModal');
            setTimeout(() => window.location.reload(), 1500);
        } else {
            return response.text().then(text => {
                let errorMsg = `HTTP error! status: ${response.status}`;
                if (response.status === 403) {
                    errorMsg = 'Write permission required to rename folder/file';
                }
                throw new Error(errorMsg);
            });
        }
    })
    .catch(error => {
        showToast(`Failed to rename: ${error.message}`, 'error');
    });
};

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

// Sort files
function sortFiles(files, col, dir) {
    const sorted = [...files].sort((a, b) => {
        // Directories always first
        if (a.type === 'directory' && b.type !== 'directory') return -1;
        if (a.type !== 'directory' && b.type === 'directory') return 1;

        let valA, valB;
        switch (col) {
            case 'name':
                // Use localeCompare for proper Unicode/Chinese support
                return dir === 'asc' ? a.name.localeCompare(b.name) : b.name.localeCompare(a.name);
            case 'size':
                valA = a.size || 0;
                valB = b.size || 0;
                break;
            case 'modified':
                valA = a.modified || '';
                valB = b.modified || '';
                break;
            case 'type':
                valA = a.type || '';
                valB = b.type || '';
                break;
            default:
                // Use localeCompare for proper Unicode/Chinese support
                return dir === 'asc' ? a.name.localeCompare(b.name) : b.name.localeCompare(a.name);
        }

        if (valA < valB) return dir === 'asc' ? -1 : 1;
        if (valA > valB) return dir === 'asc' ? 1 : -1;
        return 0;
    });
    return sorted;
}

// Filter files by search query
function filterFiles(files, query) {
    if (!query) return files;
    
    // For better Unicode/Chinese support, use indexOf which works with all characters
    const q = query.trim();
    if (!q) return files;
    
    return files.filter(f => {
        const name = f.name;
        // Use indexOf for case-insensitive search (works with Chinese)
        return name.toLowerCase().indexOf(q.toLowerCase()) !== -1;
    });
}

// Filter and display file list using DOM manipulation (no re-rendering)
function renderFileList() {
    const fileList = document.querySelector('.file-list');
    if (!fileList) return;

    // Get all existing file items from DOM
    let allItems = Array.from(fileList.querySelectorAll('.file-item'));
    
    // If no items found (e.g., after empty search), reload page to get fresh data from backend
    // This happens when innerHTML was replaced with empty state
    // But only reload if not currently typing (to avoid refresh during IME input)
    if (allItems.length === 0 && fileData.files.length > 0 && !searchQuery) {
        window.location.reload();
        return;
    }

    // Build a map of filename -> DOM element for quick lookup
    const itemMap = {};
    allItems.forEach(item => {
        const name = item.getAttribute('data-name');
        if (name) itemMap[name] = item;
    });

    // Get filtered and sorted file list from data
    let files = [...fileData.files];
    files = filterFiles(files, searchQuery);
    files = sortFiles(files, currentSort.col, currentSort.dir);

    // Hide empty state if it exists
    const emptyState = fileList.querySelector('.empty-state');
    if (emptyState) emptyState.remove();

    if (files.length === 0) {
        // Show empty state in file list
        fileList.innerHTML = `
            <div class="empty-state visible">
                <i class="ti ti-folder-open"></i>
                <h3>${searchQuery ? 'No files found' : 'This folder is empty'}</h3>
                <p>${searchQuery ? 'Try adjusting your search terms' : 'Upload files to get started'}</p>
            </div>
        `;
        updateSearchResultsUI();
        return;
    }

    // Create a set of visible file names for quick lookup
    const visibleNames = new Set(files.map(f => f.name));

    // Hide non-matching items, show matching items
    allItems.forEach(item => {
        const name = item.getAttribute('data-name');
        if (visibleNames.has(name)) {
            item.style.display = '';
        } else {
            item.style.display = 'none';
        }
    });

    // Reorder DOM elements to match sorted order
    const fragment = document.createDocumentFragment();
    files.forEach(file => {
        const item = itemMap[file.name];
        if (item) {
            fragment.appendChild(item);
        }
    });
    fileList.appendChild(fragment);

    updateSearchResultsUI();
}

// Update search results info UI
function updateSearchResultsUI() {
    const searchResultsInfo = document.getElementById('search-results-info');
    const searchCount = document.getElementById('search-count');
    const searchTerm = document.getElementById('search-term');
    const searchClear = document.getElementById('search-clear');
    const emptySearch = document.getElementById('empty-search');

    if (searchQuery && searchResultsInfo) {
        const visibleCount = document.querySelectorAll('.file-item[style=""], .file-item:not([style])').length;
        searchResultsInfo.classList.add('visible');
        if (searchCount) searchCount.textContent = visibleCount;
        if (searchTerm) searchTerm.textContent = searchQuery;
        if (searchClear) searchClear.classList.add('visible');

        // Hide the template's empty-search div to avoid duplicate "not found" messages
        if (emptySearch) emptySearch.classList.remove('visible');
    } else {
        if (searchResultsInfo) searchResultsInfo.classList.remove('visible');
        if (emptySearch) emptySearch.classList.remove('visible');
        if (searchClear) searchClear.classList.remove('visible');
    }
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

    const fileItem = fileData.files.find(f => f.name === name);
    if (fileItem) {
        openFile(fileItem);
    }
}

// Handle file double-click
function handleFileDblClick(event, name, isFolder) {
    if (event.target.closest('.file-three-dot-menu')) return;

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
    
    // Clear and re-append in sorted order
    fileList.innerHTML = '';
    [...sortedFolders, ...sortedFiles].forEach(item => fileList.appendChild(item));
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

// Update stats display (called after search filtering)
function updateStats() {
    const statsBar = document.querySelector('.stats-bar');
    if (!statsBar) return;

    const statValues = statsBar.querySelectorAll('.stat-value');
    if (statValues.length >= 4) {
        statValues[0].textContent = fileData.stats.total || 0;
        statValues[1].textContent = fileData.stats.folders || 0;
        statValues[2].textContent = fileData.stats.files || 0;
        statValues[3].textContent = fileData.stats.size_formatted || '0 B';
    }
}

// Initialize on DOM load
document.addEventListener('DOMContentLoaded', function() {
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

    // Setup event listeners
    const searchInput = document.getElementById('search-input');
    const searchClear = document.getElementById('search-clear');
    const searchResultsInfo = document.getElementById('search-results-info');
    const searchCount = document.getElementById('search-count');
    const searchTerm = document.getElementById('search-term');
    const clearSearchBtn = document.getElementById('clear-search');
    const emptySearch = document.getElementById('empty-search');

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

    function performSearch(query) {
        const q = query.trim();
        searchQuery = q;

        // Filter files from data
        let filteredFiles = filterFiles(fileData.files, q);
        let matchCount = filteredFiles.length;

        // Update search results info
        if (q.length > 0 && searchResultsInfo) {
            searchResultsInfo.classList.add('visible');
            if (searchCount) searchCount.textContent = matchCount;
            if (searchTerm) searchTerm.textContent = query;
            if (searchClear) searchClear.classList.add('visible');
        } else {
            if (searchResultsInfo) searchResultsInfo.classList.remove('visible');
            if (searchClear) searchClear.classList.remove('visible');
        }

        renderFileList();
    }

    function clearSearch() {
        if (searchInput) searchInput.value = '';
        if (searchClear) searchClear.classList.remove('visible');
        if (searchResultsInfo) searchResultsInfo.classList.remove('visible');
        if (emptySearch) emptySearch.classList.remove('visible');
        searchQuery = '';
        renderFileList();
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
});
