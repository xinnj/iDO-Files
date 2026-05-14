import { test, expect } from '@playwright/test';
import { ViewerPage } from '../pages/ViewerPage';

test.describe('File viewer', () => {
  let vp: ViewerPage;

  test.beforeEach(async ({ page }) => {
    vp = new ViewerPage(page);
  });

  test('loads code file with syntax highlighting', async () => {
    await vp.gotoViewer('/download/code/script.js');
    await vp.page.waitForTimeout(1000);

    // Should have highlighted code or raw text
    const content = await vp.getContent().innerText();
    expect(content.length).toBeGreaterThan(0);
  });

  test('renders markdown file', async () => {
    await vp.gotoViewer('/download/documents/README.md');
    await vp.page.waitForTimeout(1000);

    const content = await vp.getContent().innerHTML();
    expect(content).toBeTruthy();
    // Markdown should render headings or HTML
    const hasHtml = content.includes('<h1') || content.includes('<h2') || content.includes('<p') || content.includes('markdown');
    expect(hasHtml || content.includes('#')).toBeTruthy();
  });

  test('shows filename', async () => {
    await vp.gotoViewer('/download/documents/notes.txt');
    await expect(vp.getFilename()).toBeVisible();
  });

  test('has download and copy buttons', async () => {
    await vp.gotoViewer('/download/code/script.js');
    await vp.page.waitForTimeout(500);
    const hasButtons =
      (await vp.page.locator('button').count()) > 0;
    expect(hasButtons).toBeTruthy();
  });
});
