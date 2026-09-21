import { test, expect, Page } from '@playwright/test';

const ADMIN_HEADERS = {
  'X-USER-NAME': 'Test Admin',
  'X-USER': 'test-admin',
  'X-USER-EMAIL': 'admin@test.local',
  'X-USER-GROUPS': 'fileserver_admin',
};

const CONFIG_URL = '/fileserver/housekeeping/config';

// The tree keys every node by `safeBtoa(childPath)` — base64 over the UTF-8
// bytes. Mirroring it here lets a test address a node by its *path* rather than
// by position, which is the only way to talk about a node the page may have
// rendered twice.
const b64 = (s: string) => Buffer.from(s, 'utf8').toString('base64');
const toggleSel = (childPath: string) => `[id="toggle-${b64(childPath)}"]`;
const nodeSel = (childPath: string) => `[id="node-${b64(childPath)}"]`;
const nodeNameSel = (childPath: string) => `${nodeSel(childPath)} > .tree-node-name`;

// getRelPathFromChildPath(): the bucket-relative path the API is asked for.
const apiPathFor = (childPath: string) => {
  const slash = childPath.indexOf('/');
  return slash >= 0 ? childPath.substring(slash) : '/';
};

const NESTED = 'download/deep/nested';

// One bucket-root rule, so every deeper node shows an inherited badge and
// `download` has a real rules array to push onto.
const seededConfig = (version: number) => ({
  version,
  download: { rules: [{ path: '/', keep_count: 50, keep_days: 0 }] },
  archive: { rules: [] },
  public: { rules: [] },
});

async function setSeededConfig(page: Page) {
  const current = await (await page.request.get(CONFIG_URL, { headers: ADMIN_HEADERS })).json();
  await page.request.post(CONFIG_URL, {
    headers: ADMIN_HEADERS,
    data: seededConfig(current.version ?? 1),
  });
}

/**
 * Every node's ancestry, plus anything the tree rendered outside a bucket.
 *
 * `#treeContent` is a flat list: for each bucket, one `.tree-node` followed by
 * one `.tree-children` container, and every deeper node lives inside its
 * parent's container. So a `.tree-children` that is a direct child of
 * `#treeContent` and is *not* one of the three bucket containers holds a
 * subtree rendered at the root instead of under its parent — the duplicate.
 */
async function readTreeShape(page: Page) {
  return page.evaluate((nestedPath) => {
    const tree = document.getElementById('treeContent');
    if (!tree) throw new Error('#treeContent not found');

    const bucketContainers = ['download', 'archive', 'public'].map((b) => 'children-' + btoa(b));
    const nameOf = (el: Element) => {
      const n = el.querySelector(':scope > .tree-node-name');
      return n ? (n.textContent || '') : '';
    };
    const nodeNamesIn = (containerId: string) => {
      const container = document.getElementById(containerId);
      if (!container) return [];
      return Array.from(container.children)
        .filter((el) => el.classList.contains('tree-node'))
        .map(nameOf);
    };

    const directNodeNames: string[] = [];
    const strays: string[] = [];
    for (const el of Array.from(tree.children)) {
      if (el.classList.contains('tree-node')) {
        directNodeNames.push(nameOf(el));
      } else if (el.classList.contains('tree-children') && !bucketContainers.includes(el.id)) {
        strays.push((el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120));
      }
    }

    // Walk up from the node, naming each ancestor by the container it sits in.
    const ancestors: string[] = [];
    const target = document.getElementById('node-' + btoa(nestedPath));
    let cur = target ? target.parentElement : null;
    while (cur && cur !== tree) {
      if (cur.classList.contains('tree-children')) {
        const prev = cur.previousElementSibling;
        if (prev && prev.classList.contains('tree-node')) ancestors.unshift(nameOf(prev));
      }
      cur = cur.parentElement;
    }

    const allNodes = Array.from(tree.querySelectorAll('.tree-node'));
    return {
      directNodeNames,
      strays,
      ancestors,
      nestedCount: allNodes.filter((el) => nameOf(el) === 'nested').length,
      downloadChildren: nodeNamesIn('children-' + btoa('download')),
    };
  }, NESTED);
}

/** The contract: one copy of `nested`, under download > deep, nothing at root. */
async function expectTreeIntact(page: Page) {
  // Polled as a whole: the re-expansion after a save is asynchronous, and a
  // single snapshot would either race it or (for `strays` alone) pass before
  // anything had been rendered at all.
  await expect.poll(async () => {
    const shape = await readTreeShape(page);
    return {
      strays: shape.strays,
      directNodeNames: shape.directNodeNames,
      nestedCount: shape.nestedCount,
      ancestors: shape.ancestors,
      hasDeep: shape.downloadChildren.includes('deep'),
    };
  }).toEqual({
    strays: [],
    directNodeNames: ['download', 'archive', 'public'],
    nestedCount: 1,
    ancestors: ['download', 'deep'],
    hasDeep: true,
  });
}

