import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Search', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
    await fb.gotoBucket('download');
  });

  test('filters files by name', async () => {
    await fb.search('doc');
    const names = await fb.getVisibleFileNames();
    expect(names.every((n) => n.toLowerCase().includes('doc'))).toBeTruthy();
  });

  test('shows search results info', async () => {
    await fb.search('doc');
    const info = fb.getSearchResultsInfo();
    await expect(info).toBeVisible();
  });

  test('clear search restores all files', async () => {
    const totalBefore = (await fb.getVisibleFileNames()).length;
    await fb.search('doc');
    const filteredCount = (await fb.getVisibleFileNames()).length;
    // Search should reduce visible items
    expect(filteredCount).toBeLessThanOrEqual(totalBefore);

    await fb.clearSearch();
    const afterClear = (await fb.getVisibleFileNames()).length;
    expect(afterClear).toBe(totalBefore);
  });

  test('case-insensitive search', async () => {
    await fb.search('DOCUMENTS');
    const names = await fb.getVisibleFileNames();
    expect(names.some((n) => n.toLowerCase().includes('documents'))).toBeTruthy();
  });

  test('no results shows empty state', async () => {
    await fb.search('xyznonexistent12345');
    const visible = await fb.page.locator('.file-item:visible').count();
    // Either all items are hidden, or a "no results" message is shown
    expect(visible === 0 || (await fb.page.locator('.empty-state').isVisible())).toBeTruthy();
  });
});
