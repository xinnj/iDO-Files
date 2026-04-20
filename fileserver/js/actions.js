/* File Server Actions - Move, Share, Delete operations */

// Modal Management Functions
closeModal = function(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.remove('visible');
        setTimeout(() => {
            modal.style.display = 'none';
        }, 200);
    }
};

openModal = function(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.style.display = 'flex';
        // Trigger reflow
        modal.offsetHeight;
        modal.classList.add('visible');
    }
};

// Close modal when clicking overlay
document.addEventListener('click', function(e) {
    if (e.target.classList.contains('modal-overlay')) {
        closeModal(e.target.id);
    }
});

// ==================== MOVE OPERATIONS ====================
let currentMoveFilePath = '';

showMoveModal = function(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (!item) return;
    
    currentMoveFilePath = item.path;
    
    // Get current bucket and prefix for display
    const bucket = getBucketFromUrl();
    
    // Set source path with full path including prefix and bucket
    const sourceEl = document.getElementById('moveSourcePath');
    if (sourceEl) {
        const fullPath = urlPrefix + bucket + item.path;
        sourceEl.textContent = decodeURIComponent(fullPath);
    }
    
    // Hide current bucket from destination options
    const destSelect = document.getElementById('moveDestSelect');
    if (destSelect) {
        Array.from(destSelect.options).forEach(option => {
            option.style.display = option.value === bucket ? 'none' : '';
        });
        // Select first visible option
        const firstVisible = Array.from(destSelect.options).find(opt => opt.style.display !== 'none');
        if (firstVisible) {
            destSelect.value = firstVisible.value;
        }
    }
    
    // Reset copy checkbox
    const copyCheckbox = document.getElementById('moveAsCopy');
    if (copyCheckbox) {
        copyCheckbox.checked = false;
    }
    
    openModal('moveModal');
};

confirmMove = function() {
    const destSelect = document.getElementById('moveDestSelect');
    const copyCheckbox = document.getElementById('moveAsCopy');
    
    if (!destSelect || !currentMoveFilePath) return;
    
    const destination = destSelect.value;
    const isCopy = copyCheckbox ? copyCheckbox.checked : false;
    
    // Get current bucket from URL
    const currentBucket = getBucketFromUrl();
    
    // Construct full source path: /prefix/bucket/item.path
    const fullSourcePath = urlPrefix + currentBucket + currentMoveFilePath;
    
    // Construct destination path: /prefix/destination/item.path
    const destPath = urlPrefix + destination + currentMoveFilePath;
    
    const action = isCopy ? 'copy' : 'move';
    const actionText = isCopy ? 'Copying' : 'Moving';
    
    showToast(`${actionText} ${decodeURIComponent(currentMoveFilePath)}...`, 'info');
    
    fetch(encodeURI(fullSourcePath), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `dest=${encodeURIComponent(destPath)}&action=${action}`
    })
    .then(response => {
        if (response.ok) {
            showToast(`${isCopy ? 'Copied' : 'Moved'} successfully`, 'success');
            closeModal('moveModal');
            setTimeout(() => window.location.reload(), 1500);
        } else {
            showToast(`Failed to ${action} file`, 'error');
        }
    })
    .catch(error => {
        showToast(`Error: ${error.message}`, 'error');
    });
};

// ==================== DELETE OPERATIONS ====================
let currentDeleteFilePath = '';

showDeleteModal = function(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (!item) return;
    
    // Get current bucket and construct full file path
    const bucket = getBucketFromUrl();
    currentDeleteFilePath = urlPrefix + bucket + item.path;
    
    // Set file path in modal message
    const messageEl = document.getElementById('deleteModalMessage');
    if (messageEl) {
        try {
            messageEl.textContent = decodeURIComponent(currentDeleteFilePath);
        } catch (e) {
            messageEl.textContent = currentDeleteFilePath;
        }
    }
    
    openModal('deleteModal');
    
    // Set up "Cancel" button - remove existing listeners and add new one
    const cancelBtn = document.getElementById('deleteCancelBtn');
    if (cancelBtn) {
        const newCancelBtn = cancelBtn.cloneNode(true);
        cancelBtn.parentNode.replaceChild(newCancelBtn, cancelBtn);
        newCancelBtn.addEventListener('click', () => {
            closeModal('deleteModal');
        });
    }
    
    // Set up "Delete" button - remove existing listeners and add new one
    const confirmBtn = document.getElementById('deleteConfirmBtn');
    if (confirmBtn) {
        const newConfirmBtn = confirmBtn.cloneNode(true);
        confirmBtn.parentNode.replaceChild(newConfirmBtn, confirmBtn);
        newConfirmBtn.addEventListener('click', () => {
            closeModal('deleteModal');
            deleteFile(currentDeleteFilePath);
        });
    }
};

