import { test, expect, Page } from '@playwright/test';

const ADMIN_HEADERS = {
  'X-USER-NAME': 'Test Admin',
  'X-USER': 'test-admin',
  'X-USER-EMAIL': 'admin@test.local',
  'X-USER-GROUPS': 'fileserver_admin',
};

const CONFIG_URL = '/fileserver/housekeeping/config';

// The example from the feature request: all three 5.0.22 files share this key.
const PATTERN = '^.-%-%d+%.%d+%.%d+';

// Mirrors safeBtoa(): the tree keys nodes by base64 over the UTF-8 bytes.
const b64 = (s: string) => Buffer.from(s, 'utf8').toString('base64');
const toggleSel = (childPath: string) => `[id="toggle-${b64(childPath)}"]`;
const nodeNameSel = (childPath: string) => `[id="node-${b64(childPath)}"] > .tree-node-name`;

let originalConfig: any = null;

async function readConfig(page: Page) {
  const response = await page.request.get(CONFIG_URL, { headers: ADMIN_HEADERS });
  return response.json();
}

async function writeConfig(page: Page, config: any) {
  const current = await readConfig(page);
  const response = await page.request.post(CONFIG_URL, {
    headers: ADMIN_HEADERS,
    data: { ...config, version: current.version ?? 1 },
  });
  expect(response.ok()).toBeTruthy();
}

async function gotoHousekeeping(page: Page) {
  await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#mainTabs', { timeout: 10000 });
  await page.waitForFunction(() => {
    const spinner = document.getElementById('treeLoading');
    return spinner && spinner.classList.contains('d-none');
  }, { timeout: 10000 });
}

