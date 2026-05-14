import { Page, Locator } from '@playwright/test';
import { BasePage } from './BasePage';

export class ViewerPage extends BasePage {
  constructor(page: Page) {
    super(page);
  }

  async gotoViewer(fileUrl: string) {
    await this.goto(`/fileserver/viewer?url=${encodeURIComponent(fileUrl)}`);
  }

  getContent(): Locator {
    return this.page.locator('#content');
  }

  getFilename(): Locator {
    return this.page.locator('#filename');
  }

  async clickCopy() {
    await this.page.locator('button:has-text("Copy"), #copyBtn').click();
  }

  async clickDownload() {
    await this.page.locator('button:has-text("Download"), #downloadBtn').click();
  }
}
