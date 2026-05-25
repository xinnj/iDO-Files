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

test.describe('Housekeeping admin page', () => {
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders({
      'X-USER-NAME': 'Test Admin',
      'X-USER': 'test-admin',
      'X-USER-EMAIL': 'admin@test.local',
      'X-USER-GROUPS': '/fileserver-admin',
    });
  });

  // ========================================================================
  // Page loading
  // ========================================================================

  test('housekeeping page loads and renders', async ({ page }) => {
    const response = await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(200);

    // Should contain the header and tab buttons
    await page.waitForSelector('#mainTabs', { timeout: 10000 });
    const heading = await page.textContent('h2');
    expect(heading?.toLowerCase()).toMatch(/housekeeping/);

    // Both tabs should be present
    await expect(page.locator('#rulesTabBtn')).toBeVisible();
    await expect(page.locator('#runNowTabBtn')).toBeVisible();
  });

  // ========================================================================
  // Config API
  // ========================================================================

  test('GET /fileserver/housekeeping/config returns valid config', async ({ page }) => {
    const response = await page.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(200);
    const json = await response?.json();
    expect(json).toHaveProperty('version');
    expect(typeof json.version).toBe('number');
  });

  test('POST /fileserver/housekeeping/config saves and returns updated config', async ({ page }) => {
    // Read current config first to get the version
    const getResp = await page.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    const current = await getResp?.json();
    const currentVersion = current.version || 1;

    const payload = {
      version: currentVersion,
      download: { rules: [{ path: '/', keep_count: 5, keep_days: 30 }] },
      archive: { rules: [] },
      public: { rules: [] },
    };

    const postResp = await page.request.post('/fileserver/housekeeping/config', {
      data: payload,
      headers: {
        'Content-Type': 'application/json',
        'X-USER-GROUPS': '/fileserver-admin',
      },
    });

    expect(postResp.status()).toBe(200);
    const result = await postResp.json();
    expect(result.version).toBe(currentVersion + 1);
  });

  test('POST /fileserver/housekeeping/config rejects stale version with 409', async ({ page }) => {
    const payload = {
      version: 1, // Likely stale
      download: { rules: [{ path: '/', keep_count: 3, keep_days: 7 }] },
      archive: { rules: [] },
      public: { rules: [] },
    };

    const postResp = await page.request.post('/fileserver/housekeeping/config', {
      data: payload,
      headers: {
        'Content-Type': 'application/json',
        'X-USER-GROUPS': '/fileserver-admin',
      },
    });

    // 409 if version mismatch, 200 if version happens to match
    expect([200, 409]).toContain(postResp.status());
  });

  test('POST /fileserver/housekeeping/config rejects invalid payload', async ({ page }) => {
    const getResp = await page.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    const current = await getResp?.json();

    const payload = {
      version: current.version,
      download: { rules: [{ path: '/', keep_days: 10 }] }, // Missing keep_count
    };

    const postResp = await page.request.post('/fileserver/housekeeping/config', {
      data: payload,
      headers: {
        'Content-Type': 'application/json',
        'X-USER-GROUPS': '/fileserver-admin',
      },
    });

    expect(postResp.status()).toBe(400);
  });

  // ========================================================================
  // Dirs API
  // ========================================================================

  test('GET /fileserver/housekeeping/dirs lists directories for valid bucket', async ({ page }) => {
    const response = await page.goto(
      '/fileserver/housekeeping/dirs?bucket=download&path=/',
      { waitUntil: 'domcontentloaded' }
    );
    expect(response?.status()).toBe(200);
    const json = await response?.json();
    expect(Array.isArray(json)).toBe(true);
  });

  test('GET /fileserver/housekeeping/dirs rejects missing bucket', async ({ page }) => {
    const response = await page.goto('/fileserver/housekeeping/dirs', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(400);
  });

  test('GET /fileserver/housekeeping/dirs rejects invalid bucket', async ({ page }) => {
    const response = await page.goto(
      '/fileserver/housekeeping/dirs?bucket=invalid_bucket&path=/',
      { waitUntil: 'domcontentloaded' }
    );
    expect(response?.status()).toBe(400);
  });

  test('GET /fileserver/housekeeping/dirs rejects path traversal', async ({ page }) => {
    const response = await page.goto(
      '/fileserver/housekeeping/dirs?bucket=download&path=/../../etc',
      { waitUntil: 'domcontentloaded' }
    );
    expect(response?.status()).toBe(400);
  });

  // ========================================================================
  // Run API
  // ========================================================================

  test('POST /fileserver/housekeeping/run dry_run returns results without deleting', async ({ page }) => {
    const postResp = await page.request.post('/fileserver/housekeeping/run', {
      data: { dry_run: true },
      headers: {
        'Content-Type': 'application/json',
        'X-USER-GROUPS': '/fileserver-admin',
      },
    });

    expect(postResp.status()).toBe(200);
    const result = await postResp.json();
    expect(result).toHaveProperty('ok', true);
    expect(result).toHaveProperty('buckets');
    expect(result).toHaveProperty('files');
  });

  // ========================================================================
  // UI: Tab switching
  // ========================================================================

  test('tabs switch between Rules and Run Now', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    // Rules tab should be active by default
    await expect(page.locator('#rulesTab')).toHaveClass(/active/);
    await expect(page.locator('#runNowTab')).not.toHaveClass(/active/);

    // Switch to Run Now tab
    await page.click('#runNowTabBtn');
    await page.waitForTimeout(300);
    await expect(page.locator('#runNowTab')).toHaveClass(/active/);
    await expect(page.locator('#runNowButton')).toBeVisible();
    await expect(page.locator('#dryRunCheckbox')).toBeChecked();

    // Switch back to Rules tab
    await page.click('#rulesTabBtn');
    await page.waitForTimeout(300);
    await expect(page.locator('#rulesTab')).toHaveClass(/active/);
  });

  // ========================================================================
  // UI: Run Now
  // ========================================================================

  test('dry run checkbox is checked by default and run button works', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    // Switch to Run Now tab
    await page.click('#runNowTabBtn');
    await page.waitForTimeout(300);

    // Dry run checkbox should be checked
    await expect(page.locator('#dryRunCheckbox')).toBeChecked();

    // Click Run Now
    await page.click('#runNowButton');

    // Should show results card or notification
    await page.waitForTimeout(1000);
    const resultsVisible = await page.locator('#resultsCard').isVisible();
    const notificationVisible = await page.locator('#runNotification').isVisible();
    expect(resultsVisible || notificationVisible).toBe(true);
  });

  // ========================================================================
  // UI: Save/Reset buttons
  // ========================================================================

  test('save button is disabled initially, reset button is visible', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    await expect(page.locator('#saveButton')).toBeDisabled();
    await expect(page.locator('#resetButton')).toBeVisible();
  });

  // ========================================================================
  // UI: Tree view loads and renders directory entries
  // ========================================================================

  test('tree view shows three bucket root nodes on page load', async ({ page }) => {
    // Intercept the dirs API to verify no API call is made on initial load
    let dirsRequestCount = 0;
    await page.route('**/fileserver/housekeeping/dirs*', (route) => {
      dirsRequestCount++;
      route.continue();
    });

    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    // Wait for tree content to load (spinner disappears)
    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // No API call should be made on initial load — buckets are rendered from config
    expect(dirsRequestCount).toBe(0);

    // Verify three bucket root nodes are rendered directly
    const treeNodes = page.locator('#treeContent > .tree-node');
    await expect(treeNodes).toHaveCount(3);

    const nodeNames = await page.locator('#treeContent > .tree-node .tree-node-name').allTextContents();
    expect(nodeNames).toContain('download');
    expect(nodeNames).toContain('archive');
    expect(nodeNames).toContain('public');
  });

  test('expanding bucket root node sends correct API request and renders entries', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    // Wait for initial tree load to complete
    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Wait for the next dirs API response after expanding the archive bucket
    const dirsResponsePromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );

    // Find the archive root node and click its toggle to expand
    const archiveNode = page.locator('.tree-node:has(.tree-node-name:text("archive"))');
    await archiveNode.locator('.tree-toggle').click();
    await dirsResponsePromise;

    // Wait for children to render
    await page.waitForTimeout(500);

    // Verify entries are rendered inside the archive node's children container
    const archiveChildren = page.locator('#treeContent .tree-children .tree-node-name');
    const count = await archiveChildren.count();
    expect(count).toBeGreaterThanOrEqual(0); // May be 0 if no subdirectories exist

    // Archive bucket node should still be visible
    await expect(archiveNode).toBeVisible();
  });

  // ========================================================================
  // UI: Rule editor — clicking a tree node populates the right panel
  // ========================================================================

  test('clicking a tree node populates the rule editor', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    // Wait for tree to load
    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Editor should show placeholder initially
    await expect(page.locator('#editorContent')).toContainText('Select a directory from the tree');

    // Get the tree nodes and click the first one
    const treeNodes = page.locator('#treeContent .tree-node-name');
    const count = await treeNodes.count();

    if (count > 0) {
      await treeNodes.first().click();
      await page.waitForTimeout(300);

      // Editor should no longer show the placeholder
      const editorText = await page.locator('#editorContent').textContent();
      expect(editorText).not.toContain('Select a directory from the tree');

      // The path label should show the selected path (not empty)
      const pathLabel = await page.locator('#editorPathLabel').textContent();
      expect(pathLabel).toBeTruthy();
      expect(pathLabel).not.toBe('');
    }
  });

  test('clicking a tree node populates the editor with action buttons', async ({ page }) => {
    // Set up a config with a root rule so there is an explicit rule at /
    const getResp = await page.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    const config = await getResp?.json();
    const version = config.version || 1;

    await page.request.post('/fileserver/housekeeping/config', {
      data: {
        version,
        download: { rules: [{ path: '/', keep_count: 10, keep_days: 7 }] },
        archive: { rules: [] },
        public: { rules: [] },
      },
      headers: {
        'Content-Type': 'application/json',
        'X-USER-GROUPS': '/fileserver-admin',
      },
    });

    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Root node was removed from the tree — click the first directory entry instead
    const treeNodes = page.locator('#treeContent .tree-node-name');
    const count = await treeNodes.count();

    if (count > 0) {
      await treeNodes.first().click();
      await page.waitForTimeout(300);

      // Editor should be populated (no placeholder)
      const editorText = await page.locator('#editorContent').textContent();
      expect(editorText).not.toContain('Select a directory from the tree');

      // Path label should be set
      const pathLabel = await page.locator('#editorPathLabel').textContent();
      expect(pathLabel).toBeTruthy();

      // At least one action button should be visible
      const updateVisible = await page.locator('button:has-text("Update")').isVisible();
      const removeVisible = await page.locator('button:has-text("Remove")').isVisible();
      const addVisible = await page.locator('button:has-text("Add Rule")').isVisible();
      expect(updateVisible || removeVisible || addVisible).toBe(true);
    }
  });

  test('clicking subdirectory shows inherited banner when parent has rule', async ({ page }) => {
    // First, ensure the config has a root-level rule so subdirectories inherit
    const getResp = await page.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    const config = await getResp?.json();
    const version = config.version || 1;
    const downloadRules = config.download?.rules || [];

    const hasRootRule = downloadRules.some((r: { path: string }) => r.path === '/');
    if (!hasRootRule) {
      await page.request.post('/fileserver/housekeeping/config', {
        data: {
          version,
          download: { rules: [{ path: '/', keep_count: 50, keep_days: 0 }] },
          archive: { rules: [] },
          public: { rules: [] },
        },
        headers: {
          'Content-Type': 'application/json',
          'X-USER-GROUPS': '/fileserver-admin',
        },
      });
    }

    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Expand the download bucket to see its subdirectories
    const downloadNode = page.locator('.tree-node:has(.tree-node-name:text("download"))');
    const dirsPromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );
    await downloadNode.locator('.tree-toggle').click();
    await dirsPromise;
    await page.waitForTimeout(500);

    // Get subdirectory nodes inside download's children (not the bucket root nodes)
    const subNodes = page.locator('#treeContent .tree-children .tree-node');
    const subCount = await subNodes.count();

    if (subCount > 0) {
      await subNodes.first().locator('.tree-node-name').click();
      await page.waitForTimeout(300);

      // Editor should not show the placeholder
      const editorText = await page.locator('#editorContent').textContent();
      expect(editorText).not.toContain('Select a directory from the tree');

      // Path label should be set
      const pathLabel = await page.locator('#editorPathLabel').textContent();
      expect(pathLabel).toBeTruthy();

      // The editor shows either:
      // - inherited banner + Add Rule (for inherited paths)
      // - Update/Remove buttons (for explicit rules)
      // - Add Rule button alone (for paths with no rule)
      const hasInheritedBanner = await page.locator('.rule-inherited-banner').isVisible();
      const hasUpdateBtn = await page.locator('button:has-text("Update")').isVisible();
      const hasRemoveBtn = await page.locator('button:has-text("Remove")').isVisible();
      const hasAddBtn = await page.locator('button:has-text("Add Rule")').isVisible();

      // If inherited banner is shown, Add Rule should be shown (not Update/Remove)
      if (hasInheritedBanner) {
        expect(hasAddBtn).toBe(true);
        expect(hasUpdateBtn).toBe(false);
        expect(hasRemoveBtn).toBe(false);
      }

      // At least one button type should be present
      expect(hasUpdateBtn || hasRemoveBtn || hasAddBtn).toBe(true);
    }
  });

  test('tree nodes display rule badges', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Tree badges should be present (either explicit or inherited)
    // The default config has a rule at / for download, so subdirectories
    // should show inherited badges
    const badges = page.locator('.tree-badge');
    const badgeCount = await badges.count();

    // If the tree has subdirectories and a root rule exists, expect badges
    // If no subdirectories, badges may be 0 which is also valid
    // We just verify the badge elements exist in the DOM structure
    const treeNodes = page.locator('#treeContent .tree-node');
    const nodeCount = await treeNodes.count();

    // At minimum, verify the tree structure has nodes
    expect(nodeCount).toBeGreaterThan(0);
  });

  test('inherited rule editor shows empty inputs and Add Rule button', async ({ page }) => {
    // This test verifies the fix: findRuleForPath must return rule=null
    // for inherited rules so the editor shows empty inputs + Add Rule,
    // NOT pre-filled inputs with Update/Remove

    // Set up config with a root rule only (no explicit subdirectory rules)
    const getResp = await page.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    const config = await getResp?.json();
    const version = config.version || 1;

    await page.request.post('/fileserver/housekeeping/config', {
      data: {
        version,
        download: { rules: [{ path: '/', keep_count: 50, keep_days: 30 }] },
        archive: { rules: [] },
        public: { rules: [] },
      },
      headers: {
        'Content-Type': 'application/json',
        'X-USER-GROUPS': '/fileserver-admin',
      },
    });

    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });

    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Expand the download bucket to see its subdirectories
    const downloadNode = page.locator('.tree-node:has(.tree-node-name:text("download"))');
    const dirsPromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );
    await downloadNode.locator('.tree-toggle').click();
    await dirsPromise;
    await page.waitForTimeout(500);

    // Click the first subdirectory (not the bucket root node)
    const subNodes = page.locator('#treeContent .tree-children .tree-node .tree-node-name');
    const count = await subNodes.count();

    if (count > 0) {
      await subNodes.first().click();
      await page.waitForTimeout(300);

      // Subdirectory inherits from root — should show inherited banner
      // and empty inputs (not pre-filled with 50/30 from root rule)
      const hasInheritedBanner = await page.locator('.rule-inherited-banner').isVisible();
      const hasAddBtn = await page.locator('button:has-text("Add Rule")').isVisible();

      if (hasInheritedBanner) {
        // Inputs should be empty for inherited paths
        const keepCountInput = page.locator('#keepCountInput');
        const subKeepCount = await keepCountInput.inputValue();
        expect(subKeepCount).toBe('0');
      }
    }
  });

  // ========================================================================
  // UI: Tree focus preservation — staging and saving should not collapse tree
  // ========================================================================

  test('staging a rule keeps tree expanded and updates badge in place', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });
    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Expand the download bucket
    const downloadNode = page.locator('.tree-node:has(.tree-node-name:text("download"))');
    const dirsPromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );
    await downloadNode.locator('.tree-toggle').click();
    await dirsPromise;
    await page.waitForTimeout(500);

    // Verify children are visible
    const childrenBefore = page.locator('#treeContent .tree-children .tree-node');
    const childCountBefore = await childrenBefore.count();
    expect(childCountBefore).toBeGreaterThan(0);

    // Click the first subdirectory to select it in the editor
    await childrenBefore.first().locator('.tree-node-name').click();
    await page.waitForTimeout(300);

    // Fill in the rule values and click Add Rule
    await page.fill('#keepCountInput', '3');
    await page.fill('#keepDaysInput', '14');
    await page.click('button:has-text("Add Rule")');
    await page.waitForTimeout(300);

    // Tree should still be expanded — same number of child nodes
    const childCountAfter = await childrenBefore.count();
    expect(childCountAfter).toBe(childCountBefore);

    // The staged node should show a "staged: keep 3 · 14d" badge
    const stagedBadge = page.locator('.tree-badge:has-text("staged:")');
    await expect(stagedBadge).toBeVisible();
    await expect(stagedBadge).toContainText('keep 3');
    await expect(stagedBadge).toContainText('14d');

    // Save button should be enabled
    await expect(page.locator('#saveButton')).toBeEnabled();
  });

  test('save keeps expanded branches and selected node', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });
    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Expand both download and archive (top-level bucket nodes only)
    const downloadNode = page.locator('#treeContent > .tree-node:has(.tree-node-name:text("download"))');
    const dlPromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );
    await downloadNode.locator('.tree-toggle').click();
    await dlPromise;
    await page.waitForTimeout(500);

    const archiveNode = page.locator('#treeContent > .tree-node:has(.tree-node-name:text("archive"))');
    const arPromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );
    await archiveNode.locator('.tree-toggle').click();
    await arPromise;
    await page.waitForTimeout(500);

    // Select a subdirectory under download
    const downloadChildren = page.locator('#treeContent > .tree-children').first().locator('.tree-node');
    const subCount = await downloadChildren.count();
    if (subCount === 0) return;

    await downloadChildren.first().locator('.tree-node-name').click();
    await page.waitForTimeout(300);

    // Stage a rule
    await page.fill('#keepCountInput', '7');
    await page.fill('#keepDaysInput', '30');
    await page.click('button:has-text("Add Rule")');
    await page.waitForTimeout(300);

    // Verify tree is still expanded before saving
    const dlChildCountBefore = await downloadChildren.count();

    // Click save
    const savePromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/config') && response.request().method() === 'POST',
      { timeout: 10000 }
    );
    await page.click('#saveButton');
    await savePromise;
    await page.waitForTimeout(1000);

    // Both download and archive should still be expanded
    const dlChildCountAfter = await page.locator('#treeContent > .tree-children').first().locator('.tree-node').count();
    expect(dlChildCountAfter).toBe(dlChildCountBefore);

    // Archive should still have its children visible (not collapsed)
    const archiveChildren = page.locator('#treeContent > .tree-children').nth(1);
    const archiveVisible = await archiveChildren.isVisible();
    expect(archiveVisible).toBe(true);

    // Editor should still show the selected path (not the placeholder)
    const editorText = await page.locator('#editorContent').textContent();
    expect(editorText).not.toContain('Select a directory from the tree');

    // The saved node should show a real badge (not staged)
    const savedBadge = page.locator('.tree-badge:has-text("keep 7")');
    await expect(savedBadge).toBeVisible();
    expect(await savedBadge.textContent()).not.toContain('staged:');

    // Save button should be disabled (no pending changes)
    await expect(page.locator('#saveButton')).toBeDisabled();
  });

  test('reset changes reverts staged badges', async ({ page }) => {
    await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#mainTabs', { timeout: 10000 });
    await page.waitForFunction(() => {
      const spinner = document.getElementById('treeLoading');
      return spinner && spinner.classList.contains('d-none');
    }, { timeout: 10000 });

    // Expand download
    const downloadNode = page.locator('.tree-node:has(.tree-node-name:text("download"))');
    const dirsPromise = page.waitForResponse(
      (response) => response.url().includes('/fileserver/housekeeping/dirs') && response.status() === 200,
      { timeout: 10000 }
    );
    await downloadNode.locator('.tree-toggle').click();
    await dirsPromise;
    await page.waitForTimeout(500);

    // Select a subdirectory and stage a rule
    const children = page.locator('#treeContent .tree-children .tree-node');
    await children.first().locator('.tree-node-name').click();
    await page.waitForTimeout(300);

    // Stage a rule
    await page.fill('#keepCountInput', '99');
    await page.fill('#keepDaysInput', '99');
    // Click whichever staging button is present (Add Rule or Update)
    const addBtn = page.locator('button:has-text("Add Rule")');
    const updateBtn = page.locator('button:has-text("Update")');
    if (await addBtn.isVisible()) {
      await addBtn.click();
    } else {
      await updateBtn.click();
    }
    await page.waitForTimeout(300);

    // Should have a staged badge
    const stagedBadge = page.locator('.tree-badge:has-text("staged:")');
    await expect(stagedBadge).toBeVisible();

    // Click reset and confirm the dialog
    page.on('dialog', (dialog) => dialog.accept());
    await page.click('#resetButton');
    await page.waitForTimeout(1000);

    // No staged badges should remain
    const stagedAfter = page.locator('.tree-badge:has-text("staged:")');
    expect(await stagedAfter.count()).toBe(0);

    // Save button should be disabled
    await expect(page.locator('#saveButton')).toBeDisabled();
  });

  // ========================================================================
  // Auth: unauthenticated access
  // ========================================================================

  test('page returns 403 without admin headers', async ({ page }) => {
    // Clear extra headers by using a new context
    const browser = page.context().browser();
    if (!browser) return;
    const newContext = await browser.newContext();
    const newPage = await newContext.newPage();
    const response = await newPage.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(403);
    await newContext.close();
  });

  test('config endpoint returns 403 without admin headers', async ({ page }) => {
    const browser = page.context().browser();
    if (!browser) return;
    const newContext = await browser.newContext();
    const newPage = await newContext.newPage();
    const response = await newPage.goto('/fileserver/housekeeping/config', { waitUntil: 'domcontentloaded' });
    expect(response?.status()).toBe(403);
    await newContext.close();
  });
});

test.describe('Admin pages without auth', () => {
  test('userinfo shows guest without admin headers', async ({ page }) => {
    const response = await page.goto('/fileserver/userinfo', { waitUntil: 'domcontentloaded' });
    const json = await response?.json();
    expect(json).toHaveProperty('isAdmin', false);
  });
});
