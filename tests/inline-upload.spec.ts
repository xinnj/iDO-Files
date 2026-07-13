import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

const TMP_DIR = '/download/e2e-inline-upload-tmp';

test.describe('Inline upload', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);

    // Cleanup stale tmp dir from previous runs
    await page.goto('/download/');
    await page.waitForTimeout(300);
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, TMP_DIR);
    await page.waitForTimeout(300);

    // Navigate to the temp directory
    await fb.gotoBucket('download', 'e2e-inline-upload-tmp/');
  });

  test.afterEach(async ({ page }) => {
    // Cleanup
    await page.goto('/download/');
    await page.waitForTimeout(300);
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, TMP_DIR);
  });

  test('upload button opens file picker', async ({ page }) => {
    const uploadBtn = page.locator('#upload-btn');
    await expect(uploadBtn).toBeVisible();

    // Click upload button and verify file chooser opens
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadBtn.click(),
    ]);
    expect(fileChooser).toBeTruthy();
  });

  test('inline upload sends correct POST request', async ({ page }) => {
    const fileName = 'inline-upload.txt';
    const fileContent = 'Hello from inline upload!';

    // Intercept POST to verify correct URL
    const postPromise = page.waitForRequest(
      (req) => req.method() === 'POST' && req.url().includes(TMP_DIR),
      { timeout: 5000 }
    );

    // Click upload, select file
    const uploadBtn = page.locator('#upload-btn');
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadBtn.click(),
    ]);
    await fileChooser.setFiles({
      name: fileName,
      mimeType: 'text/plain',
      buffer: Buffer.from(fileContent),
    });

    // Verify the POST request was sent to the correct URL
    const postReq = await postPromise;
    expect(postReq.method()).toBe('POST');
    expect(postReq.url()).toContain(TMP_DIR);
  });

  test('upload banner appears with filename and progress', async ({ page }) => {
    const fileName = 'banner-test.txt';

    // Start upload
    const uploadBtn = page.locator('#upload-btn');
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadBtn.click(),
    ]);
    await fileChooser.setFiles({
      name: fileName,
      mimeType: 'text/plain',
      buffer: Buffer.from('banner test content'),
    });

    // Verify upload banner appears
    const banner = page.locator('#uploadBanner');
    await expect(banner).toBeVisible({ timeout: 5000 });

    // Verify banner shows filename
    const bannerFilename = page.locator('#uploadBannerFilename');
    await expect(bannerFilename).toContainText(fileName);

    // Verify progress bar track and fill exist
    const track = page.locator('.upload-banner-track');
    const fill = page.locator('#uploadBannerFill');
    await expect(track).toBeVisible();
    await expect(fill).toBeVisible();

    // Verify percentage is shown
    const pct = page.locator('#uploadBannerPct');
    await expect(pct).toBeVisible();

    // Wait for completion and page reload
    await page.waitForLoadState('domcontentloaded', { timeout: 10000 });
  });

  test('upload button disabled during upload', async ({ page }) => {
    const uploadBtn = page.locator('#upload-btn');

    // Start upload
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadBtn.click(),
    ]);
    await fileChooser.setFiles({
      name: 'disabled-test.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('test'),
    });

    // Button should be disabled while upload is in progress
    await expect(uploadBtn).toBeDisabled({ timeout: 3000 });

    // Wait for page reload
    await page.waitForLoadState('domcontentloaded', { timeout: 10000 });

    // After reload, new upload button should be enabled
    await expect(page.locator('#upload-btn')).toBeEnabled();
  });

  test('upload completes and file appears in listing', async ({ page }) => {
    const fileName = 'complete-upload.txt';
    const fileContent = 'Upload complete test';

    // Start upload
    const uploadBtn = page.locator('#upload-btn');
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadBtn.click(),
    ]);
    await fileChooser.setFiles({
      name: fileName,
      mimeType: 'text/plain',
      buffer: Buffer.from(fileContent),
    });

    // Wait for page reload after successful upload
    await page.waitForLoadState('domcontentloaded', { timeout: 10000 });

    // Verify file appears in listing
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === fileName)).toBeTruthy();

    // Verify file content
    const dlResp = await page.request.get(TMP_DIR + '/' + fileName);
    expect(dlResp.status()).toBe(200);
    expect(await dlResp.text()).toBe(fileContent);
  });

  test('cancel button stops upload and shows toast', async ({ page }) => {
    // Route POST to stall — giving us time to click cancel
    await page.route('**/*', async (route) => {
      if (route.request().method() === 'POST' && route.request().url().includes(TMP_DIR)) {
        // Hold indefinitely so we can test cancel
        await new Promise(() => {});
      } else {
        await route.continue();
      }
    });

    const uploadBtn = page.locator('#upload-btn');
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadBtn.click(),
    ]);
    await fileChooser.setFiles({
      name: 'cancel-test.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('should be cancelled'),
    });

    // Verify banner and cancel button appear
    const banner = page.locator('#uploadBanner');
    const cancelBtn = page.locator('#uploadCancelBtn');
    await expect(banner).toBeVisible({ timeout: 5000 });
    await expect(cancelBtn).toBeVisible();

    // Accept the confirm dialog, then click cancel
    page.once('dialog', (dialog) => dialog.accept());
    await cancelBtn.click();

    // Banner should hide
    await expect(banner).toBeHidden({ timeout: 5000 });

    // Upload button should be re-enabled
    await expect(uploadBtn).toBeEnabled({ timeout: 3000 });

    // Warning toast should appear
    const toast = page.locator('.toast.warning');
    await expect(toast).toBeVisible({ timeout: 5000 });
  });
});

test.describe('Upload Files menu item', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
    await fb.gotoBucket('download', '');
  });

  test('Upload Files link is in user dropdown', async ({ page }) => {
    // Open user dropdown
    await page.locator('#userTrigger').click();
    const userMenu = page.locator('#userMenu');
    await expect(userMenu).toHaveClass(/active/);

    // Verify "Upload Files" menu item
    const uploadFilesLink = page.locator('.dropdown-item:has-text("Upload Files")');
    await expect(uploadFilesLink).toBeVisible();
    await expect(uploadFilesLink).toHaveAttribute('href', /upload\.html/);
    await expect(uploadFilesLink).toHaveAttribute('target', '_blank');
  });

  test('Upload Files link opens upload.html', async ({ page }) => {
    // Open user dropdown
    await page.locator('#userTrigger').click();

    // Click Upload Files — it should open a new tab (target=_blank)
    const uploadFilesLink = page.locator('.dropdown-item:has-text("Upload Files")');
    const [newPage] = await Promise.all([
      page.context().waitForEvent('page'),
      uploadFilesLink.click(),
    ]);

    // Verify the new page loaded upload.html
    await newPage.waitForLoadState('domcontentloaded');
    expect(newPage.url()).toContain('upload.html');

    // Verify the upload area is visible
    await expect(newPage.locator('#uploadArea')).toBeVisible();

    // Clean up the new page
    await newPage.close();
  });
});
