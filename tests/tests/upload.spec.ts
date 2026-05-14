import { test, expect } from '@playwright/test';
import { UploadPage } from '../pages/UploadPage';

test.describe('Upload', () => {
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
    // Input may be hidden (styled), but should exist
    await expect(input).toBeAttached();
  });

  test('has upload button', async () => {
    const btn = up.page.locator('button:has-text("Upload"), button:has-text("Start")');
    await expect(btn.first()).toBeVisible();
  });
});
