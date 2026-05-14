import { test, expect } from '@playwright/test';

test.describe('Admin pages', () => {
  // Admin pages need X-USER-GROUPS header set
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders({
      'X-USER-NAME': 'Test Admin',
      'X-USER': 'test-admin',
      'X-USER-EMAIL': 'admin@test.local',
      'X-USER-GROUPS': '/fileserver-admin',
    });
  });

  test('access token page loads', async ({ page }) => {
    await page.goto('/fileserver/access-token.html', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(500);
    // Page title or form should be visible
    const content = await page.content();
    expect(content).toBeTruthy();
    expect(content.toLowerCase()).toMatch(/token|access/i);
  });

  test('access control page loads', async ({ page }) => {
    await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(500);
    const content = await page.content();
    expect(content).toBeTruthy();
  });

  test('share links admin page loads', async ({ page }) => {
    await page.goto('/fileserver/share-links.html', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(500);
    const content = await page.content();
    expect(content).toBeTruthy();
  });

  test('userinfo returns valid JSON response', async ({ page }) => {
    const response = await page.goto('/fileserver/userinfo', { waitUntil: 'domcontentloaded' });
    const json = await response?.json();
    expect(json).toHaveProperty('username');
    expect(typeof json.isAdmin).toBe('boolean');
  });
});

test.describe('Admin pages without auth', () => {
  test('userinfo shows guest without admin headers', async ({ page }) => {
    const response = await page.goto('/fileserver/userinfo', { waitUntil: 'domcontentloaded' });
    const json = await response?.json();
    expect(json).toHaveProperty('isAdmin', false);
  });
});
