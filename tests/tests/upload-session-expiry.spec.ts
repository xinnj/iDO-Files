import { test, expect, Page } from '@playwright/test';
import { UploadPage } from '../pages/UploadPage';

/**
 * Session expiry on the dedicated upload page (fileserver/upload.html).
 *
 * The E2E environment runs with AUTH_REQUIRED=false and a stub oidc module that
 * always sets a non-empty X-USER, so a real 401 is unreachable. The session
 * state is therefore synthesized with page.route, which also means these tests
 * exercise client behaviour only -- the requests never reach OpenResty.
 */

const TMP = '/download/e2e-session-tmp';
const USERINFO_NAME = 'fileserver/userinfo';
const UPLOAD_RE = /\/download\/e2e-session-tmp\//;

/** Mutable session state the stubs read from. */
type SessionState = { valid: boolean };

/**
 * Stub GET /fileserver/userinfo.
 *
 * `authRequired` MUST be true: the page's predicate is
 * `!(isGuest && authRequired)`, so with authRequired:false it evaluates to
 * "valid" forever and every expiry test would silently become a happy-path test.
 */
async function stubUserinfo(page: Page, state: SessionState, seenUrls?: string[]) {
  await page.route(`**/${USERINFO_NAME}`, (route) => {
    seenUrls?.push(route.request().url());
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        username: state.valid ? 'e2e' : 'Guest',
        userid: state.valid ? 'u1' : '',
        email: state.valid ? 'e2e@localhost' : '',
        isAdmin: false,
        writeable: state.valid,
        isGuest: !state.valid,
        authRequired: true,
      }),
    });
  });
}

function file(name: string, content = 'x') {
  return { name, mimeType: 'text/plain', buffer: Buffer.from(content) };
}

