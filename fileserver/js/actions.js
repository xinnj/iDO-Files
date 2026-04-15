export function modifyContent(pathname) {
    fetch(`<URL_PREFIX>fileserver/userinfo?path=${encodeURIComponent(pathname)}`)
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
            return response.json();
        })
        .then(data => {
            window.userInfo = data;
            setUserMenu();
            addActionsCol();
        })
        .catch(error => {
            console.error('Error fetching user info:', error);
            window.userInfo = {username: '', isAdmin: false, writeable: false};
            setUserMenu();
        });
}

let userMenuInitialized = false;
let deleteModalCreated = false;
let moveModalCreated = false;
let shareModalCreated = false;

function setUserMenu() {
    const userMenu = document.querySelector('.user-menu');
    if (userMenu) {
        const toggle = document.querySelector('.user-menu-toggle');
        const dropdown = document.querySelector('.user-dropdown');

        if (!userMenuInitialized) {
            if (toggle) {
                toggle.addEventListener('click', function (e) {
                    e.stopPropagation();
                    userMenu.classList.toggle('active');
                });
            }

            if (dropdown) {
                dropdown.addEventListener('click', function (e) {
                    e.stopPropagation();
                });
            }

            document.addEventListener('click', function () {
                userMenu.classList.remove('active');
            });

            userMenuInitialized = true;
        }

        if (window.userInfo.username) {
            const userName = document.querySelector('.user-name');
            if (userName) {
                userName.textContent = window.userInfo.username;
            }

            const accessControlLink = document.getElementById('access-control-link');
            if (!window.userInfo.isAdmin && accessControlLink) {
                accessControlLink.remove();
            }

            const shareLinksLink = document.getElementById('share-links-link');
            if (!window.userInfo.isAdmin && shareLinksLink) {
                shareLinksLink.remove();
            }

            const uploadLink = document.getElementById('upload-link');
            if (!window.userInfo.writeable && uploadLink) {
                uploadLink.remove();
            }

            userMenu.style.display = 'block';
        } else {
            userMenu.style.display = 'none';
        }
    }
}

function addActionsCol() {
    if (!window.userInfo.writeable) {
        return;
    }

    const table = document.getElementById('list');
    if (table) {
        // Only create modals if they don't exist
        if (!deleteModalCreated) {
            createDeleteModal();
            deleteModalCreated = true;
        }
        if (!moveModalCreated) {
            createMoveModal();
            moveModalCreated = true;
        }
        if (!shareModalCreated) {
            createShareModal();
            shareModalCreated = true;
        }

        // Add table header
        const headerRow = table.querySelector('thead tr');
        if (headerRow) {
            const actionsHeader = document.createElement('th');
            actionsHeader.classList.add('col-actions');
            actionsHeader.textContent = 'Actions';
            headerRow.appendChild(actionsHeader);
        }

        // Add action cell to each row
        const bodyRows = table.querySelectorAll('tbody tr');
        bodyRows.forEach(row => {
            const fullFilePath = new URL(row.querySelector('.link a').getAttribute('href'), document.baseURI).pathname;

            const actionsCell = document.createElement('td');
            actionsCell.classList.add('col-actions');
            actionsCell.classList.add('actions-container');

            const moveIcon = document.createElement('img');
            moveIcon.src = '<URL_PREFIX>fileserver/images/move.png';
            moveIcon.alt = 'Move';
            moveIcon.classList.add('action-icon', 'move-icon');
            moveIcon.title = 'Move';
            moveIcon.addEventListener('click', (e) => {
                e.preventDefault();
                showMoveModal(fullFilePath);
            });
            actionsCell.appendChild(moveIcon);

            const deleteIcon = document.createElement('img');
            deleteIcon.src = '<URL_PREFIX>fileserver/images/delete.png';
            deleteIcon.alt = 'Delete';
            deleteIcon.classList.add('action-icon', 'delete-icon');
            deleteIcon.title = 'Delete';
            deleteIcon.addEventListener('click', (e) => {
                e.preventDefault();
                showDeleteModal(fullFilePath);
            });
            actionsCell.appendChild(deleteIcon);

            const fileSize = row.querySelector('.size').textContent;
            if (fileSize && fileSize !== '-') {
                const shareIcon = document.createElement('img');
                shareIcon.src = '<URL_PREFIX>fileserver/images/share.png';
                shareIcon.alt = 'Share';
                shareIcon.classList.add('action-icon', 'share-icon');
                shareIcon.title = 'Share';
                shareIcon.addEventListener('click', (e) => {
                    e.preventDefault();
                    showShareModal(fullFilePath);
                });
                actionsCell.appendChild(shareIcon);
            }

            row.appendChild(actionsCell);
        });
    }
}

