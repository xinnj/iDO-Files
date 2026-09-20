/**
 * Shared session probe.
 *
 * Both the dedicated upload page and the in-page uploader need to know whether
 * the current session is still usable before spending time on an upload that
 * will be rejected. Keeping the predicate in one place stops the two callers
 * from drifting apart.
 *
 * Deliberately contains no URL_PREFIX placeholder token: the URL to probe is
 * passed in by the caller. Start.sh only sed-replaces an explicit list of files
 * which does not include this one, whereas seed-data.sh rewrites every html/js
 * file it copies -- so a placeholder here would behave differently in tests
 * than in production.
 */

var SESSION_EXPIRED_MSG = 'Session expired. Please refresh the page and log in again.';

// Overridable so tests can use a short timeout. See window.UPLOAD_PROBE_TIMEOUT_MS.
var PROBE_TIMEOUT_MS = window.UPLOAD_PROBE_TIMEOUT_MS || 10000;

/**
 * Probe the session by fetching the userinfo endpoint.
 *
 * Calls cb(true) when the session is usable, and cb(false) only when the server
 * positively reports an expired session. Every other outcome -- no URL, an
 * unparseable body, a network error, or a timeout -- fails OPEN with cb(true),
 * so a flaky probe never blocks an upload that would have worked. The backend
 * rejects the request anyway if the session really is gone.
 *
 * The timeout matters: without it a stalled probe leaves the caller waiting
 * forever, which on the file-browser page means the upload never even starts.
 */
function probeSession(userinfoUrl, cb) {
    if (!userinfoUrl) {
        cb(true);
        return;
    }

    var xhr = new XMLHttpRequest();
    var done = false;

    // A request can only settle once, however many of these fire.
    function finish(valid) {
        if (done) return;
        done = true;
        cb(valid);
    }

    xhr.open('GET', userinfoUrl, true);
    xhr.timeout = PROBE_TIMEOUT_MS;

    xhr.addEventListener('load', function () {
        var valid = true;
        try {
            if (xhr.status === 200) {
                var info = JSON.parse(xhr.responseText);
                if (info.isGuest && info.authRequired) {
                    valid = false;
                }
            }
        } catch (e) {
            // Unparseable response: proceed, the backend will reject if needed.
        }
        finish(valid);
    });

    xhr.addEventListener('error', function () { finish(true); });
    xhr.addEventListener('timeout', function () { finish(true); });

    xhr.send();
}
