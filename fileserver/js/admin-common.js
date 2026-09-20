/* Shared helpers for the admin pages.
 *
 * Deliberately free of any <URL_PREFIX> placeholder: callers pass in a base URL
 * built from window.__URL_PREFIX__, which lives in the HTML. Start.sh only
 * substitutes the placeholder in an explicit file list, while the E2E seed
 * script substitutes it in every .html and .js — so a placeholder here would
 * pass the whole test suite and then break in production.
 */

function escapeHtml(value) {
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(value === null || value === undefined ? '' : String(value)));
    return div.innerHTML;
}

// For values interpolated into an attribute, including inside inline handlers.
function escapeAttr(value) {
    return escapeHtml(value).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// UTF-8 safe base64, for use in element ids built from paths and role names.
function safeBtoa(value) {
    return btoa(encodeURIComponent(value).replace(/%([0-9A-F]{2})/g, function (match, hex) {
        return String.fromCharCode(parseInt(hex, 16));
    })).replace(/[^A-Za-z0-9]/g, '');
}

/**
 * Fetch JSON from an admin endpoint.
 *
 * Rejects with an Error carrying a `.status` property, so callers can branch on
 * a specific code (409 for a version conflict) while still showing the server's
 * own message for everything else.
 */
function apiFetch(url, options) {
    options = options || {};
    options.redirect = 'manual';
    options.headers = Object.assign({ 'Accept': 'application/json' }, options.headers || {});

    return fetch(url, options).then(function (response) {
        if (response.type === 'opaqueredirect') {
            var expired = new Error('Your session expired. Reload the page and sign in again.');
            expired.status = 401;
            throw expired;
        }

        if (response.status === 403) {
            var denied = new Error('Permission denied: you are not authorized to manage access control.');
            denied.status = 403;
            throw denied;
        }

        if (!response.ok) {
            return response.text().then(function (text) {
                var message = null;
                try {
                    message = JSON.parse(text).error;
                } catch (ignored) {
                    // Fall through to the generic message.
                }
                var failure = new Error(message || ('Request failed: server returned ' + response.status));
                failure.status = response.status;
                throw failure;
            });
        }

        return response.json();
    });
}

// Swap a button's contents for a spinner while work is in flight.
function setBusy(button, busyHtml) {
    if (!button) {
        return;
    }
    if (!button.dataset.idleHtml) {
        button.dataset.idleHtml = button.innerHTML;
    }
    button.disabled = true;
    button.innerHTML = busyHtml || '<span class="spinner-border spinner-border-sm"></span>';
}

function clearBusy(button) {
    if (!button || !button.dataset.idleHtml) {
        return;
    }
    button.innerHTML = button.dataset.idleHtml;
    button.disabled = false;
    delete button.dataset.idleHtml;
}
