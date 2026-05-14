import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Share links', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('share modal has create section', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await fb.page.waitForTimeout(300);

    // Should show a create share link form
    const createBtn = fb.page.locator('button:has-text("Create Link"), button:has-text("Create")');
    const expInput = fb.page.locator('#shareExpiration, input[type="number"]');
    // Either the create button or expiration input should be visible
    const hasCreateSection = (await createBtn.count()) > 0 || (await expInput.count()) > 0;
    expect(hasCreateSection).toBeTruthy();
  });

  test('share modal can be closed', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('shareModal');
    await expect(modal).toBeVisible();

    // Close it
    const closeBtn = fb.page.locator('#shareModal .modal-close, #shareModal .btn-close, #shareModal button:has-text("Cancel"), #shareModal button:has-text("Close")');
    if (await closeBtn.count() > 0) {
      await closeBtn.first().click();
    }
    await fb.page.waitForTimeout(300);
    await expect(modal).not.toBeVisible();
  });
});
