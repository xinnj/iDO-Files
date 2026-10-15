import { test, expect, Page, APIRequestContext } from '@playwright/test';
import { UploadPage } from '../pages/UploadPage';
import { FileBrowserPage } from '../pages/FileBrowserPage';
import { computed, contrastRatio } from '../utils/theme';

/**
 * Overwrite confirmation.
 *
 * Two halves that meet in the middle:
 *  - the server refuses an overwriting upload unless the request asks
 *    (`?overwrite=1`), except on /internal-download/ where service-to-service
 *    clients keep the silent overwrite they have always had;
 *  - the pages ask first, via a `?check=1` pre-flight (upload) or the 409 the
 *    server already returned (copy/move/rename).
 *
 * The server half runs over plain HTTP with no browser, because the contract is
 * the part that must not drift.
 */

const TMP = '/download/e2e-conflict';
const INTERNAL = '/internal-download/e2e-conflict';
const TMP_RE = /\/download\/e2e-conflict\//;

const RENAME_SRC = 'e2e-conflict-holder';
const RENAME_DEST = 'e2e-conflict-target';

function upload(request: APIRequestContext, dir: string, name: string, body: string) {
  return request.post(dir, {
    multipart: {
      file: { name, mimeType: 'text/plain', buffer: Buffer.from(body) },
    },
  });
}

test.describe('Overwrite — server contract', () => {
  test.afterAll(async ({ request }) => {
    await request.delete(`${TMP}/`);
    await request.delete(`/download/${RENAME_SRC}/`);
    await request.delete(`/download/${RENAME_DEST}/`);
  });

  test('re-uploading an existing name without the flag is refused, and the original survives', async ({ request }) => {
    expect((await upload(request, `${TMP}/`, 'kept.txt', 'FIRST')).status()).toBe(200);

    const refused = await upload(request, `${TMP}/`, 'kept.txt', 'SECOND');
    expect(refused.status()).toBe(409);
    expect(await refused.json()).toEqual({ exists: true, type: 'file' });

    // The point of the whole change: the refusal must not have truncated it.
    expect(await (await request.get(`${TMP}/kept.txt`)).text()).toBe('FIRST');
  });

  test('with ?overwrite=1 the same upload replaces it', async ({ request }) => {
    expect((await upload(request, `${TMP}/`, 'swap.txt', 'FIRST')).status()).toBe(200);
    expect((await upload(request, `${TMP}/?overwrite=1`, 'swap.txt', 'SECOND')).status()).toBe(200);
    expect(await (await request.get(`${TMP}/swap.txt`)).text()).toBe('SECOND');
  });

  test('the internal channel keeps its silent overwrite', async ({ request }) => {
    // The documented service-to-service endpoint (README): those clients
    // re-publish the same filename and must not start failing.
    expect((await upload(request, `${INTERNAL}/`, 'service.txt', 'ONE')).status()).toBe(200);
    expect((await upload(request, `${INTERNAL}/`, 'service.txt', 'TWO')).status()).toBe(200);
    expect(await (await request.get(`${TMP}/service.txt`)).text()).toBe('TWO');
  });

  test('a directory in the way is a conflict even with the flag', async ({ request }) => {
    // ?overwrite=1 cannot mean "replace a directory with a file": io.open would
    // fail, and the old code surfaced that as a bare 400. `documents` is a
    // seeded directory, so this needs no fixture of its own.
    const response = await upload(request, '/download/?overwrite=1', 'documents', 'x');
    expect(response.status()).toBe(409);
    expect(await response.json()).toEqual({ exists: true, type: 'directory' });
  });
});

