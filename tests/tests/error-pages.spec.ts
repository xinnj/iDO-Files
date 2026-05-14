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
});