function createDeleteModal() {
    const modalHTML = `
        <div id="deleteModal" class="action-modal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 1000;">
            <div style="position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); background: white; padding: 20px; border-radius: 8px; min-width: 300px; max-width: 80vw;">
                <h3>Confirm Delete</h3>
                <p id="deleteModalMessage" style="word-break: break-all; max-height: 200px; overflow-y: auto; margin: 15px 0;">Are you sure you want to delete this file?</p>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button id="deleteCancelBtn" class="action-cancelBtn">Cancel</button>
                    <button id="deleteConfirmBtn" class="action-confirmBtn">Delete</button>
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHTML);

    // Add modal event listeners
    const modal = document.getElementById('deleteModal');
    const cancelBtn = document.getElementById('deleteCancelBtn');

    cancelBtn.addEventListener('click', () => {
        modal.style.display = 'none';
    });

    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.style.display = 'none';
        }
    });
}

function showDeleteModal(fullFilePath) {
    const modal = document.getElementById('deleteModal');
    const message = document.getElementById('deleteModalMessage');
    const confirmBtn = document.getElementById('deleteConfirmBtn');

    try {
        message.textContent = decodeURIComponent(fullFilePath);
    } catch (e) {
        message.textContent = fullFilePath;
    }

    // Remove previous event listener and add new one
    const newConfirmBtn = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(newConfirmBtn, confirmBtn);

    newConfirmBtn.addEventListener('click', () => {
        modal.style.display = 'none';
        deleteFile(fullFilePath);
    });

    modal.style.display = 'block';
}

function deleteFile(fullFilePath) {
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }
    showInfo(`Deleting "${displayPath}"...`);

    // Example using fetch API - replace with your actual endpoint
    fetch(fullFilePath, {method: 'DELETE'})
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }

            let displayPath;
            try {
                displayPath = decodeURIComponent(fullFilePath);
            } catch (e) {
                displayPath = fullFilePath;
            }

            showSuccess(`"${displayPath}" deleted successfully`);
            // Reload page after a short delay to show the success message
            setTimeout(() => {
                window.location.reload();
            }, 1500);
        })
        .catch(error => {
            let displayPath;
            try {
                displayPath = decodeURIComponent(fullFilePath);
            } catch (e) {
                displayPath = fullFilePath;
            }
            showError(`"${displayPath}" deleted unsuccessfully: ${error.message}`);
        });
}

function createMoveModal() {
    const modalHTML = `
        <div id="moveModal" class="action-modal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 1000;">
            <div style="position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); background: white; padding: 20px; border-radius: 8px; min-width: 300px; max-width: 80vw;">
                <h3>Move File</h3>
                <label style="display: block; margin-bottom: 8px; font-weight: bold;">Source:</label>
                <p id="sourceFile" style="word-break: break-all; max-height: 150px; overflow-y: auto; margin: 10px 0;">Source file:</p>
                
                <div style="margin: 15px 0;">
                    <label style="display: block; margin-bottom: 8px; font-weight: bold;">Destination:</label>
                    <div style="display: flex; flex-direction: column; gap: 8px;">
                        <label style="display: flex; align-items: center; gap: 8px;">
                            <input type="radio" name="moveDestination" value="download" id="moveDestDownload" checked>
                            Download
                        </label>
                        <label style="display: flex; align-items: center; gap: 8px;">
                            <input type="radio" name="moveDestination" value="archive" id="moveDestArchive">
                            Archive
                        </label>
                        <label style="display: flex; align-items: center; gap: 8px;">
                            <input type="radio" name="moveDestination" value="public" id="moveDestPublic">
                            Public
                        </label>
                    </div>
                </div>
                
                <div style="margin: 15px 0;">
                    <label style="display: flex; align-items: center; gap: 8px;">
                        <input type="checkbox" id="moveCopyOption">
                        Copy instead of Move
                    </label>
                </div>
                
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button id="moveCancelBtn" class="action-cancelBtn">Cancel</button>
                    <button id="moveConfirmBtn" class="action-confirmBtn">Confirm</button>
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHTML);

    // Add modal event listeners
    const modal = document.getElementById('moveModal');
    const cancelBtn = document.getElementById('moveCancelBtn');

    cancelBtn.addEventListener('click', () => {
        modal.style.display = 'none';
    });

    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.style.display = 'none';
        }
    });
}

