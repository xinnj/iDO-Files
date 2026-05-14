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
});