test.describe('Upload page — session expiry', () => {
  test('pre-flight check blocks the batch before any upload starts', async ({ page }) => {
    const state: SessionState = { valid: false };
    const probeUrls: string[] = [];
    const postUrls: string[] = [];

    await stubUserinfo(page, state, probeUrls);
    await page.route(UPLOAD_RE, (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postUrls.push(route.request().url());
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('a.txt'), file('b.txt')]);
    await up.startUpload();

    // The user is told, once, and given a way to act on it.
    await expect(up.getSessionAlert()).toBeVisible();
    await expect(page.locator('#sessionAlertMessage')).toContainText('Session expired');
    await expect(up.getLoginLink()).toBeVisible();
    await expect(up.getLoginLink()).toHaveAttribute('target', '_blank');
    await expect(up.getLoginLink()).toHaveAttribute('href', 'http://localhost:8080/fileserver/login');

    // The queue is kept and offers a retry.
    await expect(up.getUploadButton()).toBeEnabled();
    await expect(up.getUploadButton()).toHaveText(/Retry remaining \(2\)/);

    // Nothing was uploaded, and the probe went to the right URL with no params.
    expect(postUrls).toEqual([]);
    expect(probeUrls).toEqual(['http://localhost:8080/fileserver/userinfo']);

    // No toast spam: the persistent alert carries the message.
    await expect(page.locator('.toast')).toHaveCount(0);
  });

  test('mid-batch 401 aborts the batch with one message and no toast spam', async ({ page }) => {
    const state: SessionState = { valid: true };
    let postCount = 0;
    const postUrls: string[] = [];

    await stubUserinfo(page, state);
    await page.route(UPLOAD_RE, async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postCount += 1;
      postUrls.push(route.request().url());
      if (postCount <= 1) {
        return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
      }
      // From here on the session looks dead, both to the POSTs and to the probe.
      state.valid = false;
      // Let every other in-flight POST be intercepted before the first 401 is
      // delivered. Otherwise the page's abort can beat the route handler and
      // make the recorded POST count nondeterministic.
      await new Promise((r) => setTimeout(r, 100));
      return route.fulfill({
        status: 401,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Session expired. Please refresh the page and log in again.' }),
      });
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('a.txt'), file('b.txt'), file('c.txt')]);
    await up.startUpload();

    // Let every straggler response land before asserting nothing was toasted.
    await page.waitForTimeout(1500);

    // Exactly one message, and no toasts at all (before this change: one error
    // toast per file, plus a summary toast).
    await expect(up.getSessionAlert()).toBeVisible();
    await expect(page.locator('#sessionAlertMessage')).toContainText('Session expired');
    await expect(page.locator('.toast')).toHaveCount(0);
    await expect(page.locator('body')).not.toContainText('Upload complete');

    // The 401'd files are rolled back to pending, NOT counted as failures --
    // otherwise the retry would skip them and the counts would lie.
    const stats = await up.getStats();
    expect(stats.success).toBe('1');
    expect(stats.errors).toBe('0');
    await expect(up.getFileItemsByStatus('success')).toHaveCount(1);
    await expect(up.getFileItemsByStatus('pending')).toHaveCount(2);
    await expect(up.getFileItemsByStatus('error')).toHaveCount(0);

    // The button offers to finish the job.
    await expect(up.getUploadButton()).toBeEnabled();
    await expect(up.getUploadButton()).toHaveText(/Retry remaining \(2\)/);

    // Every POST went to the right place; the batch was not extended.
    expect(postUrls).toHaveLength(3);
    for (const url of postUrls) {
      expect(url).toBe('http://localhost:8080/download/e2e-session-tmp/');
    }
  });

  test('a rejection from the server is reported per file without stopping the batch', async ({ page }) => {
    const state: SessionState = { valid: true };
    const postUrls: string[] = [];

    await stubUserinfo(page, state);
    await page.route(UPLOAD_RE, (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postUrls.push(route.request().url());
      // A plain failure (not 401) must NOT be treated as a dead session: the
      // batch keeps going and the file is marked failed, not made retryable.
      return route.fulfill({ status: 500, body: 'boom' });
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('a.txt'), file('b.txt')]);
    await up.startUpload();

    await expect(up.getFileItemsByStatus('error')).toHaveCount(2);
    expect((await up.getStats()).errors).toBe('2');

    // No session alert, and no offer to retry something that will just fail again.
    await expect(up.getSessionAlert()).toBeHidden();
    await expect(up.getUploadButton()).toHaveText(/Start Upload/);
    await expect(up.getUploadButton()).toBeDisabled();
  });

  test('posts to the right URL as multipart, then reflects the response in the DOM', async ({ page }) => {
    const state: SessionState = { valid: true };
    let captured: { url: string; contentType: string; body: string } | null = null;

    await stubUserinfo(page, state);
    await page.route(UPLOAD_RE, (route) => {
      const req = route.request();
      if (req.method() !== 'POST') return route.continue();
      captured = {
        url: req.url(),
        contentType: req.headers()['content-type'] ?? '',
        body: req.postData() ?? '',
      };
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('e2e-session.txt', 'hello')]);
    await up.startUpload();

    // The DOM reflects the successful response.
    await expect(up.getFileItemsByStatus('success')).toHaveCount(1);
    expect((await up.getStats()).success).toBe('1');

    // And the request itself was well formed.
    expect(captured).not.toBeNull();
    expect(captured!.url).toBe('http://localhost:8080/download/e2e-session-tmp/');
    expect(captured!.contentType).toMatch(/^multipart\/form-data; boundary=/);
    expect(captured!.body).toContain('name="file"');
    expect(captured!.body).toContain('filename="e2e-session.txt"');
  });

  test('uploads relative to a nested destination directory', async ({ page }) => {
    const state: SessionState = { valid: true };
    const postUrls: string[] = [];

    await stubUserinfo(page, state);
    await page.route(UPLOAD_RE, (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postUrls.push(route.request().url());
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/nested/subdir/`);
    await up.selectFiles([file('deep.txt')]);
    await up.startUpload();

    await expect(up.getFileItemsByStatus('success')).toHaveCount(1);
    expect(postUrls).toEqual(['http://localhost:8080/download/e2e-session-tmp/nested/subdir/']);
  });

  // Note: the window.UPLOAD_HEARTBEAT_MS override used by the next two tests is
  // itself proven here -- if it did not take effect, the 30s production default
  // would make both tests time out rather than pass.

  test('the heartbeat stops the batch before the next upload can fail', async ({ page }) => {
    // A short interval so the test does not wait 30s.
    await page.addInitScript(() => {
      window.UPLOAD_HEARTBEAT_MS = 400;
    });

    const state: SessionState = { valid: true };
    const postUrls: string[] = [];

    await stubUserinfo(page, state);
    await page.route(UPLOAD_RE, async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postUrls.push(route.request().url());
      // Stall forever. These POSTs never respond, so nothing but the heartbeat
      // can possibly detect that the session died -- if the heartbeat did not
      // work, this test would simply time out.
      await new Promise(() => {});
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('a.txt'), file('b.txt')]);
    await up.startUpload();

    await expect(page.locator('#uploadButton')).toHaveText(/Uploading/);
    // The button says "Uploading" as soon as the XHRs are sent, which is before
    // the route handler has run -- poll instead of asserting the array directly.
    await expect.poll(() => postUrls.length).toBe(2);

    // The session dies while both uploads are stalled in flight.
    state.valid = false;

    await expect(up.getSessionAlert()).toBeVisible({ timeout: 5000 });
    await expect(page.locator('#sessionAlertMessage')).toContainText('Session expired');
    await expect(up.getUploadButton()).toHaveText(/Retry remaining \(2\)/);

    // Rolled back to pending and ready to resume -- and nothing was toasted,
    // because no request ever failed.
    await expect(up.getFileItemsByStatus('pending')).toHaveCount(2);
    await expect(up.getFileItemsByStatus('error')).toHaveCount(0);
    await expect(page.locator('.toast')).toHaveCount(0);
  });

  test('retry resumes only the unfinished files and keeps the successes', async ({ page }) => {
    const state: SessionState = { valid: true };
    let postCount = 0;
    let successesAllowed = 1;

    await stubUserinfo(page, state);
    await page.route(UPLOAD_RE, (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postCount += 1;
      if (successesAllowed > 0) {
        successesAllowed -= 1;
        return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
      }
      state.valid = false;
      return route.fulfill({
        status: 401,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Session expired.' }),
      });
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('a.txt'), file('b.txt'), file('c.txt')]);
    await up.startUpload();

    await expect(up.getSessionAlert()).toBeVisible();
    await expect(up.getUploadButton()).toHaveText(/Retry remaining \(2\)/);

    // The user logs in from another tab and comes back -- a focus event is the
    // recovery signal, so no polling interval is needed.
    state.valid = true;
    successesAllowed = 99;
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));

    await expect(page.locator('#sessionAlertMessage')).toContainText('Session restored');
    await expect(up.getUploadButton()).toBeEnabled();

    const beforeRetry = postCount;
    await up.startUpload();

    // The whole batch ends up uploaded...
    await expect(up.getFileItemsByStatus('success')).toHaveCount(3);
    expect((await up.getStats()).success).toBe('3');

    // ...and only the two unfinished files were re-sent.
    expect(postCount - beforeRetry).toBe(2);
    await expect(up.getSessionAlert()).toBeHidden();
  });

  test('Clear All mid-batch leaves no orphan summary and stops the heartbeat', async ({ page }) => {
    await page.addInitScript(() => {
      window.UPLOAD_HEARTBEAT_MS = 400;
    });

    const state: SessionState = { valid: true };
    const probeUrls: string[] = [];

    await stubUserinfo(page, state, probeUrls);
    await page.route(UPLOAD_RE, async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      await new Promise(() => {}); // keep the upload in flight
    });

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([file('a.txt')]);
    await up.startUpload();
    await expect(page.locator('#uploadButton')).toHaveText(/Uploading/);

    await page.locator('button:has-text("Clear All")').click();

    await expect(page.locator('.file-item')).toHaveCount(0);
    await expect(up.getSessionAlert()).toBeHidden();
    await expect(up.getUploadButton()).toHaveText(/Start Upload/);
    await expect(up.getUploadButton()).toBeDisabled();

    // Clearing mid-batch must not leave an orphan summary behind. (The separate
    // `selectedFiles.length === 0` guard in checkUploadComplete is defensive and
    // is NOT covered here -- verified by mutation that removing it still passes.)
    await expect(page.locator('body')).not.toContainText('Upload complete');

    // The heartbeat was cleared too, so no further probes are issued.
    const probesAfterClear = probeUrls.length;
    await page.waitForTimeout(1200);
    expect(probeUrls.length).toBe(probesAfterClear);
  });
});