async function expandDownload(page: Page) {
  const dirs = page.waitForResponse(
    (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
    { timeout: 10000 },
  );
  await page.locator(toggleSel('download')).click();
  await dirs;
  await expect(page.locator(nodeNameSel('download/builds'))).toBeVisible();
}

async function selectBuilds(page: Page) {
  await expandDownload(page);
  await page.locator(nodeNameSel('download/builds')).click();
  await expect(page.locator('#groupModeInput')).toBeVisible();
}

const previewFixture = {
  ok: true,
  bucket: 'download',
  path: '/builds',
  pattern: PATTERN,
  pattern_source: 'override',
  keep_count: 50,
  keep_days: 0,
  total_files: 4,
  total_units: 2,
  truncated: false,
  units: [
    {
      key: 'MyApp-main-5.0.22',
      grouped: true,
      index: 1,
      newest: '2024-01-01 00:03',
      file_count: 3,
      size_total: 3,
      action: 'keep',
      files_truncated: false,
      files: [
        { name: 'MyApp-main-5.0.22-Appstore.ipa', size: 1, mtime: 1, modified: '2024-01-01 00:03' },
      ],
    },
    {
      key: 'notes.txt',
      grouped: false,
      index: 2,
      newest: '2024-06-01 00:01',
      file_count: 1,
      size_total: 5,
      action: 'keep',
      files_truncated: false,
      files: [{ name: 'notes.txt', size: 5, mtime: 2, modified: '2024-06-01 00:01' }],
    },
  ],
};

test.describe('Housekeeping build grouping', () => {
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders(ADMIN_HEADERS);

    const current = await readConfig(page);
    if (!originalConfig) {
      originalConfig = current;
    }

    await writeConfig(page, {
      download: { rules: [{ path: '/', keep_count: 50, keep_days: 0 }] },
      archive: { rules: [] },
      public: { rules: [] },
    });
  });

  test.afterAll(async ({ request }) => {
    if (!originalConfig) return;

    const response = await request.get(CONFIG_URL, { headers: ADMIN_HEADERS });
    const current = await response.json();
    await request.post(CONFIG_URL, {
      headers: ADMIN_HEADERS,
      data: { ...originalConfig, version: current.version ?? 1 },
    });
  });

  // The project requires an assertion that the page sends the right URL with
  // the right query parameters, and then renders the response.
  test('preview sends bucket, path and pattern, then renders the returned units', async ({ page }) => {
    let previewUrl = '';
    await page.route('**/fileserver/housekeeping/preview*', async (route) => {
      previewUrl = route.request().url();
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(previewFixture),
      });
    });

    await gotoHousekeeping(page);
    await selectBuilds(page);

    await page.selectOption('#groupModeInput', 'custom');
    await page.fill('#groupPatternInput', PATTERN);
    await page.locator('#editorContent button:has-text("Preview")').click();

    const panel = page.locator('#previewPanel');
    await expect(panel).toContainText('MyApp-main-5.0.22');
    await expect(panel).toContainText('notes.txt');
    await expect(panel.locator('.spinner-border')).toHaveCount(0);

    const url = new URL(previewUrl);
    expect(url.pathname).toContain('/fileserver/housekeeping/preview');
    expect(url.searchParams.get('bucket')).toBe('download');
    expect(url.searchParams.get('path')).toBe('/builds');
    expect(url.searchParams.get('pattern')).toBe(PATTERN);
  });

  test('preview groups the seeded build files on the real server', async ({ page }) => {
    await gotoHousekeeping(page);
    await selectBuilds(page);

    await page.selectOption('#groupModeInput', 'custom');
    await page.fill('#groupPatternInput', PATTERN);
    await page.locator('#editorContent button:has-text("Preview")').click();

    const panel = page.locator('#previewPanel');
    await expect(panel).toContainText('MyApp-main-5.0.22');
    await expect(panel).toContainText('5 files');
    await expect(panel).toContainText('3 units');
  });

  test('preview shows an empty state', async ({ page }) => {
    await page.route('**/fileserver/housekeeping/preview*', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          ...previewFixture,
          total_files: 0,
          total_units: 0,
          units: [],
        }),
      });
    });

    await gotoHousekeeping(page);
    await selectBuilds(page);
    await page.locator('#editorContent button:has-text("Preview")').click();

    await expect(page.locator('#previewPanel')).toContainText('No files in this directory.');
  });

  test('preview shows the server error', async ({ page }) => {
    await page.route('**/fileserver/housekeeping/preview*', async (route) => {
      await route.fulfill({
        status: 400,
        contentType: 'application/json',
        body: JSON.stringify({ ok: false, error: 'invalid group pattern: malformed pattern' }),
      });
    });

    await gotoHousekeeping(page);
    await selectBuilds(page);
    await page.locator('#editorContent button:has-text("Preview")').click();

    await expect(page.locator('#previewPanel .alert-danger'))
      .toContainText('invalid group pattern');
  });

  test('saves a custom override and reloads it', async ({ page }) => {
    await gotoHousekeeping(page);
    await selectBuilds(page);

    await page.selectOption('#groupModeInput', 'custom');
    await page.fill('#groupPatternInput', PATTERN);
    await page.locator('#editorContent button:has-text("Add Rule")').click();

    const saved = page.waitForRequest(
      (request) => request.url().includes('/fileserver/housekeeping/config') && request.method() === 'POST',
    );
    await page.locator('#saveButton').click();
    const body = (await saved).postDataJSON();
    const rule = body.download.rules.find((r: any) => r.path === '/builds');
    expect(rule.group_pattern).toBe(PATTERN);

    await expect(page.locator('#saveButton')).toBeDisabled();

    await page.reload({ waitUntil: 'domcontentloaded' });
    await selectBuilds(page);
    await expect(page.locator('#groupModeInput')).toHaveValue('custom');
    await expect(page.locator('#groupPatternInput')).toHaveValue(PATTERN);
  });

  test('distinguishes "no grouping" from "inherit global"', async ({ page }) => {
    await gotoHousekeeping(page);
    await selectBuilds(page);

    await page.selectOption('#groupModeInput', 'none');
    await page.locator('#editorContent button:has-text("Add Rule")').click();

    let saved = page.waitForRequest(
      (request) => request.url().includes('/fileserver/housekeeping/config') && request.method() === 'POST',
    );
    await page.locator('#saveButton').click();
    let body = (await saved).postDataJSON();
    let rule = body.download.rules.find((r: any) => r.path === '/builds');
    expect(rule.group_pattern).toBe('');

    await page.reload({ waitUntil: 'domcontentloaded' });
    await selectBuilds(page);
    await expect(page.locator('#groupModeInput')).toHaveValue('none');

    // Back to inherit: the key must disappear rather than become "".
    await page.selectOption('#groupModeInput', 'inherit');
    await page.locator('#editorContent button:has-text("Update")').click();

    saved = page.waitForRequest(
      (request) => request.url().includes('/fileserver/housekeeping/config') && request.method() === 'POST',
    );
    await page.locator('#saveButton').click();
    body = (await saved).postDataJSON();
    rule = body.download.rules.find((r: any) => r.path === '/builds');
    expect('group_pattern' in rule).toBe(false);
  });

  test('saves the global pattern, shows it as the inherit label, and Reset restores it', async ({ page }) => {
    await gotoHousekeeping(page);

    const input = page.locator('#globalGroupPatternInput');
    await expect(input).toHaveValue('');

    await input.fill(PATTERN);
    await expect(page.locator('#saveButton')).toBeEnabled();
    await expect(page.locator('#saveButton')).toHaveClass(/save-dirty/);

    const saved = page.waitForRequest(
      (request) => request.url().includes('/fileserver/housekeeping/config') && request.method() === 'POST',
    );
    await page.locator('#saveButton').click();
    const body = (await saved).postDataJSON();
    expect(body.group_pattern).toBe(PATTERN);

    await page.reload({ waitUntil: 'domcontentloaded' });
    await expect(page.locator('#globalGroupPatternInput')).toHaveValue(PATTERN);

    await selectBuilds(page);
    const inheritOption = page.locator('#groupModeInput option[value="inherit"]');
    await expect(inheritOption).toContainText('Inherit global');
    await expect(inheritOption).toContainText(PATTERN);

    await page.fill('#globalGroupPatternInput', '^other');
    await expect(page.locator('#saveButton')).toHaveClass(/save-dirty/);

    page.once('dialog', (dialog) => dialog.accept());
    await page.locator('#resetButton').click();

    await expect(page.locator('#globalGroupPatternInput')).toHaveValue(PATTERN);
    await expect(page.locator('#saveButton')).toBeDisabled();
  });
});
