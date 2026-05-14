import { Page, Locator } from '@playwright/test';
import { BasePage } from './BasePage';

export class UploadPage extends BasePage {
  constructor(page: Page) {
    super(page);
  }

  async gotoUpload() {
    await this.goto('/fileserver/upload.html');
  }

  getUploadArea(): Locator {
    return this.page.locator('#uploadArea');
  }

  getFileInput(): Locator {
    return this.page.locator('#fileInput');
  }

  async selectFiles(filePaths: string[]) {
    const [fileChooser] = await Promise.all([
      this.page.waitForEvent('filechooser'),
      this.getFileInput().click(),
    ]);
    await fileChooser.setFiles(filePaths);
  }

  async startUpload() {
    const uploadBtn = this.page.locator('button:has-text("Start Upload"), #uploadBtn');
    await uploadBtn.click();
  }

  getFileQueueItems(): Locator {
    return this.page.locator('.upload-file-item, .file-item');
  }

  async getUploadedFilesCount(): Promise<number> {
    const text = await this.page.locator('#uploadedFiles').innerText();
    return parseInt(text, 10) || 0;
  }
}
