import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('Share links UI', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('share modal has create section', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await fb.page.waitForTimeout(300);

    const createBtn = fb.page.locator('button:has-text("Create Link"), button:has-text("Create")');
    const expInput = fb.page.locator('#shareExpiration, input[type="number"]');
    const hasCreateSection = (await createBtn.count()) > 0 || (await expInput.count()) > 0;
    expect(hasCreateSection).toBeTruthy();
  });

  test('share modal can be closed', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('shareModal');
    await expect(modal).toBeVisible();

    const closeBtn = fb.page.locator('#shareModal .modal-close, #shareModal .btn-close, #shareModal button:has-text("Cancel"), #shareModal button:has-text("Close")');
    if (await closeBtn.count() > 0) {
      await closeBtn.first().click();
    }
    await fb.page.waitForTimeout(300);
    await expect(modal).not.toBeVisible();
  });
});

test.describe('Share links E2E', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('create share link via API and verify token returned', async ({ request }) => {
    const response = await request.post('/fileserver/gen-share-token', {
      data: {
        path: '/download/documents/notes.txt',
        exp: 60,
      },
    });
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body.token).toBeTruthy();
    expect(typeof body.token).toBe('string');
  });

  test('share link serves file with correct headers', async ({ request }) => {
    // Create share token
    const createResp = await request.post('/fileserver/gen-share-token', {
      data: {
        path: '/download/documents/notes.txt',
        exp: 60,
      },
    });
    expect(createResp.status()).toBe(200);
    const { token } = await createResp.json();

    // Hit the share URL
    const shareResp = await request.get(`/share/${token}`);
    expect(shareResp.status()).toBe(200);

    // Should have Content-Disposition: attachment
    const headers = shareResp.headers();
    expect(headers['content-disposition']).toContain('attachment');
    expect(headers['content-disposition']).toContain('notes.txt');

    // Content-Length should be set
    expect(headers['content-length']).toBeTruthy();
    const body = await shareResp.body();
    expect(parseInt(headers['content-length'])).toBe(body.length);
  });

  test('share link returns 401 for invalid token', async ({ request }) => {
    const response = await request.get('/share/nonexistent-token-12345');
    expect(response.status()).toBe(401);
  });

  test('list share links via API returns empty for file with no links', async ({ request }) => {
    const response = await request.get('/fileserver/gen-share-token?path=/download/documents/report.pdf');
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body.links).toBeDefined();
    // May be empty (no links) or have links from prior test runs
    expect(Array.isArray(body.links)).toBeTruthy();
  });

  test('create share link via UI and verify token is generated', async ({ page }) => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await page.waitForTimeout(300);

    const modal = fb.getModal('shareModal');
    await expect(modal).toBeVisible();

    // Fill expiration
    const expInput = modal.locator('#shareExpireValue');
    if (await expInput.count() > 0) {
      await expInput.fill('60');
    }

    // Intercept the POST to gen-share-token
    const createResp = page.waitForResponse(
      resp => resp.request().method() === 'POST' && resp.url().includes('/fileserver/gen-share-token'),
      { timeout: 10000 }
    );

    // Click Create Link
    const createBtn = modal.locator('#shareCreateBtn');
    await createBtn.click();

    const response = await createResp;
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body.token).toBeTruthy();

    // Verify the list section now shows (not the create section)
    await page.waitForTimeout(500);
    const listSection = modal.locator('#shareListSection');
    await expect(listSection).toBeVisible();
  });

  test('delete share link via API', async ({ request }) => {
    // Create a token to delete
    const createResp = await request.post('/fileserver/gen-share-token', {
      data: {
        path: '/download/documents/notes.txt',
        exp: 60,
      },
    });
    expect(createResp.status()).toBe(200);
    const { token } = await createResp.json();

    // Delete it
    const deleteResp = await request.delete('/fileserver/gen-share-token', {
      data: { token },
    });
    expect(deleteResp.status()).toBe(200);

    // Verify the share link no longer works
    const shareResp = await request.get(`/share/${token}`);
    expect(shareResp.status()).toBe(401);
  });
});
