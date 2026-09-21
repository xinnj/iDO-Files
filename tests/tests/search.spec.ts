import { test, expect } from '@playwright/test';
import { FileBrowserPage, isListingFragment } from '../pages/FileBrowserPage';

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

  test('finds a file that lives on a later page', async () => {
    // many_files/ holds file_01.txt .. file_30.txt with PAGE_LIMIT=10 in the
    // test env, so file_30.txt is on page 3 and is not in the initial list.
    await fb.gotoBucket('download', 'many_files/');
    expect(await fb.getVisibleFileNames()).not.toContain('file_30.txt');

    await fb.search('file_30');

    expect(await fb.getVisibleFileNames()).toContain('file_30.txt');
  });

  test('a q in the URL renders filtered, server-side', async () => {
    // No client fetch: the page must arrive already filtered, so a refresh or
    // a shared link reproduces the search.
    await fb.goto('/download/many_files/?q=file_30');

    await expect(fb.getSearchInput()).toHaveValue('file_30');
    expect(await fb.getVisibleFileNames()).toEqual(['file_30.txt']);
    await expect(fb.page.locator('#search-results-info')).toBeVisible();
    await expect(fb.page.locator('#search-count')).toHaveText('1');
  });

  test('a query matching nothing says so, inside the list', async () => {
    await fb.goto('/download/many_files/?q=zzz_matches_nothing');

    expect(await fb.getVisibleFileNames()).toEqual([]);
    // The message belongs to the list region: the separate #empty-search block
    // sits inside <!--IF_WRITEABLE--> and is absent for read-only users.
    await expect(fb.page.locator('.file-list .empty-state h3')).toHaveText('No files found');
  });

  test('pagination links keep the query', async () => {
    await fb.goto('/download/many_files/?q=file_');

    const hrefs = await fb.page
      .locator('.pagination-page')
      .evaluateAll((els) => els.map((el) => el.getAttribute('href') || ''));
    expect(hrefs.length).toBeGreaterThan(0);
    for (const href of hrefs) expect(href).toContain('q=file_');

    // The page-size selector resets to page 1 and must keep the filter too.
    const onchange = await fb.page.locator('#page-limit').getAttribute('onchange');
    expect(onchange).toContain('q=file_');
  });

  test('asks the server for the filtered list with the current params', async () => {
    await fb.gotoBucket('download', 'many_files/');

    const requestPromise = fb.page.waitForRequest((req) => req.url().includes('partial=1'));
    const responsePromise = fb.page.waitForResponse(isListingFragment);
    await fb.getSearchInput().fill('file_30');
    const request = await requestPromise;
    await responsePromise;

    const url = new URL(request.url());
    expect(url.pathname).toBe('/download/many_files/');
    expect(url.searchParams.get('q')).toBe('file_30');
    expect(url.searchParams.get('partial')).toBe('1');
    // A new query starts at page 1 and carries the rest of the view state.
    expect(url.searchParams.get('page')).toBe('1');
    expect(url.searchParams.get('limit')).toBe('10');
    expect(url.searchParams.get('sort')).toBe('modified');
    expect(url.searchParams.get('dir')).toBe('desc');

    // And the rows it returned are the ones on screen.
    await expect(fb.getFileItem('file_30.txt')).toBeVisible();
    await expect(fb.page.locator('.file-item')).toHaveCount(1);
  });

  test('slow typing settles on the last query, not an earlier one', async () => {
    await fb.gotoBucket('download', 'many_files/');

    // Identifies the request for the final query specifically: every keystroke
    // gets its own request, and only this one must survive to be rendered.
    const finalResponse = fb.page.waitForResponse(
      (res) => isListingFragment(res) && new URL(res.url()).searchParams.get('q') === 'file_2'
    );

    // Slower than the debounce, so every keystroke fires a request and the
    // earlier ones have to be discarded rather than applied out of order.
    await fb.getSearchInput().pressSequentially('file_2', { delay: 300 });
    await finalResponse;
    await fb.waitForListToSettle();

    const names = await fb.getVisibleFileNames();
    // 'file_2' matches file_20 .. file_29 exactly. A stale response for the
    // earlier 'file_' would instead render file_01 .. file_10.
    expect([...names].sort()).toEqual([
      'file_20.txt', 'file_21.txt', 'file_22.txt', 'file_23.txt', 'file_24.txt',
      'file_25.txt', 'file_26.txt', 'file_27.txt', 'file_28.txt', 'file_29.txt',
    ]);
  });

  test('sorting while showing no results keeps the message', async () => {
    await fb.gotoBucket('download', 'many_files/');
    await fb.search('zzz_matches_nothing');
    await expect(fb.page.locator('.file-list .empty-state')).toBeVisible();

    await fb.clickSortColumn('name');

    // Re-sorting an empty list used to clear .file-list outright, leaving a
    // blank area with nothing to explain it.
    await expect(fb.page.locator('.file-list .empty-state')).toBeVisible();
  });

  test('row menus still work on a searched row', async () => {
    await fb.gotoBucket('download', 'many_files/');
    await fb.search('file_30');
    expect(await fb.getVisibleFileNames()).toEqual(['file_30.txt']);

    // Rename resolves its target through fileData.files, which the swap has to
    // keep in step with the rows it rendered. A stale copy fails silently:
    // showRenameModal returns early, so no modal appears and nothing is logged.
    await fb.openThreeDotMenu('file_30.txt');
    await fb.clickThreeDotMenuItem('Rename');

    await expect(fb.page.locator('#renameModal')).toBeVisible();
    await expect(fb.page.locator('#renameCurrentName')).toHaveText('file_30.txt');
  });
});
