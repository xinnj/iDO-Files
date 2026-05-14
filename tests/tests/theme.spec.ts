import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Theme', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
    await fb.gotoBucket('download');
  });

  test('toggles dark/light theme on button click', async () => {
    const initial = await fb.getCurrentTheme();
    await fb.getThemeToggle().click();
    await fb.page.waitForTimeout(300);
    const toggled = await fb.getCurrentTheme();
    expect(toggled).not.toBe(initial);
    expect(['light', 'dark']).toContain(toggled);
  });

  test('persists theme preference in localStorage', async () => {
    await fb.getThemeToggle().click();
    await fb.page.waitForTimeout(300);
    const stored = await fb.page.evaluate(() => localStorage.getItem('theme'));
    expect(stored).toBeTruthy();
    const current = await fb.getCurrentTheme();
    expect(stored).toBe(current);
  });

  test('theme toggle button is visible', async () => {
    await expect(fb.getThemeToggle()).toBeVisible();
  });
});