test.describe('Overwrite — the ?check=1 pre-flight', () => {
  const check = (request: APIRequestContext, url: string, names: string[]) =>
    request.post(`${url}?check=1`, { data: { names } });

  test('reports only the names that are taken, with their type', async ({ request }) => {
    const response = await check(request, '/download/documents/', ['notes.txt', 'no-such-file.txt']);
    expect(response.status()).toBe(200);
    expect(await response.json()).toEqual({
      existing: [{ name: 'notes.txt', type: 'file' }],
    });
  });

  test('an empty answer is a JSON array, never an object', async ({ request }) => {
    // cjson renders an empty Lua table as {}, which the client then iterates.
    const response = await check(request, '/download/documents/', ['no-such-file.txt']);
    expect((await response.text()).trim()).toBe('{"existing":[]}');
  });

  test('names that are not names are ignored', async ({ request }) => {
    const response = await check(request, '/download/documents/', ['..', '.', '', '/']);
    expect(await response.json()).toEqual({ existing: [] });
  });

  test('a CJK name is found', async ({ request }) => {
    const response = await check(request, '/download/', ['中文测试文件.txt']);
    expect(await response.json()).toEqual({
      existing: [{ name: '中文测试文件.txt', type: 'file' }],
    });
  });

  test('checking never creates the directory', async ({ request }) => {
    // A question with side effects would conjure the destination out of nothing,
    // and the "creates intermediate dirs" upload test would pass for the wrong
    // reason.
    await check(request, '/download/e2e-check-nodir/deeper/', ['anything.txt']);
    expect((await request.get('/download/e2e-check-nodir/')).status()).toBe(404);
  });
});

