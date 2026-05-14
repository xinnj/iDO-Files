import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Context menu', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
    await fb.gotoBucket('download');
  });

  test('right-click shows context menu', async () => {
    await fb.openContextMenu('documents');
    const menu = fb.page.locator('.context-menu');
    await expect(menu).toBeVisible();
  });

  test('context menu has action items', async () => {
    await fb.openContextMenu('documents');
    const items = fb.page.locator('.context-menu .dropdown-item, .context-menu .menu-item');
    const count = await items.count();
    expect(count).toBeGreaterThan(0);
  });

  test('three-dot menu opens on click', async () => {
    await fb.openThreeDotMenu('documents');
    const dropdown = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await expect(dropdown).toBeVisible();
  });

  test('three-dot menu has action items', async () => {
    await fb.openThreeDotMenu('documents');
    const items = await fb.getThreeDotMenuItems();
    expect(items.length).toBeGreaterThan(0);
  });
});