function showMoveModal(fullFilePath) {
    const modal = document.getElementById('moveModal');
    const sourceFile = document.getElementById('sourceFile');
    const copyCheckbox = document.getElementById('moveCopyOption');

    try {
        sourceFile.textContent = decodeURIComponent(fullFilePath);
    } catch (e) {
        sourceFile.textContent = fullFilePath;
    }

    const radios = document.querySelectorAll('input[name="moveDestination"]');
    const prefix = '<URL_PREFIX>';
    const source = fullFilePath
        .substring(prefix.length)
        .split('/')
        .filter(part => part.length > 0)[0] || '';

    // Remove the radio button that matches the current source
    radios.forEach(radio => {
        if (radio.value === source) {
            const label = radio.closest('label');
            if (label) {
                label.style.display = 'none';
            }
        }
    });

    // Reset form state
    radios[0].checked = true;
    copyCheckbox.checked = false;

    // Set up event listener (remove existing first to avoid duplicates)
    const confirmBtn = document.getElementById('moveConfirmBtn');
    const newConfirmHandler = () => {
        const destination = document.querySelector('input[name="moveDestination"]:checked').value;
        const isCopy = copyCheckbox.checked;

        modal.style.display = 'none';
        moveFile(fullFilePath, destination, isCopy);

        // Remove this event listener after execution
        confirmBtn.removeEventListener('click', newConfirmHandler);
    };

    // Remove any existing listeners and add new one
    const newConfirmBtn = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(newConfirmBtn, confirmBtn);
    newConfirmBtn.addEventListener('click', newConfirmHandler);

    modal.style.display = 'block';
}

function moveFile(fullFilePath, destination, isCopy = false) {
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }

    const action = isCopy ? 'Copying' : 'Moving';
    showInfo(`${action} "${displayPath}" to ${destination}...`);

    const source = fullFilePath
        .substring('<URL_PREFIX>'.length)
        .split('/')
        .filter(part => part.length > 0)[0] || '';

    const dest = `<URL_PREFIX>${destination}` + fullFilePath.substring(`<URL_PREFIX>${source}`.length)

    const requestParams = new URLSearchParams({
        dest: dest,
        action: isCopy ? 'copy' : 'move'
    });

    // Example using fetch API - replace with your actual endpoint
    fetch(fullFilePath, {
        method: 'PUT',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: requestParams.toString()
    })
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }

            const successMessage = isCopy
                ? `"${displayPath}" copied to ${destination} successfully`
                : `"${displayPath}" moved to ${destination} successfully`;

            showSuccess(successMessage);

            // Reload page after a short delay to show the success message
            setTimeout(() => {
                window.location.reload();
            }, 1500);
        })
        .catch(error => {
            const errorMessage = isCopy
                ? `"${displayPath}" copied to ${destination} unsuccessfully: ${error.message}`
                : `"${displayPath}" moved to ${destination} unsuccessfully: ${error.message}`;
            showError(errorMessage);
        });
}

