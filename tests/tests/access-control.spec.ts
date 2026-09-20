import { test, expect, APIRequestContext } from '@playwright/test';

const ADMIN_HEADERS = {
  'X-USER-NAME': 'Test Admin',
  'X-USER': 'test-admin',
  'X-USER-EMAIL': 'admin@test.local',
  'X-USER-GROUPS': 'fileserver_admin',
};

const CONFIG_URL = '/fileserver/auth-config';
const ROLES_URL = '/fileserver/auth-config/roles';
const PAGE_URL = '/fileserver/access-control.html';

// The page saves the whole config, so any test that saves must put it back or it
// leaks into the next one.
let baseline: { version: number; rules: Record<string, unknown> } | null = null;

async function readConfig(request: APIRequestContext) {
  const response = await request.get(CONFIG_URL, { headers: ADMIN_HEADERS });
  expect(response.status()).toBe(200);
  return response.json();
}

async function restoreConfig(request: APIRequestContext) {
  if (!baseline) {
    return;
  }
  const current = await readConfig(request);
  await request.post(CONFIG_URL, {
    headers: ADMIN_HEADERS,
    data: { version: current.version, rules: baseline.rules },
  });
}

test.describe('Access control page', () => {
  test.beforeEach(async ({ page, request }) => {
    baseline = await readConfig(request);
    await page.setExtraHTTPHeaders(ADMIN_HEADERS);
  });

  test.afterEach(async ({ request }) => {
    await restoreConfig(request);
    baseline = null;
  });

  test('loads the config and lists configured roles with rule counts', async ({ page }) => {
    // The response promise must exist before the navigation that triggers it.
    const configResponse = page.waitForResponse(
      (response) => response.url().includes(CONFIG_URL) && response.status() === 200
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await configResponse;

    // The editor appears only once the config landed, so the spinner must be gone.
    await expect(page.locator('#loadingIndicator')).toBeHidden();
    await expect(page.locator('#contentSection')).toBeVisible();

    const configured = page.locator('#roleListConfigured .role-row');
    await expect(configured).toHaveCount(2);
    await expect(configured.filter({ hasText: '.default' })).toBeVisible();
    await expect(configured.filter({ hasText: 'fileserver_admin' })).toBeVisible();

    // The seeded config gives both roles three allow rules and no deny rules.
    await expect(page.locator('#roleListConfigured .role-row.active .count.allow')).toHaveText('3');
  });

  test('requests the role list without a refresh parameter', async ({ page }) => {
    const rolesRequest = page.waitForRequest((request) => request.url().includes(ROLES_URL));

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    const request = await rolesRequest;

    expect(request.method()).toBe('GET');
    expect(new URL(request.url()).searchParams.has('refresh')).toBe(false);
  });

  test('splits configured roles from other Keycloak roles', async ({ page }) => {
    await page.route(`**${ROLES_URL}`, (route) =>
      route.fulfill({
        json: {
          roles: [
            'auditors',
            'fileserver_admin',
            'guest',
            'admin',
            'create-realm',
            'offline_access',
            'default-roles-master',
          ],
          source: 'keycloak',
          degraded: false,
        },
      })
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#roleListConfigured .role-row')).toHaveCount(2);

    const other = page.locator('#roleListOther .role-row');
    await expect(other).toHaveCount(3); // admin, auditors, guest
    await expect(other.filter({ hasText: 'auditors' })).toBeVisible();
    await expect(other.filter({ hasText: 'guest' })).toBeVisible();

    // `admin` is a plausible name for a realm's own role, so it stays listed
    // rather than folded away with the built-ins.
    await expect(other.filter({ hasText: 'admin' })).toBeVisible();

    // Keycloak's built-in realm roles stay folded away until asked for.
    await expect(page.locator('#roleListOther')).not.toContainText('offline_access');
    await expect(page.locator('#roleListOther')).not.toContainText('create-realm');
    await expect(page.locator('#showAllRolesButton')).toContainText('3 more roles');

    await page.locator('#showAllRolesButton').click();
    await expect(page.locator('#roleListOther .role-row')).toHaveCount(6);
    await expect(page.locator('#roleListOther')).toContainText('create-realm');
  });

  test('degrades gracefully when the role list is unavailable', async ({ page }) => {
    // This is the real state of the test environment: OIDC is not configured.
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });

    await expect(page.locator('#rolesDegradedNotice')).toBeVisible();
    await expect(page.locator('#rolesDegradedNotice')).toContainText('unavailable');

    // Configured roles still render and the editor still works.
    await expect(page.locator('#roleListConfigured .role-row')).toHaveCount(2);
    await page.locator('#addAllowRuleButton').click();
    await page.locator('#rulePath').fill('/download/documents');
    await page.locator('#ruleSaveButton').click();
    await expect(page.locator('#saveButton')).toBeEnabled();
  });

  test('selecting a role issues no further requests', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    let requests = 0;
    page.on('request', (request) => {
      if (request.url().includes(CONFIG_URL)) {
        requests++;
      }
    });

    await page.locator('#roleListConfigured .role-row', { hasText: 'fileserver_admin' }).click();

    await expect(page.locator('#rulesTitle')).toHaveText('fileserver_admin');
    expect(requests).toBe(0);
  });

  test('adds a rule by hand, staging it without saving', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    let posts = 0;
    page.on('request', (request) => {
      if (request.method() === 'POST' && request.url().includes(CONFIG_URL)) {
        posts++;
      }
    });

    await page.locator('#addAllowRuleButton').click();
    await expect(page.locator('#ruleModal')).toBeVisible();
    await page.locator('#rulePath').fill('/download/not-yet-on-disk');
    await page.locator('#ruleSaveButton').click();

    const rows = page.locator('#allowTable .rule-row');
    await expect(rows).toHaveCount(4);
    await expect(rows.last()).toContainText('/download/not-yet-on-disk');
    await expect(page.locator('#allowCount')).toHaveText('4 rules');

    await expect(page.locator('#saveButton')).toBeEnabled();
    await expect(page.locator('#saveButton')).toHaveClass(/save-dirty/);
    expect(posts).toBe(0);
  });

  test('adds a deny rule to a role whose config entry has only allow', async ({ page }) => {
    // The saved config does not guarantee both lists. A role written by hand, or
    // by an older build, can carry `allow` alone — the deployed ci config does
    // exactly this. renderRulesPanel and validateBeforeSave both tolerate it, but
    // submitRule dereferenced the missing list and threw inside its own click
    // handler: no dialog error, no staged row, no toast. Nothing happened.
    await page.route(`**${CONFIG_URL}`, (route) =>
      route.fulfill({
        json: {
          version: 1,
          rules: {
            '.default': { allow: [], deny: [] },
            auditors: { allow: ['read:/download'] },
          },
        },
      })
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    await page.locator('#roleListConfigured .role-row', { hasText: 'auditors' }).click();
    await expect(page.locator('#rulesTitle')).toHaveText('auditors');

    await page.locator('#addDenyRuleButton').click();
    await expect(page.locator('#ruleModal')).toBeVisible();
    await page.locator('#rulePath').fill('/download/blocked');
    await page.locator('#ruleSaveButton').click();

    const rows = page.locator('#denyTable .rule-row');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText('/download/blocked');
    // The dialog closed, so the add actually completed rather than silently dying.
    await expect(page.locator('#ruleModal')).toBeHidden();
  });

  test('adds a rule to a role that has no entry in the config yet', async ({ page }) => {
    // "Other roles" are clickable, and renderRulesPanel draws them through its
    // `|| { allow: [], deny: [] }` fallback, so the panel looks completely normal
    // while state.rules[role] does not exist at all. Selecting one and clicking
    // Add rule then threw for the same reason as the missing-list case above.
    await page.route(`**${ROLES_URL}`, (route) =>
      route.fulfill({
        json: { roles: ['fileserver_admin', 'jenkins_admin'], source: 'keycloak', degraded: false },
      })
    );
    await page.route(`**${CONFIG_URL}`, (route) =>
      route.fulfill({
        json: {
          version: 1,
          rules: {
            '.default': { allow: [], deny: [] },
            fileserver_admin: { allow: [], deny: [] },
          },
        },
      })
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    // jenkins_admin is in Keycloak but not in the config, so it lands in the
    // "other roles" list.
    await page.locator('#roleListOther .role-row', { hasText: 'jenkins_admin' }).click();
    await expect(page.locator('#rulesTitle')).toHaveText('jenkins_admin');

    await page.locator('#addAllowRuleButton').click();
    await expect(page.locator('#ruleModal')).toBeVisible();
    await page.locator('#rulePath').fill('/download/from-keycloak-role');
    await page.locator('#ruleSaveButton').click();

    const rows = page.locator('#allowTable .rule-row');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText('/download/from-keycloak-role');
    await expect(page.locator('#ruleModal')).toBeHidden();
    await expect(page.locator('#saveButton')).toHaveClass(/save-dirty/);
  });

  test('normalises a role with no lists, so the server accepts the save', async ({ page }) => {
    // validate_config in lua/auth-config.lua requires BOTH lists on every role,
    // even empty; a role whose entry is {} is rejected with "Missing allow rules
    // for group <role>". Nothing else cares, so a hand-written config loads
    // perfectly and then cannot be saved from ANY role — the POST carries the
    // whole config, so one broken role blocks every save and the error names a
    // role the user never touched. The deployed config is exactly this shape:
    // {".default": {}, "fileserver_admin": {"allow": [...]}}.
    await page.route(`**${CONFIG_URL}`, (route) =>
      route.fulfill({
        // The real version, or the save would be rejected as stale before it
        // ever reached the shape check.
        json: {
          version: baseline!.version,
          rules: {
            '.default': {},
            auditors: { allow: ['read:/download'] },
          },
        },
      })
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    await page.locator('#roleListConfigured .role-row', { hasText: 'auditors' }).click();
    await page.locator('#addDenyRuleButton').click();
    await page.locator('#rulePath').fill('/download/blocked');
    await page.locator('#ruleSaveButton').click();
    await expect(page.locator('#denyTable .rule-row')).toHaveCount(1);

    const saveRequest = page.waitForRequest(
      (request) => request.method() === 'POST' && request.url().includes(CONFIG_URL)
    );
    const saveResponse = page.waitForResponse(
      (response) => response.url().includes(CONFIG_URL) && response.request().method() === 'POST'
    );
    await page.locator('#saveButton').click();

    const body = JSON.parse((await saveRequest).postData() || '{}');

    // The role the user never touched is sent with both lists, not as {}.
    expect(body.rules['.default']).toEqual({ allow: [], deny: [] });
    // And the role they did touch keeps what it had, plus the new rule.
    expect(body.rules.auditors.allow).toEqual(['read:/download']);
    expect(body.rules.auditors.deny).toEqual(['all:/download/blocked']);

    const response = await saveResponse;
    expect(response.status()).toBe(200);

    // No "Could not save" banner, and the edit is adopted rather than left pending.
    await expect(page.locator('#notificationAlert')).toBeHidden();
    await expect(page.locator('#saveButton')).toBeDisabled();
  });

  test('rejects a path without a leading slash', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    await page.locator('#addAllowRuleButton').click();
    await page.locator('#rulePath').fill('download/documents');
    await page.locator('#ruleSaveButton').click();

    await expect(page.locator('#rulePathError')).toContainText("must start with '/'");
    await expect(page.locator('#ruleModal')).toBeVisible();
    await expect(page.locator('#saveButton')).toBeDisabled();
  });

  test('rejects a duplicate rule', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    await page.locator('#addAllowRuleButton').click();
    // .default already has "all:/download", so match both halves.
    await page.locator('#ruleOp').selectOption('all');
    await page.locator('#rulePath').fill('/download');
    await page.locator('#ruleSaveButton').click();

    await expect(page.locator('#rulePathError')).toContainText('already exists');
    await expect(page.locator('#allowTable .rule-row')).toHaveCount(3);
  });

  test('saves the config and sends the version it loaded', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    const loaded = await readConfig(page.request);

    await page.locator('#addAllowRuleButton').click();
    await page.locator('#rulePath').fill('/download/documents');
    await page.locator('#ruleSaveButton').click();

    const saveRequest = page.waitForRequest(
      (request) => request.method() === 'POST' && request.url().includes(CONFIG_URL)
    );
    await page.locator('#saveButton').click();
    const request = await saveRequest;

    const body = JSON.parse(request.postData() || '{}');
    expect(body.version).toBe(loaded.version);
    expect(body.rules['.default'].allow).toContain('read:/download/documents');

    // The response is adopted: nothing is left pending.
    await expect(page.locator('#saveButton')).toBeDisabled();
    await expect(page.locator('#saveButton')).not.toHaveClass(/save-dirty/);

    const persisted = await readConfig(page.request);
    expect(persisted.version).toBe(loaded.version + 1);
    expect(persisted.rules['.default'].allow).toContain('read:/download/documents');
  });

  test('server rejects an operation the matcher does not implement', async ({ request }) => {
    const current = await readConfig(request);

    const response = await request.post(CONFIG_URL, {
      headers: ADMIN_HEADERS,
      data: {
        version: current.version,
        rules: { guest: { allow: ['write:/download'], deny: [] } },
      },
    });

    expect(response.status()).toBe(400);
    const body = await response.json();
    // The message must name the problem: the body is the whole config, so one
    // bad rule blocks every save until it is found.
    expect(body.error).toContain('write');
    expect(body.error).toContain('read, all');
  });

  test('server rejects a stale version with a JSON body', async ({ request }) => {
    const current = await readConfig(request);

    const response = await request.post(CONFIG_URL, {
      headers: ADMIN_HEADERS,
      data: { version: current.version + 99, rules: current.rules },
    });

    expect(response.status()).toBe(409);
    expect((await response.json()).error).toBeTruthy();
  });

  test('shows a conflict dialog instead of discarding unsaved edits', async ({ page, request }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    // Stage an edit, then let someone else save behind the page's back.
    await page.locator('#addAllowRuleButton').click();
    await page.locator('#rulePath').fill('/download/documents');
    await page.locator('#ruleSaveButton').click();

    const current = await readConfig(request);
    await request.post(CONFIG_URL, {
      headers: ADMIN_HEADERS,
      data: {
        version: current.version,
        rules: { ...current.rules, intruder: { allow: ['read:/public'], deny: [] } },
      },
    });

    await page.locator('#saveButton').click();

    await expect(page.locator('#conflictModal')).toBeVisible();
    // The staged row survives — no silent reload.
    await expect(page.locator('#allowTable .rule-row')).toHaveCount(4);
    await expect(page.locator('#saveButton')).toHaveClass(/save-dirty/);
  });

  test('closes the rule dialog when Save lands while it is still opening', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    // Bootstrap ignores Modal.hide() until a dialog has finished opening, so a
    // Save clicked inside that window used to be dropped and the dialog stayed
    // open for good. At real speed that window is ~300ms, so a normal click lands
    // after it and the race fires only on a slow machine — no use as a test.
    // Driving the open and the Save in a single tick puts the Save inside the
    // window every time.
    //
    // The assertion deliberately is not "the dialog is hidden": it is hidden
    // while it is still opening, so that passes even when the close was dropped
    // — which is exactly how this test first passed against the bug. The dialog's
    // own hidden event is the only signal that it actually closed.
    await page.evaluate(() => {
      (window as any).__modalEvents = [];
      const el = document.getElementById('ruleModal')!;
      el.addEventListener('shown.bs.modal', () => (window as any).__modalEvents.push('shown'));
      el.addEventListener('hidden.bs.modal', () => (window as any).__modalEvents.push('hidden'));

      document.getElementById('addAllowRuleButton')!.click();
      (document.getElementById('rulePath') as HTMLInputElement).value = '/download/fast-save';
      document.getElementById('ruleSaveButton')!.click();
    });

    // The rule is staged either way...
    await expect(page.locator('#allowTable .rule-row')).toHaveCount(4);
    // ...and the dialog must still close. Without the fix the close is dropped,
    // hidden never arrives, and this times out.
    await page.waitForFunction(
      () => (window as any).__modalEvents.includes('hidden'),
      undefined,
      { timeout: 5000 }
    );
  });

  test('protects .default and the admin role', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    // .default is selected first and cannot be deleted.
    await expect(page.locator('#rulesTitle')).toHaveText('.default');
    await expect(page.locator('#deleteRoleButton')).toBeHidden();

    await page.locator('#roleListConfigured .role-row', { hasText: 'fileserver_admin' }).click();
    await expect(page.locator('#deleteRoleButton')).toBeVisible();
    // Admins are warned that this role is what grants access to the page.
    await expect(page.locator('#adminWarning')).toBeVisible();
  });

  test('warns when .default has no rules', async ({ page, request }) => {
    const current = await readConfig(request);
    await request.post(CONFIG_URL, {
      headers: ADMIN_HEADERS,
      data: { version: current.version, rules: { '.default': { allow: [], deny: [] } } },
    });

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#defaultWarning')).toBeVisible();
    await expect(page.locator('#defaultWarning')).toContainText('denied everything');
  });

  test('scrolls a long role list rather than clipping it', async ({ page }) => {
    const many = Array.from({ length: 40 }, (_, i) => `team-${String(i).padStart(2, '0')}`);
    await page.route(`**${ROLES_URL}`, (route) =>
      route.fulfill({ json: { roles: many, source: 'keycloak', degraded: false } })
    );

    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#roleListOther .role-row')).toHaveCount(40);

    // The panel is the scroll container, so its content must exceed its box.
    const panel = page.locator('.role-list');
    expect(await panel.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);

    // Nothing may spill past the viewport. body is overflow: hidden at this
    // width, so a document taller than the window means content is unreachable
    // rather than merely scrollable — which is the bug this guards.
    expect(
      await page.evaluate(() => document.documentElement.scrollHeight > window.innerHeight)
    ).toBe(false);

    // The last role is reachable by scrolling the panel itself.
    await panel.evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });
    await expect(page.locator('#roleListOther .role-row').last()).toBeInViewport();
  });

  test('scrolls a long rules list rather than clipping it', async ({ page, request }) => {
    const current = await readConfig(request);
    const allow = Array.from({ length: 30 }, (_, i) => `all:/download/folder-${i}`);
    const deny = Array.from({ length: 30 }, (_, i) => `write:/archive/folder-${i}`);
    await request.post(CONFIG_URL, {
      headers: ADMIN_HEADERS,
      data: {
        version: current.version,
        rules: { ...current.rules, auditors: { allow, deny } },
      },
    });

    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });

    await page.locator('#roleListConfigured .role-row').filter({ hasText: 'auditors' }).click();
    await expect(page.locator('#allowTable')).toBeVisible();
    await expect(page.locator('#allowTable tbody tr')).toHaveCount(30);
    await expect(page.locator('#denyTable tbody tr')).toHaveCount(30);

    // The rules panel is the scroll container, so its content must exceed its box.
    const body = page.locator('.rules-body');
    expect(await body.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);

    // Nothing may spill past the viewport: body is overflow: hidden at this width.
    expect(
      await page.evaluate(() => document.documentElement.scrollHeight > window.innerHeight)
    ).toBe(false);

    // Distance from the top of the panel, which is where a pinned header sits.
    const headOffsets = () =>
      page.evaluate(() => {
        const panel = document.querySelector('.rules-body')!;
        const panelTop = panel.getBoundingClientRect().top;
        return [...panel.querySelectorAll('.section-head')].map((head) =>
          Math.round(head.getBoundingClientRect().top - panelTop)
        );
      });

    // Partway into ALLOW its head stays pinned, keeping the label and the Add
    // button in reach.
    await body.evaluate((el) => {
      el.scrollTop = 400;
    });
    expect((await headOffsets())[0]).toBeLessThanOrEqual(16);
    await expect(page.locator('#addAllowRuleButton')).toBeInViewport();

    // Scrolled into DENY, its head pins in turn and ALLOW's is pushed out.
    await body.evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });
    const [allowOffset, denyOffset] = await headOffsets();
    expect(denyOffset).toBeLessThanOrEqual(16);
    expect(allowOffset).toBeLessThan(0);

    // The last deny rule is reachable by scrolling the panel itself.
    await expect(page.locator('#denyTable tbody tr').last()).toBeInViewport();
  });

  test('filters the role list as you type', async ({ page }) => {
    await page.route(`**${ROLES_URL}`, (route) =>
      route.fulfill({ json: { roles: ['auditors', 'guest'], source: 'keycloak', degraded: false } })
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#roleListOther .role-row')).toHaveCount(2);

    await page.locator('#roleSearch').fill('audit');
    await expect(page.locator('#roleListOther .role-row')).toHaveCount(1);
    await expect(page.locator('#roleListOther')).toContainText('auditors');

    await page.locator('#roleSearch').fill('');
    await expect(page.locator('#roleListOther .role-row')).toHaveCount(2);
  });

  test('flags a configured role that Keycloak does not have', async ({ page }) => {
    await page.route(`**${ROLES_URL}`, (route) =>
      route.fulfill({ json: { roles: ['auditors'], source: 'keycloak', degraded: false } })
    );

    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });

    // fileserver_admin is configured but absent from this role list, so its
    // rules can never match at runtime.
    const adminRow = page.locator('#roleListConfigured .role-row', { hasText: 'fileserver_admin' });
    await expect(adminRow).toContainText('not in Keycloak');
  });

  test('normalises a sloppy path with repeated slashes', async ({ request }) => {
    const response = await request.get(`${CONFIG_URL}/dirs?path=/download//documents`, {
      headers: ADMIN_HEADERS,
    });
    expect(response.status()).toBe(200);
  });

  test('requires the admin role on both new endpoints', async ({ playwright }) => {
    const anonymous = await playwright.request.newContext({ baseURL: test.info().project.use.baseURL });

    expect((await anonymous.get(ROLES_URL)).status()).toBe(403);
    expect((await anonymous.get(`${CONFIG_URL}/dirs?path=/download`)).status()).toBe(403);

    await anonymous.dispose();
  });

  test('rejects paths outside the buckets', async ({ request }) => {
    for (const path of ['/etc/passwd', '/download/../../etc', '/internal-download']) {
      const response = await request.get(`${CONFIG_URL}/dirs?path=${encodeURIComponent(path)}`, {
        headers: ADMIN_HEADERS,
      });
      expect(response.status(), `expected 400 for ${path}`).toBe(400);
      expect((await response.json()).error).toBeTruthy();
    }
  });

  test('renders the bucket roots without any request', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    const dirsRequests: string[] = [];
    page.on('request', (request) => {
      if (request.url().includes('/dirs')) {
        dirsRequests.push(request.url());
      }
    });

    await page.locator('#addAllowRuleButton').click();

    const roots = page.locator('#pickerTree > .tree-node');
    await expect(roots).toHaveCount(3);
    await expect(roots.nth(0)).toContainText('download');
    await expect(roots.nth(1)).toContainText('public');
    await expect(roots.nth(2)).toContainText('archive');

    // The three roots are synthetic; nothing is fetched until one expands.
    await page.waitForTimeout(300);
    expect(dirsRequests).toEqual([]);
  });

  test('expands a folder with the right query and fills the path from it', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    await page.locator('#addAllowRuleButton').click();

    // The response promise is created before the click that triggers it.
    const dirsResponse = page.waitForResponse(
      (response) => response.url().includes('/dirs') && response.status() === 200
    );
    await page.locator('#pickerTree .tree-node[data-path="/download"] .tree-toggle').click();
    await dirsResponse;

    const documents = page.locator('.tree-node[data-path="/download/documents"]');
    await expect(documents).toBeVisible();

    // The non-ASCII fixture proves UTF-8 survives ids, JSON and query encoding.
    await expect(page.locator('.tree-node[data-path="/download/测试目录"]')).toBeVisible();

    await documents.click();

    // The path is the server's, used verbatim — not reconstructed from parts.
    await expect(page.locator('#rulePath')).toHaveValue('/download/documents');
    // Picking a folder must not submit.
    await expect(page.locator('#ruleModal')).toBeVisible();
    await expect(page.locator('#saveButton')).toBeDisabled();
  });

  test('sends the expanded path as a query parameter', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();
    await page.locator('#addAllowRuleButton').click();

    const dirsRequest = page.waitForRequest((request) => request.url().includes('/dirs'));
    await page.locator('#pickerTree .tree-node[data-path="/download"] .tree-toggle').click();
    const request = await dirsRequest;

    expect(new URL(request.url()).searchParams.get('path')).toBe('/download');
    expect(new URL(request.url()).pathname).toBe('/fileserver/auth-config/dirs');
  });

  test('reveals the folder of an existing rule when editing', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();

    await page.locator('#allowTable .rule-row').first().locator('button[data-action="edit"]').click();

    // The rule is /download, so the download root is revealed and selected.
    await expect(page.locator('.tree-node[data-path="/download"]')).toHaveClass(/active/);
    await expect(page.locator('#rulePath')).toHaveValue('/download');
  });

  test('supports keyboard navigation in the picker', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();
    await page.locator('#addAllowRuleButton').click();

    // Opening focuses the path field; wait for that so it cannot steal focus
    // back after the tree node below is focused.
    await expect(page.locator('#rulePath')).toBeFocused();

    const root = page.locator('#pickerTree .tree-node').first();
    await root.focus();

    await page.keyboard.press('ArrowDown');
    await expect(page.locator('#pickerTree .tree-node[data-path="/public"]')).toBeFocused();

    await page.keyboard.press('ArrowUp');
    await expect(page.locator('#pickerTree .tree-node[data-path="/download"]')).toBeFocused();

    await page.keyboard.press('ArrowRight'); // expand
    await expect(page.locator('.tree-node[data-path="/download"]')).toHaveAttribute('aria-expanded', 'true');
    await expect(page.locator('.tree-node[data-path="/download/documents"]')).toBeVisible();

    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('Enter');
    await expect(page.locator('#rulePath')).toHaveValue('/download/archives');

    await page.locator('.tree-node[data-path="/download"]').focus();
    await page.keyboard.press('ArrowLeft');
    await expect(page.locator('.tree-node[data-path="/download"]')).toHaveAttribute('aria-expanded', 'false');
  });

  test('reports a failed folder listing inline', async ({ page }) => {
    await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#contentSection')).toBeVisible();
    await page.locator('#addAllowRuleButton').click();

    await page.route('**/auth-config/dirs**', (route) =>
      route.fulfill({ status: 400, json: { error: 'Path is outside the allowed buckets' } })
    );

    await page.locator('#pickerTree .tree-node[data-path="/public"] .tree-toggle').click();

    await expect(page.locator('#pickerTree .tree-empty')).toContainText('outside the allowed buckets');
    // The node collapses back so it can be retried.
    await expect(page.locator('.tree-node[data-path="/public"]')).toHaveAttribute('aria-expanded', 'false');
  });

  test('lists bucket subdirectories', async ({ request }) => {
    const response = await request.get(`${CONFIG_URL}/dirs?path=/download`, {
      headers: ADMIN_HEADERS,
    });
    expect(response.status()).toBe(200);

    const entries = await response.json();
    const names = entries.map((entry: { name: string }) => entry.name);
    expect(names).toEqual([...names].sort());
    expect(names).toContain('documents');
    expect(names).toContain('测试目录');

    // Paths come back ready to use, already carrying the URL prefix.
    const documents = entries.find((entry: { name: string }) => entry.name === 'documents');
    expect(documents.path).toBe('/download/documents');
  });
});
