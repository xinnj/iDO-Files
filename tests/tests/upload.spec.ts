import { test, expect } from '@playwright/test';
import { UploadPage } from '../pages/UploadPage';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Upload page UI', () => {
  let up: UploadPage;

  test.beforeEach(async ({ page }) => {
    up = new UploadPage(page);
    await up.gotoUpload();
  });

  test('upload page loads', async () => {
    await expect(up.getUploadArea()).toBeVisible();
  });

  test('has file input', async () => {
    const input = up.getFileInput();
    await expect(input).toBeAttached();
  });

  test('has upload button', async () => {
    const btn = up.page.locator('button:has-text("Upload"), button:has-text("Start")');
    await expect(btn.first()).toBeVisible();
  });
});

test.describe('Upload E2E', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('upload file to download bucket and verify on backend', async ({ page }) => {
    const tmpDir = '/download/e2e-upload-tmp';
    const fileName = 'e2e-upload.txt';
    const fileContent = 'Hello from E2E upload test!';

    // Cleanup stale tmp dir from previous runs
    await page.goto('/download/');
    await page.waitForTimeout(500);
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Navigate to upload page — set referrer so the page knows where to upload
    await page.goto('/fileserver/upload.html', {
      referer: `http://localhost:8080${tmpDir}/`,
    });
    await page.waitForTimeout(500);

    // Verify upload area is visible
    await expect(page.locator('#uploadArea')).toBeVisible();

    // Select file via the "Select Files" button (hidden input triggers file chooser)
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      page.locator('button:has-text("Select Files")').click(),
    ]);
    await fileChooser.setFiles({
      name: fileName,
      mimeType: 'text/plain',
      buffer: Buffer.from(fileContent),
    });

    // Verify file appears in queue
    await expect(page.locator('.file-item')).toBeVisible();

    // Start upload
    await page.locator('#uploadButton').click();

    // Wait for success status
    await page.waitForSelector('.status-success', { timeout: 10000 });

    // Navigate to bucket and verify file exists via backend-served JSON
    await fb.gotoBucket('download', 'e2e-upload-tmp/');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === fileName)).toBeTruthy();

    // Verify file content via direct download
    const dlResp = await page.request.get(tmpDir + '/' + fileName);
    expect(dlResp.status()).toBe(200);
    expect(await dlResp.text()).toBe(fileContent);

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('upload file into a subdirectory (creates intermediate dirs)', async ({ page }) => {
    const tmpDir = '/download/e2e-upload-tmp';
    const subDir = 'nested/subdir';
    const fileName = 'deep-upload.txt';
    const fileContent = 'Deeply nested upload';

    // Cleanup stale tmp dir
    await page.goto('/download/');
    await page.waitForTimeout(500);
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Upload to a nested subdirectory — use referrer to set upload base
    await page.goto('/fileserver/upload.html', {
      referer: `http://localhost:8080${tmpDir}/${subDir}/`,
    });
    await page.waitForTimeout(500);

    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      page.locator('button:has-text("Select Files")').click(),
    ]);
    await fileChooser.setFiles({
      name: fileName,
      mimeType: 'text/plain',
      buffer: Buffer.from(fileContent),
    });

    await page.locator('#uploadButton').click();
    await page.waitForSelector('.status-success', { timeout: 10000 });

    // Navigate into the nested dir and verify
    await fb.gotoBucket('download', 'e2e-upload-tmp/nested/subdir/');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === fileName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });
});
