import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('New folder', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  const TMP_NAME = 'e2e-create-folder';
  const TMP_DIR = `/download/${TMP_NAME}`;

  /** Seed a folder via the API, bypassing the UI */
  async function seedFolder(page: import('@playwright/test').Page, name: string) {
    await page.evaluate(async (folderName) => {
      await fetch('/download/', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'action=create&name=' + encodeURIComponent(folderName),
      });
    }, name);
  }

  /** Remove a temp dir left behind by a crashed previous run */
  async function removeFolder(page: import('@playwright/test').Page, url: string) {
    await page.evaluate(async (target) => {
      await fetch(target, { method: 'DELETE' });
    }, url);
    await page.waitForTimeout(300);
  }

  test('toolbar button opens the modal with an empty name', async ({ page }) => {
    await fb.gotoBucket('download', '');

    const button = page.locator('#new-folder-btn');
    await expect(button).toBeVisible();

    await button.click();

    const modal = fb.getModal('newFolderModal');
    await expect(modal).toBeVisible();
    await expect(modal.locator('#newFolderName')).toHaveValue('');
    await expect(modal.locator('#newFolderName')).toBeFocused();
    await expect(modal.locator('#newFolderError')).not.toBeVisible();
  });

  test('creates a folder at the bucket root and sends the correct request', async ({ page }) => {
    const name = 'e2e-new-folder';
    const folderUrl = `/download/${name}`;

    await fb.gotoBucket('download', '');
    await removeFolder(page, folderUrl);

    await fb.gotoBucket('download', '');
    await page.locator('#new-folder-btn').click();

    const modal = fb.getModal('newFolderModal');
    await modal.locator('#newFolderName').fill(name);

    // Both promises are created BEFORE the click so the response cannot be missed
    const putRequest = page.waitForRequest(
      (r) => r.method() === 'PUT' && new URL(r.url()).pathname === '/download/',
      { timeout: 10000 }
    );
    const putResponse = page.waitForResponse(
      (r) =>
        r.request().method() === 'PUT' &&
        new URL(r.url()).pathname === '/download/' &&
        r.status() === 200,
      { timeout: 10000 }
    );

    await modal.locator('#newFolderConfirmBtn').click();

    const request = await putRequest;
    const params = new URLSearchParams(request.postData() || '');
    expect(params.get('action')).toBe('create');
    expect(params.get('name')).toBe(name);
    expect(request.url()).not.toContain('//download');

    await putResponse;

    // The listing must reflect the new folder after the reload
    await fb.gotoBucket('download', '');
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === name && f.type === 'directory')).toBeTruthy();
    await expect(fb.getFileItem(name)).toBeVisible();

    await removeFolder(page, folderUrl);
  });

  test('creates a folder inside a folder opened by clicking', async ({ page }) => {
    await fb.gotoBucket('download', '');
    await removeFolder(page, TMP_DIR);
    await seedFolder(page, TMP_NAME);

    // Clicking a folder navigates to a URL with NO trailing slash
    await fb.gotoBucket('download', '');
    await fb.openFolder(TMP_NAME);
    expect(new URL(page.url()).pathname).toBe(TMP_DIR);

    await page.locator('#new-folder-btn').click();
    const modal = fb.getModal('newFolderModal');
    await modal.locator('#newFolderName').fill('inner');

    // The request must still carry a trailing slash, or the backend rejects it
    const putRequest = page.waitForRequest(
      (r) => r.method() === 'PUT' && new URL(r.url()).pathname === `${TMP_DIR}/`,
      { timeout: 10000 }
    );
    const putResponse = page.waitForResponse(
      (r) =>
        r.request().method() === 'PUT' &&
        new URL(r.url()).pathname === `${TMP_DIR}/` &&
        r.status() === 200,
      { timeout: 10000 }
    );

    await modal.locator('#newFolderConfirmBtn').click();
    await putRequest;
    await putResponse;

    await fb.gotoBucket('download', `${TMP_NAME}/`);
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === 'inner' && f.type === 'directory')).toBeTruthy();

    await removeFolder(page, TMP_DIR);
  });

  test('invalid names show an inline error and send no request', async ({ page }) => {
    const putUrls: string[] = [];
    page.on('request', (r) => {
      if (r.method() === 'PUT') putUrls.push(r.url());
    });

    await fb.gotoBucket('download', '');
    await page.locator('#new-folder-btn').click();

    const modal = fb.getModal('newFolderModal');
    const input = modal.locator('#newFolderName');
    const error = modal.locator('#newFolderError');

    const cases: Array<[string, string]> = [
      ['', 'Please enter a folder name'],
      ['a/b', "Folder name cannot contain '/' or '\\'"],
      ['a\\b', "Folder name cannot contain '/' or '\\'"],
      ['..', 'Invalid folder name'],
      ['.hidden', "Folder name cannot start with '.'"],
    ];

    for (const [value, message] of cases) {
      await input.fill(value);
      await modal.locator('#newFolderConfirmBtn').click();
      await expect(error).toBeVisible();
      await expect(error).toHaveText(message);
      await expect(modal).toBeVisible();
    }

    expect(putUrls).toEqual([]);

    // Typing clears the error again
    await input.fill('valid-name');
    await expect(error).not.toBeVisible();
  });

  test('a duplicate name on the current page is caught without a request', async ({ page }) => {
    const name = 'visible-dup';
    const folderUrl = `/download/${name}`;

    await fb.gotoBucket('download', '');
    await removeFolder(page, folderUrl);
    await seedFolder(page, name);

    const putUrls: string[] = [];
    page.on('request', (r) => {
      if (r.method() === 'PUT') putUrls.push(r.url());
    });

    // A fresh load puts the folder in the embedded listing
    await fb.gotoBucket('download', '');
    await page.locator('#new-folder-btn').click();

    const modal = fb.getModal('newFolderModal');
    await modal.locator('#newFolderName').fill(name);
    await modal.locator('#newFolderConfirmBtn').click();

    await expect(modal.locator('#newFolderError')).toBeVisible();
    await expect(modal.locator('#newFolderError')).toContainText('already exists');
    expect(putUrls).toEqual([]);

    await removeFolder(page, folderUrl);
  });

  test('a duplicate name missing from a stale listing shows the server conflict inline', async ({ page }) => {
    const name = 'stale-dup';
    const folderUrl = `/download/${name}`;

    await fb.gotoBucket('download', '');
    await removeFolder(page, folderUrl);

    // Load the listing BEFORE the folder exists, so the client-side check cannot see it
    await fb.gotoBucket('download', '');
    await seedFolder(page, name);

    let dialogSeen = false;
    page.on('dialog', (d) => {
      dialogSeen = true;
      d.dismiss();
    });

    await page.locator('#new-folder-btn').click();
    const modal = fb.getModal('newFolderModal');
    await modal.locator('#newFolderName').fill(name);

    const conflictResponse = page.waitForResponse(
      (r) => r.request().method() === 'PUT' && r.status() === 409,
      { timeout: 10000 }
    );
    await modal.locator('#newFolderConfirmBtn').click();
    await conflictResponse;

    // 409 must surface inline, never through the rename flow's window.confirm
    await expect(modal.locator('#newFolderError')).toBeVisible();
    await expect(modal.locator('#newFolderError')).toContainText('already exists');
    await expect(modal).toBeVisible();
    expect(dialogSeen).toBe(false);

    await removeFolder(page, folderUrl);
  });

  test('creates a UTF-8 named folder and one inside it', async ({ page }) => {
    const outer = '新建文件夹';
    const outerUrl = `/download/${encodeURIComponent(outer)}`;

    await fb.gotoBucket('download', '');
    await removeFolder(page, outerUrl);

    await fb.gotoBucket('download', '');
    await page.locator('#new-folder-btn').click();
    await fb.getModal('newFolderModal').locator('#newFolderName').fill(outer);

    const outerResponse = page.waitForResponse(
      (r) => r.request().method() === 'PUT' && r.status() === 200,
      { timeout: 10000 }
    );
    await fb.getModal('newFolderModal').locator('#newFolderConfirmBtn').click();
    await outerResponse;

    // Navigate into it — the page URL is now percent-encoded
    await fb.gotoBucket('download', '');
    await fb.openFolder(outer);

    await page.locator('#new-folder-btn').click();
    await fb.getModal('newFolderModal').locator('#newFolderName').fill('inner');

    const putRequest = page.waitForRequest(
      (r) =>
        r.method() === 'PUT' &&
        decodeURIComponent(new URL(r.url()).pathname) === `/download/${outer}/`,
      { timeout: 10000 }
    );
    const putResponse = page.waitForResponse(
      (r) =>
        r.request().method() === 'PUT' &&
        decodeURIComponent(new URL(r.url()).pathname) === `/download/${outer}/` &&
        r.status() === 200,
      { timeout: 10000 }
    );
    await fb.getModal('newFolderModal').locator('#newFolderConfirmBtn').click();
    await putRequest;
    await putResponse;

    await fb.gotoBucket('download', `${outer}/`);
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === 'inner' && f.type === 'directory')).toBeTruthy();

    await removeFolder(page, outerUrl);
  });
});
