import { test, expect, Page } from '@playwright/test';

/**
 * The in-page uploader on the file-browser page (the toolbar Upload button and
 * its progress banner), driven by js/app.js.
 *
 * Two defects are covered here:
 *  1. The pre-flight session check had no timeout, so a stalled check meant the
 *     upload never started and the UI gave no feedback at all.
 *  2. A rejected filename surfaced only as "Upload failed: HTTP 400", because
 *     the backend sends a 400 with an empty body.
 *
 * NOTE: the page must be loaded from a directory that actually exists. A
 * request for a nonexistent path returns 404 with Content-Type
 * application/octet-stream, which Chromium treats as a download and page.goto
 * rejects with "Download is starting".
 */

const DIR = '/download/documents';
const UPLOADED = 'e2e-inline-upload.txt';
const USERINFO = '**/fileserver/userinfo';
const UPLOAD_RE = /\/download\/documents\//;

async function pickFile(page: Page, name: string) {
  const [chooser] = await Promise.all([
    page.waitForEvent('filechooser'),
    page.locator('#upload-btn').click(),
  ]);
  await chooser.setFiles({ name, mimeType: 'text/plain', buffer: Buffer.from('inline hello') });
}

async function stubUserinfo(page: Page, valid = true) {
  await page.route(USERINFO, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        username: valid ? 'e2e' : 'Guest',
        userid: valid ? 'u1' : '',
        email: '',
        isAdmin: false,
        writeable: valid,
        isGuest: !valid,
        authRequired: true,
      }),
    }),
  );
}

test.describe('In-page uploader — session probe and error reporting', () => {
  test.afterEach(async ({ page }) => {
    // Best-effort cleanup; the upload may never have happened.
    await page.goto('/download/').catch(() => {});
    await page
      .evaluate(
        async ({ dir, file }) => {
          await fetch(`${dir}/${file}`, { method: 'DELETE' });
        },
        { dir: DIR, file: UPLOADED },
      )
      .catch(() => {});
  });

  test('a stalled session check no longer blocks the upload', async ({ page, browserName }) => {
    // xhr.timeout does not fire in WebKit while Playwright is holding the
    // intercepted request open (verified: with a 500ms timeout and a 12s delayed
    // response the page waits the full 12s in WebKit, but proceeds at ~500ms in
    // Chromium). That is a harness/engine interaction, not a product behaviour,
    // and there is no way to hang the request here without interception -- so
    // the hang path is asserted only where it can actually be observed.
    test.skip(browserName === 'webkit', 'xhr.timeout does not fire under route interception in WebKit');

    // The probe would eventually time out at this value rather than hanging.
    await page.addInitScript(() => {
      window.UPLOAD_PROBE_TIMEOUT_MS = 500;
    });

    // The session check never responds at all.
    await page.route(USERINFO, async () => {
      await new Promise(() => {});
    });

    const postUrls: string[] = [];
    await page.route(UPLOAD_RE, (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      postUrls.push(route.request().url());
      return route.fulfill({ status: 200, body: 'upload successfully!' });
    });

    await page.goto(`${DIR}/`);
    await pickFile(page, UPLOADED);

    // Before the timeout existed, the probe never settled so doUploadFile was
    // never reached: no banner, no request, no error. The test would time out.
    await expect(page.locator('#uploadBanner')).toBeVisible({ timeout: 15000 });
    await expect.poll(() => postUrls.length).toBe(1);
    expect(postUrls[0]).toBe(`http://localhost:8080${DIR}/`);
  });

  test('a rejected filename is explained rather than reported as a bare 400', async ({ page }) => {
    await stubUserinfo(page);

    await page.route(UPLOAD_RE, (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      // Mirrors the backend: 400 with an empty body for a filename the
      // sanitizer cannot accept.
      return route.fulfill({ status: 400, body: '' });
    });

    await page.goto(`${DIR}/`);
    await pickFile(page, UPLOADED);

    const toast = page.locator('.toast.error');
    await expect(toast).toContainText('filename', { timeout: 10000 });

    // Read the text while the toast is still on screen (it self-dismisses).
    const text = await toast.innerText();
    expect(text).not.toContain('HTTP 400');
  });

  test('the happy path still uploads, reloads and lists the file', async ({ page }) => {
    // No stubbing: this runs against the real server end to end.
    await page.goto(`${DIR}/`);
    await pickFile(page, UPLOADED);

    await page.waitForLoadState('domcontentloaded');
    await expect(page.locator('.file-name', { hasText: UPLOADED })).toBeVisible({ timeout: 15000 });

    const resp = await page.request.get(`${DIR}/${UPLOADED}`);
    expect(resp.status()).toBe(200);
    expect(await resp.text()).toBe('inline hello');
  });
});
