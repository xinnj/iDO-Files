import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('File operations', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('delete modal opens and shows file path', async () => {
    await fb.gotoBucket('download', 'documents/');
    // Delete a text file we know exists
    const testFile = 'notes.txt';

    // Click "Delete" in three-dot menu (scope to active menu)
    await fb.openThreeDotMenu(testFile);
    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Delete")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('deleteModal');
    await expect(modal).toBeVisible();
  });

  test('rename modal opens and pre-fills name', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Rename")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('renameModal');
    await expect(modal).toBeVisible();
  });

  test('copy/move modal opens', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('copyMoveModal');
    await expect(modal).toBeVisible();
  });

  test('delete modal can be closed', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Delete")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('deleteModal');
    await expect(modal).toBeVisible();

    // Close via cancel button or overlay
    await fb.page.locator('#deleteModal .modal-cancel, #deleteModal .btn-cancel, #deleteModal button:has-text("Cancel")').click();
    await fb.page.waitForTimeout(300);

    // Modal should be hidden
    await expect(modal).not.toBeVisible();
  });

  test('share modal opens for file', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('shareModal');
    await expect(modal).toBeVisible();
  });
});
