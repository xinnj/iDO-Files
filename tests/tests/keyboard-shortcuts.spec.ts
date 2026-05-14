import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Keyboard shortcuts', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
    await fb.gotoBucket('download');
  });

  test('Ctrl+K focuses search input', async () => {
    await fb.page.keyboard.press('Control+k');
    const focused = await fb.page.evaluate(() => document.activeElement?.id);
    // Either the search input is focused
    expect(focused === 'search-input' || (await fb.getSearchInput().evaluate((el) => el === document.activeElement))).toBeTruthy();
  });

  test('Backspace navigates to parent folder', async () => {
    await fb.openFolder('documents');
    await fb.getSearchInput().blur(); // defocus any input
    await fb.page.keyboard.press('Backspace');
    await expect(fb.page).not.toHaveURL(/\/documents/);
  });

  test('Escape closes open menus and clears search', async () => {
    await fb.search('test');
    await fb.page.keyboard.press('Escape');
    // Search should be cleared
    const searchValue = await fb.getSearchInput().inputValue();
    expect(searchValue).toBe('');
  });
});
