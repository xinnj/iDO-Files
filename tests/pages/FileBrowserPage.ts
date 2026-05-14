import { Page, Locator } from '@playwright/test';
import { BasePage } from './BasePage';

export interface FileItem {
  name: string;
  type: 'directory' | 'file';
  path: string;
  icon: string;
  modified: string;
}

export class FileBrowserPage extends BasePage {
  constructor(page: Page) {
    super(page);
  }

  async gotoBucket(bucket: 'download' | 'public' | 'archive', subPath = '') {
    const path = `/${bucket}/${subPath}`;
    await this.goto(path);
  }

  /** Get the parsed file data JSON from the page */
  async getFileData(): Promise<{ pagination: any; files: FileItem[] }> {
    return this.page.evaluate(() => {
      const el = document.getElementById('file-data');
      return el ? JSON.parse(el.textContent || '{}') : { pagination: {}, files: [] };
    });
  }

  /** Get all visible file item elements */
  getFileItems(): Locator {
    return this.page.locator('.file-item');
  }

  /** Get a specific file item by data-name */
  getFileItem(name: string): Locator {
    return this.page.locator(`.file-item[data-name="${name}"]`);
  }

  /** Get file names visible in the list (not hidden by search) */
  async getVisibleFileNames(): Promise<string[]> {
    const items = this.page.locator('.file-item');
    const count = await items.count();
    const names: string[] = [];
    for (let i = 0; i < count; i++) {
      const item = items.nth(i);
      const display = await item.getAttribute('style');
      // Skip hidden items (search filtering uses inline style display:none or hidden attribute)
      if (display && (display.includes('display: none') || display.includes('display:none'))) continue;
      const name = await item.locator('.file-name').innerText();
      names.push(name);
    }
    return names;
  }

  /** Click a folder to navigate into it */
  async openFolder(name: string) {
    await this.getFileItem(name).click();
    await this.page.waitForLoadState('domcontentloaded');
  }

  /** Click a file to open it (in viewer or native) */
  async clickFile(name: string) {
    await this.getFileItem(name).click();
  }

  /** Get breadcrumb text */
  async getBreadcrumbText(): Promise<string> {
    return this.page.locator('.breadcrumb').innerText();
  }

  /** Switch bucket via dropdown */
  async switchBucket(bucket: 'download' | 'public' | 'archive') {
    await this.page.locator('.breadcrumb-home-btn').hover();
    await this.page.locator(`.bucket-dropdown-item:has-text("${bucket}")`).click();
    await this.page.waitForLoadState('domcontentloaded');
  }

  /** Click breadcrumb segment */
  async clickBreadcrumb(index: number) {
    await this.page.locator('.breadcrumb-item').nth(index).click();
    await this.page.waitForLoadState('domcontentloaded');
  }

  /** Open the three-dot menu for a file */
  async openThreeDotMenu(itemName: string) {
    await this.getFileItem(itemName).hover();
    await this.getFileItem(itemName).locator('.file-three-dot-btn').click();
    await this.page.waitForTimeout(300);
  }

  /** Get three-dot menu items as text */
  async getThreeDotMenuItems(): Promise<string[]> {
    const menu = this.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    return menu.locator('.dropdown-item span').allTextContents();
  }

  /** Click a three-dot menu item by text */
  async clickThreeDotMenuItem(text: string) {
    const menu = this.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await menu.locator(`.dropdown-item:has-text("${text}")`).click();
    await this.page.waitForTimeout(200);
  }

  /** Get the sort header */
  getSortHeader(): Locator {
    return this.page.locator('.sort-header');
  }

  /** Click a sort column */
  async clickSortColumn(sortKey: 'name' | 'size' | 'modified') {
    await this.page.locator(`.sort-col[data-sort="${sortKey}"]`).click();
    await this.page.waitForTimeout(200);
  }

  /** Get active sort column key */
  async getActiveSort(): Promise<string | null> {
    const el = this.page.locator('.sort-col.active');
    return el.getAttribute('data-sort');
  }

  /** Get active sort direction */
  async getSortDirection(): Promise<'asc' | 'desc' | null> {
    const el = this.page.locator('.sort-col.active');
    const cls = await el.getAttribute('class');
    return cls?.includes('desc') ? 'desc' : cls?.includes('asc') ? 'asc' : null;
  }

  /** Get pagination info */
  async getPaginationInfo(): Promise<{ total: number; page: number; pages: number } | null> {
    return this.page.evaluate(() => {
      const el = document.getElementById('file-data');
      if (!el) return null;
      const data = JSON.parse(el.textContent || '{}');
      return data.pagination || null;
    });
  }

  /** Click a pagination page number by its URL */
  async goToPage(pageNum: number) {
    await this.page.locator(`.pagination-page:has-text("${pageNum}")`).click();
    await this.page.waitForLoadState('domcontentloaded');
  }

  /** Get current page number from pagination */
  async getCurrentPage(): Promise<number> {
    const el = this.page.locator('.pagination-current');
    const text = await el.innerText();
    return parseInt(text, 10);
  }

  /** Click next pagination button */
  async clickNextPage() {
    const btns = this.page.locator('.pagination-btn');
    const count = await btns.count();
    await btns.nth(count - 1).click(); // last btn is "next"
    await this.page.waitForLoadState('domcontentloaded');
  }

  /** Click prev pagination button */
  async clickPrevPage() {
    await this.page.locator('.pagination-btn').first().click();
    await this.page.waitForLoadState('domcontentloaded');
  }

  /** Get the theme toggle button */
  getThemeToggle(): Locator {
    return this.page.locator('#themeToggle');
  }

  /** Check current theme from data attribute */
  async getCurrentTheme(): Promise<string | null> {
    return this.page.locator('html').getAttribute('data-theme');
  }

  /** Get the search input */
  getSearchInput(): Locator {
    return this.page.locator('#search-input');
  }

  /** Type in search box */
  async search(query: string) {
    await this.getSearchInput().fill(query);
    await this.page.waitForTimeout(300);
  }

  /** Clear search */
  async clearSearch() {
    await this.page.locator('#search-clear').click();
    await this.page.waitForTimeout(200);
  }

  /** Check if search results info is visible */
  getSearchResultsInfo(): Locator {
    return this.page.locator('#search-results-info');
  }

  /** Open context menu (right-click) on file */
  async openContextMenu(itemName: string) {
    await this.getFileItem(itemName).click({ button: 'right' });
    await this.page.waitForTimeout(200);
  }

  /** Get context menu items */
  async getContextMenuItems(): Promise<string[]> {
    const menu = this.page.locator('#contextMenu');
    return menu.locator('.dropdown-item').allTextContents();
  }

  /** Get modal by ID */
  getModal(id: string): Locator {
    return this.page.locator(`#${id}`);
  }

  /** Wait for modal to be visible */
  async waitForModal(id: string) {
    await this.page.locator(`#${id}.visible`).waitFor({ timeout: 5000 });
  }
}