test.describe('Overwrite — the upload page', () => {
  /**
   * Stub the check and the upload so the request shape can be asserted without
   * touching the server. `taken` decides which names the check reports.
   */
  async function stubOverwrite(page: Page, taken: string[]) {
    const checks: { names: string[] }[] = [];
    const uploads: string[] = [];

    await page.route(TMP_RE, async (route) => {
      const request = route.request();
      if (request.method() !== 'POST') return route.continue();

      if (new URL(request.url()).searchParams.get('check') === '1') {
        const names = (request.postDataJSON() as { names: string[] }).names;
        checks.push({ names });
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            existing: names
              .filter((name) => taken.includes(name))
              .map((name) => ({ name, type: 'file' })),
          }),
        });
      }

      uploads.push(request.url());
      return route.fulfill({ status: 200, body: 'upload successfully!' });
    });

    return { checks, uploads };
  }

  const files = () => [
    { name: 'e2e-known.txt', mimeType: 'text/plain', buffer: Buffer.from('a') },
    { name: 'e2e-fresh.txt', mimeType: 'text/plain', buffer: Buffer.from('b') },
  ];

  test('asks once for the batch, then flags only the file it was told about', async ({ page }) => {
    const { checks, uploads } = await stubOverwrite(page, ['e2e-known.txt']);

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles(files());
    await up.startUpload();

    await expect(up.getOverwriteModal()).toBeVisible();
    await expect(up.getOverwriteNames()).toHaveText(['e2e-known.txt']);

    await up.chooseOverwrite();
    await expect(up.getFileItemsByStatus('success')).toHaveCount(2);

    // One check for the whole batch, carrying both names.
    expect(checks).toHaveLength(1);
    expect(checks[0].names.slice().sort()).toEqual(['e2e-fresh.txt', 'e2e-known.txt']);

    // And the flag travels on the replaced file only.
    expect(uploads.filter((u) => u.includes('overwrite=1'))).toHaveLength(1);
    expect(uploads.filter((u) => !u.includes('overwrite=1'))).toHaveLength(1);
  });

  test('skip leaves the existing file alone and uploads the rest', async ({ page }) => {
    const { uploads } = await stubOverwrite(page, ['e2e-known.txt']);

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles(files());
    await up.startUpload();

    await expect(up.getOverwriteModal()).toBeVisible();
    await up.chooseSkip();

    await expect(up.getFileItemsByStatus('skipped')).toHaveCount(1);
    await expect(up.getFileItemsByStatus('success')).toHaveCount(1);

    // Nothing at all was sent for the skipped file.
    expect(uploads).toHaveLength(1);
    expect(new URL(uploads[0]).searchParams.get('overwrite')).toBeNull();
  });

  test('cancel writes nothing at all', async ({ page }) => {
    const { uploads } = await stubOverwrite(page, ['e2e-known.txt']);

    const up = new UploadPage(page);
    await up.gotoUploadTo(`${TMP}/`);
    await up.selectFiles([files()[0]]);
    await up.startUpload();

    await expect(up.getOverwriteModal()).toBeVisible();
    await up.chooseCancel();

    await expect(up.getOverwriteModal()).toBeHidden();
    expect(uploads).toHaveLength(0);
    // Left in the queue, so the button offers to try again.
    await expect(up.getFileItemsByStatus('pending')).toHaveCount(1);
  });

  test('the dialog is legible in both themes', async ({ page }) => {
    await stubOverwrite(page, ['e2e-known.txt']);
    const up = new UploadPage(page);

    for (const mode of ['light', 'dark'] as const) {
      // Nothing is stored, so the page's anti-FOUC snippet falls through to
      // prefers-color-scheme.
      await page.emulateMedia({ colorScheme: mode });

      await up.gotoUploadTo(`${TMP}/`);
      await up.selectFiles([files()[0]]);
      await up.startUpload();
      await expect(up.getOverwriteModal()).toBeVisible();

      // Bootstrap 5.1.3 hardcodes .modal-content to #fff, so the dark shell has
      // to override it. Asserting the property that matters, not a hex value.
      const surface = await computed(page, '#overwriteConfirmBtn', 'background-color');
      const label = await computed(page, '#overwriteConfirmBtn', 'color');
      const ratio = contrastRatio(label, surface);
      expect(ratio, `${mode}: ${label} on ${surface} = ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
    }
  });
});

test.describe('Overwrite — the file browser', () => {
  test.beforeAll(async ({ request }) => {
    await request.delete(`/download/${RENAME_SRC}/`);
    await request.delete(`/download/${RENAME_DEST}/`);
    // Two folders side by side: the source is renamed or copied onto the target.
    await upload(request, `/download/${RENAME_SRC}/`, 'inside.txt', 'x');
    await upload(request, `/download/${RENAME_DEST}/`, 'existing.txt', 'x');
  });

  test.afterAll(async ({ request }) => {
    await request.delete(`/download/${RENAME_SRC}/`);
    await request.delete(`/download/${RENAME_DEST}/`);
  });

  test('renaming onto a folder warns that its contents are deleted, not merged', async ({ page }) => {
    const fb = new FileBrowserPage(page);
    await fb.gotoBucket('download');

    await fb.openThreeDotMenu(RENAME_SRC);
    await page.locator('.file-three-dot-menu.active .dropdown-item:has-text("Rename")').click();
    await page.waitForTimeout(300);

    await page.locator('#renameNewName').fill(RENAME_DEST);
    await page.locator('#renameModal .btn-primary').click();

    const modal = fb.getModal('overwriteModal');
    await expect(modal).toBeVisible();
    // files.lua rm -rf's the target for this action, so "merge" would be a lie.
    await expect(fb.overwriteMessage()).toContainText('permanently delete everything inside it');

    await fb.cancelOverwrite();
    await expect(modal).toBeHidden();
    // Cancelling leaves the rename dialog up, ready to be corrected.
    await expect(fb.getModal('renameModal')).toBeVisible();
  });

  test('copying onto a folder offers a merge, and cancelling sends no second PUT', async ({ page }) => {
    const fb = new FileBrowserPage(page);

    const puts: string[] = [];
    await page.route(/\/download\/e2e-conflict-target/, (route) => {
      if (route.request().method() === 'PUT') puts.push(route.request().postData() ?? '');
      return route.continue();
    });

    await fb.gotoBucket('download');
    await fb.openThreeDotMenu(RENAME_SRC);
    await page.locator('.file-three-dot-menu.active .dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    await page.locator('#copyDestPath').fill(`/${RENAME_DEST}`);
    await page.locator('#copyMoveModal .btn-primary').click();

    await expect(fb.getModal('overwriteModal')).toBeVisible();
    await expect(fb.overwriteTitle()).toContainText('folder');
    await expect(fb.overwriteMessage()).toContainText('merge the two folders');

    await fb.cancelOverwrite();
    await expect(fb.getModal('overwriteModal')).toBeHidden();
    // The copy dialog survives, and the refusal was not retried behind it.
    await expect(fb.getModal('copyMoveModal')).toBeVisible();
    expect(puts.filter((b) => b.includes('force=true'))).toHaveLength(0);
  });

  test('the conflict is a modal, never a native dialog', async ({ page }) => {
    const fb = new FileBrowserPage(page);
    let dialogSeen = false;
    page.on('dialog', (d) => {
      dialogSeen = true;
      void d.dismiss();
    });

    await fb.gotoBucket('download');
    await fb.openThreeDotMenu(RENAME_SRC);
    await page.locator('.file-three-dot-menu.active .dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    await page.locator('#copyDestPath').fill(`/${RENAME_DEST}`);
    await page.locator('#copyMoveModal .btn-primary').click();

    await expect(fb.getModal('overwriteModal')).toBeVisible();
    expect(dialogSeen).toBe(false);
    await fb.cancelOverwrite();
  });
});
