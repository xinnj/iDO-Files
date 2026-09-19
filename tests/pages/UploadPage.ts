import { Page, Locator, FileChooser } from '@playwright/test';
import { BasePage } from './BasePage';

export class UploadPage extends BasePage {
  constructor(page: Page) {
    super(page);
  }

  async gotoUpload() {
    await this.goto('/fileserver/upload.html');
  }

  /**
   * Navigate to the upload page with a referer, which is how the page learns
   * which directory to upload into (see the `upload_to` / referrer logic in
   * upload.html's DOMContentLoaded handler).
   */
  async gotoUploadTo(refererPath: string) {
    await this.page.goto('/fileserver/upload.html', {
      referer: `http://localhost:8080${refererPath}`,
    });
    await this.page.waitForTimeout(500);
  }

  getUploadArea(): Locator {
    return this.page.locator('#uploadArea');
  }

  getFileInput(): Locator {
    return this.page.locator('#fileInput');
  }

  /**
   * Opens the file chooser via the visible "Select Files" button and sets the
   * given files. The hidden #fileInput cannot be clicked directly because it is
   * `display: none`.
   */
  async selectFiles(files: Parameters<FileChooser['setFiles']>[0]) {
    const [fileChooser] = await Promise.all([
      this.page.waitForEvent('filechooser'),
      this.page.locator('button:has-text("Select Files")').click(),
    ]);
    await fileChooser.setFiles(files);
  }

  /**
   * The main action button. Its label changes with state ("Start Upload" /
   * "Uploading..." / "Retry remaining (N)"), so always target the stable id
   * rather than the text.
   */
  getUploadButton(): Locator {
    return this.page.locator('#uploadButton');
  }

  async startUpload() {
    await this.getUploadButton().click();
  }

  getSessionAlert(): Locator {
    return this.page.locator('#sessionAlert');
  }

  getLoginLink(): Locator {
    return this.page.locator('#sessionLoginLink');
  }

  getFileItemsByStatus(status: string): Locator {
    return this.page.locator(`.status-${status}`);
  }

  async getStats(): Promise<Record<string, string>> {
    const read = async (id: string) =>
      (await this.page.locator(`#${id}`).innerText()).trim();
    return {
      total: await read('totalFiles'),
      uploaded: await read('uploadedFiles'),
      success: await read('successFiles'),
      errors: await read('errorFiles'),
    };
  }

  getFileQueueItems(): Locator {
    return this.page.locator('.upload-file-item, .file-item');
  }

  async getUploadedFilesCount(): Promise<number> {
    const text = await this.page.locator('#uploadedFiles').innerText();
    return parseInt(text, 10) || 0;
  }
}