deleteFile = function(fullFilePath) {
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }
    
    showToast(`Deleting "${displayPath}"...`, 'info');
    
    fetch(encodeURI(fullFilePath), { method: 'DELETE' })
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        showToast(`"${displayPath}" deleted successfully`, 'success');
        // Reload page after a short delay to show the success message
        setTimeout(() => {
            window.location.reload();
        }, 1500);
    })
    .catch(error => {
        showToast(`"${displayPath}" deleted unsuccessfully: ${error.message}`, 'error');
    });
};

// ==================== SHARE OPERATIONS ====================
let currentShareFilePath = '';

showShareModal = function(itemName) {
    const item = fileData.files.find(f => f.name === itemName);
    if (!item) return;
    
    // Get current bucket and prefix for full path
    const bucket = getBucketFromUrl();
    
    // Construct full file path like old solution
    currentShareFilePath = urlPrefix + bucket + item.path;
    
    // Set file name/path display
    const fileNameEl = document.getElementById('shareFileName');
    if (fileNameEl) {
        try {
            fileNameEl.textContent = decodeURIComponent(currentShareFilePath);
        } catch (e) {
            fileNameEl.textContent = currentShareFilePath;
        }
    }
    
    // Clear links container
    const linksContainer = document.getElementById('shareLinksContainer');
    if (linksContainer) {
        linksContainer.innerHTML = '';
    }
    
    // Reset to create section
    showCreateShareSection();
    
    openModal('shareModal');
    
    // Set up "Cancel" button - remove existing listeners and add new one
    const cancelBtn = document.getElementById('shareCancelBtn');
    if (cancelBtn) {
        const newCancelBtn = cancelBtn.cloneNode(true);
        cancelBtn.parentNode.replaceChild(newCancelBtn, cancelBtn);
        newCancelBtn.addEventListener('click', () => {
            closeModal('shareModal');
        });
    }
    
    // Set up "Close" button - remove existing listeners and add new one
    const closeBtn = document.getElementById('shareCloseBtn');
    if (closeBtn) {
        const newCloseBtn = closeBtn.cloneNode(true);
        closeBtn.parentNode.replaceChild(newCloseBtn, closeBtn);
        newCloseBtn.addEventListener('click', () => {
            closeModal('shareModal');
        });
    }
    
    // Set up "Create Link" button - remove existing listeners and add new one
    const createBtn = document.getElementById('shareCreateBtn');
    if (createBtn) {
        const newCreateBtn = createBtn.cloneNode(true);
        createBtn.parentNode.replaceChild(newCreateBtn, createBtn);
        newCreateBtn.addEventListener('click', () => {
            createShareLink();
        });
    }
    
    // Set up "Create New Link" button - remove existing listeners and add new one
    const createNewBtn = document.getElementById('shareCreateNewBtn');
    if (createNewBtn) {
        const newCreateNewBtn = createNewBtn.cloneNode(true);
        createNewBtn.parentNode.replaceChild(newCreateNewBtn, createNewBtn);
        newCreateNewBtn.addEventListener('click', () => {
            showCreateShareSection();
        });
    }
    
    // Load existing share links (this will show/hide sections based on results)
    loadShareLinks(currentShareFilePath);
};

showCreateShareSection = function() {
    const createSection = document.getElementById('shareCreateSection');
    const listSection = document.getElementById('shareListSection');
    if (createSection) createSection.style.display = 'block';
    if (listSection) listSection.style.display = 'none';
};

showListShareSection = function() {
    const createSection = document.getElementById('shareCreateSection');
    const listSection = document.getElementById('shareListSection');
    if (createSection) createSection.style.display = 'none';
    if (listSection) listSection.style.display = 'block';
};

