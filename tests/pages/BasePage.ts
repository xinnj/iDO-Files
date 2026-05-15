import { Page, Locator } from '@playwright/test';

export class BasePage {
  constructor(protected page: Page) {}

  async goto(path: string) {
    await this.page.goto(path, { waitUntil: 'domcontentloaded' });
    await this.page.waitForTimeout(500);
  }

  async waitForToast(type: 'success' | 'error' | 'info' | 'warning' = 'success') {
    const toast = this.page.locator('.toast');
    await toast.waitFor({ state: 'visible', timeout: 8000 });
    return toast;
  }

  getToast(): Locator {
    return this.page.locator('.toast');
  }
}
