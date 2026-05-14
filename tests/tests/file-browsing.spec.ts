import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('File browsing', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('loads download bucket with file listing', async () => {
    await fb.gotoBucket('download');
    const data = await fb.getFileData();
    expect(data.files.length).toBeGreaterThan(0);
    expect(data.files.some((f) => f.name === 'documents')).toBeTruthy();
    expect(data.files.some((f) => f.name === 'code')).toBeTruthy();
  });

  test('shows folders first in listing', async () => {
    await fb.gotoBucket('download');
    const data = await fb.getFileData();
    const firstItem = data.files[0];
    expect(firstItem.type).toBe('directory');
  });

  test('loads public bucket', async () => {
    await fb.gotoBucket('public');
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === 'public-note.txt')).toBeTruthy();
  });

  test('loads archive bucket', async () => {
    await fb.gotoBucket('archive');
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === 'old_reports')).toBeTruthy();
  });

  test('navigates into folder and back via breadcrumb', async () => {
    await fb.gotoBucket('download');
    await fb.openFolder('documents');
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === 'notes.txt')).toBeTruthy();

    // Navigate back to root via breadcrumb (second item = bucket name)
    await fb.clickBreadcrumb(1);
    const rootData = await fb.getFileData();
    expect(rootData.files.some((f) => f.name === 'documents')).toBeTruthy();
  });

  test('switches buckets via home dropdown', async () => {
    await fb.gotoBucket('download');
    await fb.switchBucket('public');
    await expect(fb.page).toHaveURL(/\/public\//);
    const data = await fb.getFileData();
    expect(data.files.length).toBeGreaterThan(0);
  });

  test('shows empty state for empty directory', async () => {
    await fb.gotoBucket('download', 'empty_folder/');
    const emptyState = fb.page.locator('.empty-state.visible');
    await expect(emptyState).toBeVisible();
  });

  test('shows logo text', async () => {
    await fb.gotoBucket('download');
    await expect(fb.page.locator('.logo-text')).toHaveText('Test Files');
  });

  test('displays Chinese filenames correctly', async () => {
    await fb.gotoBucket('download');
    const data = await fb.getFileData();
    expect(data.files.some((f) => f.name === '中文测试文件.txt')).toBeTruthy();
    expect(data.files.some((f) => f.name === '测试目录')).toBeTruthy();
  });

  test('has visible sort header', async () => {
    await fb.gotoBucket('download');
    await expect(fb.getSortHeader()).toBeVisible();
  });

  test('has visible stats bar', async () => {
    await fb.gotoBucket('download');
    await expect(fb.page.locator('.stats-bar')).toBeVisible();
  });
});