createShareLink = function() {
    if (!currentShareFilePath) return;
    
    let displayPath;
    try {
        displayPath = decodeURIComponent(currentShareFilePath);
    } catch (e) {
        displayPath = currentShareFilePath;
    }
    
    const expireValue = parseInt(document.getElementById('shareExpireValue').value);
    const expireUnit = document.getElementById('shareExpireUnit').value;
    
    if (isNaN(expireValue) || expireValue < 1) {
        showToast('Please enter a valid expiration time', 'error');
        return;
    }
    
    // Convert to minutes
    let expireMinutes;
    if (expireUnit === 'days') {
        expireMinutes = expireValue * 24 * 60; // 1 day = 1440 minutes
    } else {
        expireMinutes = expireValue;
    }
    
    // Validate maximum expiration time (1 year = 525600 minutes)
    const maxExpMinutes = 525600;
    if (expireMinutes > maxExpMinutes) {
        showToast('Expiration time cannot exceed 1 year (525600 minutes)', 'error');
        return;
    }
    
    showToast(`Creating share link for "${displayPath}"...`, 'info');
    
    fetch('<URL_PREFIX>fileserver/gen-share-token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            path: currentShareFilePath,
            exp: expireMinutes
        })
    })
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        return response.json();
    })
    .then(data => {
        if (data.token) {
            // Auto-copy the share link to clipboard
            const shareLink = `${window.location.origin}<URL_PREFIX>share-download/${data.token}`;
            navigator.clipboard.writeText(shareLink).then(() => {
                showToast('Share link created and copied to clipboard', 'success');
            }).catch(() => {
                showToast('Share link created successfully (copy failed)', 'warning');
            });
            loadShareLinks(currentShareFilePath);
        }
    })
    .catch(error => {
        showToast(`Failed to create share link: ${error.message}`, 'error');
    });
};

loadShareLinks = function(fullFilePath) {
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }
    
    const createSection = document.getElementById('shareCreateSection');
    const listSection = document.getElementById('shareListSection');
    const container = document.getElementById('shareLinksContainer');
    
    if (!container) return;
    
    fetch(`<URL_PREFIX>fileserver/gen-share-token?path=${fullFilePath}`)
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        return response.json();
    })
    .then(data => {
        container.innerHTML = '';
        
        if (data.links && data.links.length > 0) {
            // Show all existing links
            data.links.forEach(link => {
                const expireDate = new Date(link.expires_at * 1000);
                const expireStr = expireDate.toLocaleString();
                
                const linkElement = document.createElement('div');
                linkElement.style.cssText = 'display: flex; align-items: center; gap: 8px; padding: 10px; border-bottom: 1px solid #eee;';
                linkElement.innerHTML = `
                    <div style="flex:1; min-width: 0;">
                        <div style="word-break: break-all; font-size: 12px; color: #666;">
                            ${urlPrefix}share-download/${link.token}
                        </div>
                        <div style="font-size: 11px; color: #999; margin-top: 4px;">
                            Expires: ${expireStr}
                        </div>
                    </div>
                    <button class="share-copyBtn" data-token="${link.token}" style="padding: 5px 10px; font-size: 12px; cursor: pointer; background: #4CAF50; color: white; border: none; border-radius: 4px;">Copy</button>
                    <button class="share-deleteBtn" data-token="${link.token}" style="padding: 5px 10px; font-size: 12px; cursor: pointer; background: #f44336; color: white; border: none; border-radius: 4px;">Delete</button>
                `;
                
                container.appendChild(linkElement);
                
                // Add copy button event listener
                const copyBtn = linkElement.querySelector('.share-copyBtn');
                copyBtn.addEventListener('click', () => {
                    const shareLink = `${window.location.origin}<URL_PREFIX>share-download/${link.token}`;
                    navigator.clipboard.writeText(shareLink).then(() => {
                        showToast('Link copied to clipboard', 'success');
                    }).catch(() => {
                        showToast('Failed to copy link', 'error');
                    });
                });
                
                // Add delete button event listener
                const deleteBtn = linkElement.querySelector('.share-deleteBtn');
                deleteBtn.addEventListener('click', () => {
                    deleteShareLink(fullFilePath, link.token);
                });
            });
            
            // Show list section and hide create section
            listSection.style.display = 'block';
            createSection.style.display = 'none';
        } else {
            // Show create section and hide list section
            createSection.style.display = 'block';
            listSection.style.display = 'none';
        }
    })
    .catch(error => {
        container.innerHTML = `<div style="padding: 10px; color: #f44336;">Failed to load share links: ${error.message}</div>`;
        listSection.style.display = 'block';
        createSection.style.display = 'none';
    });
};

deleteShareLink = function(fullFilePath, token) {
    if (!confirm('Are you sure you want to delete this share link?')) {
        return;
    }
    
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }
    
    showToast('Deleting share link...', 'info');
    
    fetch('<URL_PREFIX>fileserver/gen-share-token', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: token })
    })
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        return response.json();
    })
    .then(data => {
        if (data.message) {
            showToast(data.message, 'success');
            loadShareLinks(fullFilePath);
        }
    })
    .catch(error => {
        showToast(`Failed to delete share link: ${error.message}`, 'error');
    });
};