interface DirCall {
  bucket: string | null;
  path: string | null;
}

/**
 * Open the page, expand download > deep, and stage a rule on the level-2 node.
 *
 * `hold.ms` delays the bucket-level /dirs call once set, which is how the tests
 * force the deep response to land first.
 */
async function openAndStage(page: Page, hold: { ms: number; applied: boolean }) {
  const dirsCalls: DirCall[] = [];

  await page.route('**/housekeeping/dirs*', async (route) => {
    const url = new URL(route.request().url());
    const bucket = url.searchParams.get('bucket');
    const path = url.searchParams.get('path');
    dirsCalls.push({ bucket, path });

    if (hold.ms > 0 && path === '/' && bucket === 'download') {
      hold.applied = true;
      await new Promise((resolve) => setTimeout(resolve, hold.ms));
    }
    await route.continue();
  });

  await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#mainTabs', { timeout: 10000 });
  await page.waitForFunction(() => {
    const spinner = document.getElementById('treeLoading');
    return spinner && spinner.classList.contains('d-none');
  }, { timeout: 10000 });

  // Expand the bucket, then one level down, so two paths are open when the
  // save rebuilds the tree. Reaching the level-2 node at all means the user has
  // exactly this state open — which is why the bug needs a non-first-level node.
  for (const childPath of ['download', 'download/deep']) {
    const response = page.waitForResponse((r) => {
      if (!r.url().includes('/housekeeping/dirs') || r.status() !== 200) return false;
      const url = new URL(r.url());
      return url.searchParams.get('bucket') === childPath.split('/')[0] &&
        url.searchParams.get('path') === apiPathFor(childPath);
    });
    await page.locator(toggleSel(childPath)).click();
    await response;
  }
  await expect(page.locator(nodeNameSel(NESTED))).toBeVisible();

  // Selecting a node renders the editor with its inputs already there —
  // "Add Rule" is itself the staging action.
  await page.locator(nodeNameSel(NESTED)).click();
  await expect(page.locator('#editorPathLabel')).toHaveText('/' + NESTED);
  await page.fill('#keepCountInput', '3');
  await page.fill('#keepDaysInput', '1');
  await page.locator('button:has-text("Add Rule")').click();
  await expect(page.locator(`${nodeSel(NESTED)} .tree-badge`)).toHaveText('staged: keep 3 · 1d');

  return {
    /** /dirs calls made since the save was triggered. */
    callsAfterSave: () => dirsCalls.slice(),
    markSave: () => {
      dirsCalls.length = 0;
    },
  };
}

async function saveAndWait(page: Page) {
  await expect(page.locator('#saveButton')).toBeEnabled();
  const saved = page.waitForResponse(
    (r) => r.url().includes('/housekeeping/config') && r.request().method() === 'POST',
  );
  await page.locator('#saveButton').click();
  expect((await saved).status()).toBe(200);
}

test.describe('Housekeeping rule tree', () => {
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders(ADMIN_HEADERS);
    await setSeededConfig(page);
  });

  test.afterEach(async ({ page }) => {
    await setSeededConfig(page);
  });

  test('saving a rule keeps the open tree, with each directory rendered once', async ({ page }) => {
    const hold = { ms: 0, applied: false };
    const tree = await openAndStage(page, hold);
    tree.markSave();

    await saveAndWait(page);

    // The frontend refetched exactly the paths that were open, by bucket + path.
    await expect.poll(() => tree.callsAfterSave().map((c) => `${c.bucket}${c.path === '/' ? '' : c.path}`).sort())
      .toEqual(['download', 'download/deep']);

    await expectTreeIntact(page);
  });

  /**
   * After a save the page rebuilds the tree and re-expands every path that was
   * open. A node's container is created by its *parent's* response, so firing
   * all of those calls at once let a deep response land before the shallow one
   * that would have created its container — the lookup missed, and the fallback
   * appended a brand-new container to #treeContent, parking the subtree at the
   * bottom of the tree. This holds the bucket-level call back so that order is
   * forced rather than left to chance (hence the "only sometimes" in the bug
   * report); the assertion is the same contract as the test above.
   */
  test('saving a rule does not duplicate the subtree when a deep dirs call lands first', async ({ page }) => {
    const hold = { ms: 1000, applied: false };
    const tree = await openAndStage(page, hold);
    tree.markSave();

    await saveAndWait(page);

    // The race was actually forced — without this the test could pass by not
    // racing at all. The delayed call is still in flight here; expectTreeIntact
    // polls until the tree has settled (or fails, if it settled wrong).
    expect(hold.applied).toBe(true);

    await expectTreeIntact(page);
  });
});
