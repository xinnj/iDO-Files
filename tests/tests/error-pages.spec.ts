import { test, expect } from '@playwright/test';

test.describe('Error pages', () => {
  test('401 page loads', async ({ page }) => {
    const response = await page.goto('/fileserver/401.html', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(200);
    const body = await page.content();
    expect(body).toBeTruthy();
  });

  test('403 page loads', async ({ page }) => {
    const response = await page.goto('/fileserver/403.html', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(200);
    const body = await page.content();
    expect(body).toBeTruthy();
  });

  test('429 page loads', async ({ page }) => {
    const response = await page.goto('/fileserver/429.html', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(200);
    const body = await page.content();
    expect(body).toBeTruthy();
  });

  test('health endpoint returns healthy', async ({ request }) => {
    const response = await request.get('/health');
    expect(response.ok()).toBeTruthy();
    const body = await response.text();
    expect(body).toContain('healthy');
  });

  test('non-existent path returns 404', async ({ request }) => {
    const response = await request.get('/nonexistent/path/xyz');
    expect(response.status()).toBe(404);
  });

  test('fileserver static assets are served', async ({ request }) => {
    const response = await request.get('/fileserver/css/styles.css');
    expect(response.status()).toBe(200);
  });

  test('buckets are accessible when auth is not required', async ({ request }) => {
    // With AUTH_REQUIRED=false, all buckets should be reachable
    for (const bucket of ['download', 'public', 'archive']) {
      const response = await request.get(`/${bucket}/`);
      expect(response.status()).toBe(200);
    }
  });
});
