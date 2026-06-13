import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Sort', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
    await fb.gotoBucket('download');
  });

  test('default sort is by modified desc', async () => {
    const active = await fb.getActiveSort();
    const dir = await fb.getSortDirection();
    expect(active).toBe('modified');
    expect(dir).toBe('desc');
  });

  test('click name sort toggles direction', async () => {
    await fb.clickSortColumn('name');
    let dir = await fb.getSortDirection();
    expect(dir).toBe('asc');

    await fb.clickSortColumn('name');
    dir = await fb.getSortDirection();
    expect(dir).toBe('desc');
  });

  test('click size sorts by size', async () => {
    await fb.clickSortColumn('size');
    const active = await fb.getActiveSort();
    expect(active).toBe('size');
  });

  test('folders remain first regardless of sort', async () => {
    await fb.clickSortColumn('name');
    await fb.clickSortColumn('name'); // desc order
    const data = await fb.getFileData();
    const firstFew = data.files.slice(0, 5);
    const allFolders = firstFew.every((f) => f.type === 'directory');
    expect(allFolders).toBeTruthy();
  });

  test('sort state persists across page reload', async ({ page }) => {
    // Sort by name ascending
    await fb.clickSortColumn('name');

    // Verify URL contains sort params
    const urlBefore = page.url();
    expect(urlBefore).toContain('sort=name');
    expect(urlBefore).toContain('dir=asc');

    // Reload and verify sort state is preserved
    await page.reload();
    await page.waitForLoadState('domcontentloaded');

    const active = await fb.getActiveSort();
    const dir = await fb.getSortDirection();
    expect(active).toBe('name');
    expect(dir).toBe('asc');
  });

  test('sort state persists across pagination', async ({ page }) => {
    // Sort by size
    await fb.clickSortColumn('size');

    // Navigate to another page (if pagination exists)
    const pageLink = page.locator('.pagination-page').first();
    if (await pageLink.isVisible()) {
      await pageLink.click();
      await page.waitForLoadState('domcontentloaded');

      const active = await fb.getActiveSort();
      const dir = await fb.getSortDirection();
      expect(active).toBe('size');
      expect(dir).toBe('asc');

      // URL should contain sort params
      expect(page.url()).toContain('sort=size');
    }
  });
});