function createShareModal() {
    const modalHTML = `
        <div id="shareModal" class="action-modal" style="display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 1000;">
            <div style="position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); background: white; padding: 20px; border-radius: 8px; min-width: 400px; max-width: 90vw;">
                <h3>Share File</h3>
                <p id="shareFileName" style="word-break: break-all; margin-bottom: 15px; font-weight: bold;">File name</p>

                <div id="shareCreateSection">
                    <div style="margin-bottom: 15px;">
                        <label style="display: block; margin-bottom: 8px; font-weight: bold;">Expiration (max 1 year):</label>
                        <div style="display: flex; align-items: center; gap: 10px;">
                            <input type="number" id="shareExpireValue" value="1" min="1" style="flex: 1; padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
                            <select id="shareExpireUnit" style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
                                <option value="minutes">Minutes</option>
                                <option value="days" selected>Days</option>
                            </select>
                        </div>
                    </div>
                    <div style="display: flex; gap: 10px; justify-content: flex-end;">
                        <button id="shareCancelBtn" class="action-cancelBtn">Cancel</button>
                        <button id="shareCreateBtn" class="action-confirmBtn">Create Link</button>
                    </div>
                </div>

                <div id="shareListSection" style="display: none;">
                    <h4 style="margin: 0 0 10px 0;">Active Share Links</h4>
                    <div id="shareLinksContainer" style="max-height: 200px; overflow-y: auto; border: 1px solid #ddd; border-radius: 4px; padding: 10px;"></div>
                    <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 15px;">
                        <button id="shareCloseBtn" class="action-cancelBtn">Close</button>
                        <button id="shareCreateNewBtn" class="action-confirmBtn">Create New Link</button>
                    </div>
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHTML);

    // Add modal event listeners
    const modal = document.getElementById('shareModal');
    const cancelBtn = document.getElementById('shareCancelBtn');
    const closeBtn = document.getElementById('shareCloseBtn');

    cancelBtn.addEventListener('click', () => {
        modal.style.display = 'none';
    });

    closeBtn.addEventListener('click', () => {
        modal.style.display = 'none';
    });
}

function showShareModal(fullFilePath) {
    const modal = document.getElementById('shareModal');
    const fileName = document.getElementById('shareFileName');
    const linksContainer = document.getElementById('shareLinksContainer');

    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }

    fileName.textContent = displayPath;
    linksContainer.innerHTML = '';

    // Set up create button
    const createBtn = document.getElementById('shareCreateBtn');
    const newCreateBtn = createBtn.cloneNode(true);
    createBtn.parentNode.replaceChild(newCreateBtn, createBtn);

    newCreateBtn.addEventListener('click', () => {
        createShareLink(fullFilePath);
    });

    // Set up create new link button
    const createNewBtn = document.getElementById('shareCreateNewBtn');
    const newCreateNewBtn = createNewBtn.cloneNode(true);
    createNewBtn.parentNode.replaceChild(newCreateNewBtn, createNewBtn);

    newCreateNewBtn.addEventListener('click', () => {
        document.getElementById('shareCreateSection').style.display = 'block';
        document.getElementById('shareListSection').style.display = 'none';
    });

    modal.style.display = 'block';

    // Load existing share links (this will show/hide sections based on results)
    loadShareLinks(fullFilePath);
}

function createShareLink(fullFilePath) {
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }

    const expireValue = parseInt(document.getElementById('shareExpireValue').value);
    const expireUnit = document.getElementById('shareExpireUnit').value;

    if (isNaN(expireValue) || expireValue < 1) {
        showError('Please enter a valid expiration time');
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
        showError('Expiration time cannot exceed 1 year (525600 minutes)');
        return;
    }

    showInfo(`Creating share link for "${displayPath}"...`);

    const requestBody = JSON.stringify({
        path: fullFilePath,
        exp: expireMinutes
    });

    fetch('<URL_PREFIX>fileserver/gen-share-token', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: requestBody
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
                    showSuccess('Share link created and copied to clipboard');
                }).catch(() => {
                    showSuccess('Share link created successfully (copy failed)');
                });
                loadShareLinks(fullFilePath);
            }
        })
        .catch(error => {
            showError(`Failed to create share link: ${error.message}`);
        });
}

function loadShareLinks(fullFilePath) {
    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }

    const createSection = document.getElementById('shareCreateSection');
    const listSection = document.getElementById('shareListSection');
    const container = document.getElementById('shareLinksContainer');

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
                                <URL_PREFIX>share-download/${link.token}
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
                            showSuccess('Link copied to clipboard');
                        }).catch(() => {
                            showError('Failed to copy link');
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
}

function deleteShareLink(fullFilePath, token) {
    if (!confirm('Are you sure you want to delete this share link?')) {
        return;
    }

    let displayPath;
    try {
        displayPath = decodeURIComponent(fullFilePath);
    } catch (e) {
        displayPath = fullFilePath;
    }

    showInfo('Deleting share link...');

    fetch('<URL_PREFIX>fileserver/gen-share-token', {
        method: 'DELETE',
        headers: {
            'Content-Type': 'application/json'
        },
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
                showSuccess(data.message);
                loadShareLinks(fullFilePath);
            }
        })
        .catch(error => {
            showError(`Failed to delete share link: ${error.message}`);
        });
}
