import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Pagination', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('shows pagination for many files', async () => {
    await fb.gotoBucket('download', 'many_files/');
    const info = await fb.getPaginationInfo();
    expect(info).not.toBeNull();
    expect(info!.pages).toBeGreaterThan(1);
    expect(info!.total).toBe(30);
  });

  test('navigates to next page', async () => {
    await fb.gotoBucket('download', 'many_files/');
    await fb.clickNextPage();
    const page = await fb.getCurrentPage();
    expect(page).toBe(2);
  });

  test('jumps to specific page', async () => {
    await fb.gotoBucket('download', 'many_files/');
    await fb.goToPage(3);
    const page = await fb.getCurrentPage();
    expect(page).toBe(3);
  });

  test('prev button disabled on first page', async () => {
    await fb.gotoBucket('download', 'many_files/');
    const info = await fb.getPaginationInfo();
    expect(info!.page).toBe(1);
    const prevBtn = fb.page.locator('.pagination-btn').first();
    await expect(prevBtn).toHaveClass(/disabled/);
  });

  test('no pagination when files fit single page', async () => {
    await fb.gotoBucket('download', 'documents/');
    const info = await fb.getPaginationInfo();
    expect(info!.pages).toBe(1);
  });
});
