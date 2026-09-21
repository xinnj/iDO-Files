import { test, expect } from '@playwright/test';
import {
  computed,
  contrastRatio,
  expectDark,
  luminance,
  surfaceLuminance,
  theme,
} from '../utils/theme';

// Admin pages authenticate by header, same as admin-pages.spec.ts.
const ADMIN_HEADERS = {
  'X-USER-NAME': 'Test Admin',
  'X-USER': 'test-admin',
  'X-USER-EMAIL': 'admin@test.local',
  'X-USER-GROUPS': 'fileserver_admin',
};

/**
 * The five pages that load css/admin.css. `housekeeping` is served by a Lua
 * route (lua/housekeeping-admin.lua) rather than as a static .html file, so it
 * has no extension.
 *
 * `surfaces` are elements that must be dark in dark mode — all of them opaque,
 * near-white chrome in light mode, so a luminance threshold genuinely
 * discriminates.
 *
 * `.card-header` is deliberately NOT in this list. It is a mid-luminance blue
 * accent in both themes — measured, its light-mode gradient is luminance 0.170,
 * which is already below any "is it dark?" threshold that light chrome
 * satisfies. Asserting it there would pass whether or not it was ever themed.
 * It gets a dedicated light-vs-dark comparison instead (see below).
 */
const ADMIN_PAGES = [
  {
    name: 'access-control',
    url: '/fileserver/access-control.html',
    surfaces: ['.card', '.header-section', '.footer-buttons', '.table'],
  },
  {
    name: 'access-token',
    url: '/fileserver/access-token.html',
    // access-token has no footer bar — only a comment mentioning one.
    surfaces: ['.card', '.header-section'],
  },
  {
    name: 'housekeeping',
    url: '/fileserver/housekeeping',
    surfaces: ['.card', '.header-section', '.footer-buttons', '.table'],
  },
  {
    name: 'share-links',
    url: '/fileserver/share-links.html',
    surfaces: ['.card', '.header-section', '.footer-buttons', '.table'],
  },
  {
    name: 'upload',
    url: '/fileserver/upload.html',
    // upload's card carries no .card-header.
    surfaces: ['.card', '.header-section', '.footer-buttons', '.upload-area'],
  },
];

/** Surfaces expected to be near-white in light mode — the sweep's positive control. */
const LIGHT_SURFACES = ['.card', '.header-section'];

test.describe('Admin dark mode', () => {
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders(ADMIN_HEADERS);
  });

  // ==========================================================================
  // The theme source
  // ==========================================================================

  test.describe('follows the OS when no preference is stored', () => {
    test.use({ colorScheme: 'dark' });

    for (const { name, url } of ADMIN_PAGES) {
      test(`${name} is dark when the OS prefers dark`, async ({ page }) => {
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        expect(await theme(page)).toBe('dark');
      });
    }
  });

  test.describe('follows the OS light preference', () => {
    test.use({ colorScheme: 'light' });

    test('access-control is light when the OS prefers light', async ({ page }) => {
      await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
      expect(await theme(page)).toBe('light');
    });
  });

  test.describe('a stored preference beats the OS', () => {
    // This is the assertion that catches the attribute landing on <body>
    // instead of <html>, and the key being read from the wrong storage.
    test.describe('stored dark under a light OS', () => {
      test.use({ colorScheme: 'light' });

      test('access-control is dark', async ({ page }) => {
        await page.addInitScript(() => localStorage.setItem('theme', 'dark'));
        await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
        expect(await theme(page)).toBe('dark');
      });
    });

    test.describe('stored light under a dark OS', () => {
      test.use({ colorScheme: 'dark' });

      test('access-control is light', async ({ page }) => {
        await page.addInitScript(() => localStorage.setItem('theme', 'light'));
        await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
        expect(await theme(page)).toBe('light');
      });
    });

    test('the preference is shared with the file browser', async ({ page }) => {
      // Same origin and same key means one choice governs both. Written the way
      // the file browser writes it (js/app.js toggleTheme).
      await page.addInitScript(() => localStorage.setItem('theme', 'dark'));
      await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
      expect(await theme(page)).toBe('dark');
      expect(await page.evaluate(() => localStorage.getItem('theme'))).toBe('dark');
    });
  });

  // ==========================================================================
  // No flash of the wrong theme
  // ==========================================================================

  test('the theme is applied before first paint', async ({ page }) => {
    // domcontentloaded rather than load/networkidle is the point: it is the
    // earliest observable moment and exactly the window in which the white
    // flash used to happen.
    await page.addInitScript(() => localStorage.setItem('theme', 'dark'));
    await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });

    expect(await theme(page)).toBe('dark');
    // Assert against a real surface. --page-bg is a gradient in light mode, so
    // body's backgroundColor resolves to rgba(0,0,0,0) in both themes and would
    // make this assertion vacuous.
    expectDark(await surfaceLuminance(page, '.card'), 'housekeeping .card at DOMContentLoaded');
  });

  // ==========================================================================
  // The surface sweep — catches the one component that was missed
  // ==========================================================================

  test.describe('every surface repaints in dark', () => {
    test.use({ colorScheme: 'dark' });

    for (const { name, url, surfaces } of ADMIN_PAGES) {
      test(`${name}`, async ({ page }) => {
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        expect(await theme(page)).toBe('dark');
        for (const sel of surfaces) {
          expectDark(await surfaceLuminance(page, sel), `${name} ${sel}`);
        }
      });
    }
  });

  test.describe('the sweep is not vacuously passing', () => {
    // Without this, a page that failed to load at all would "pass" every
    // dark assertion above.
    test.use({ colorScheme: 'light' });

    for (const { name, url } of ADMIN_PAGES) {
      test(`${name} is light in light mode`, async ({ page }) => {
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        expect(await theme(page)).toBe('light');
        for (const sel of LIGHT_SURFACES) {
          const l = await surfaceLuminance(page, sel);
          expect(l, `${name} ${sel} should be light (got ${l.toFixed(3)})`).toBeGreaterThan(0.8);
        }
      });
    }
  });

  // ==========================================================================
  // Silent-drop guards.
  //
  // A malformed declaration is discarded by the browser with no error and no
  // warning — the element just keeps its previous style. Composing a shadow
  // shorthand into another shadow is the easy way to do it
  // ("box-shadow: 0 2px 8px var(--shadow-sm)", where the token already carries
  // its own offsets and blur, expands to six lengths and is dropped). Neither a
  // colour assertion nor a screenshot of a working page would reveal it.
  // ==========================================================================

  const SHADOW_CASES = [
    { url: '/fileserver/upload.html', sel: '.upload-stats' },
    { url: '/fileserver/upload.html', sel: '.base-url-section' },
    // share-links has no page-local box-shadow: its .stats-card rule is dead
    // (see the audit in the spec), so this checks admin.css's .card reaches it.
    { url: '/fileserver/share-links.html', sel: '.card' },
    { url: '/fileserver/access-token.html', sel: '.token-value' },
    { url: '/fileserver/access-control.html', sel: '.card' },
    { url: '/fileserver/housekeeping', sel: '.card' },
  ];

  for (const { url, sel } of SHADOW_CASES) {
    test(`box-shadow resolves on ${url} ${sel}`, async ({ page }) => {
      await page.goto(url, { waitUntil: 'domcontentloaded' });
      const v = (await computed(page, sel, 'box-shadow')).trim();
      expect(v, `${sel}'s box-shadow was dropped or empty`).not.toBe('');
      expect(v, `${sel}'s box-shadow fell back to the initial value`).not.toBe('none');
    });
  }

  test('the token layer resolves on every admin page', async ({ page }) => {
    // Catches a page that failed to load tokens.css: the var() would resolve to
    // nothing and every themed surface would silently fall back.
    const TOKENS = [
      '--bg-secondary',
      '--text-primary',
      '--accent-primary',
      '--border',
      '--page-bg',
      '--bg-active',
      '--danger-bg',
      '--text-subtle',
    ];
    for (const { name, url } of ADMIN_PAGES) {
      await page.goto(url, { waitUntil: 'domcontentloaded' });
      for (const t of TOKENS) {
        const v = await page.evaluate(
          (token) => getComputedStyle(document.documentElement).getPropertyValue(token).trim(),
          t,
        );
        expect(v, `${name} did not resolve ${t}`).not.toBe('');
      }
    }
  });

  // ==========================================================================
  // The accent surface. A luminance threshold cannot judge it, so compare the
  // painted gradient across themes instead.
  // ==========================================================================

  test('the card header repaints between themes', async ({ page }) => {
    const readHeader = async (scheme: 'light' | 'dark') => {
      await page.emulateMedia({ colorScheme: scheme });
      await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
      return page
        .locator('.card-header')
        .first()
        .evaluate((el: Element) => getComputedStyle(el).backgroundImage);
    };

    const light = await readHeader('light');
    const dark = await readHeader('dark');

    // Both are gradients, so this is not comparing empty strings.
    expect(light, 'card header should be painted with a gradient').toContain('gradient');
    expect(
      dark,
      `card header gradient must differ between themes.\nlight: ${light}\ndark:  ${dark}`,
    ).not.toBe(light);
  });

  // ==========================================================================
  // Legibility, not just darkness — a luminance-only sweep passes on an
  // unreadable page.
  // ==========================================================================

  test.describe('text stays legible in dark', () => {
    test.use({ colorScheme: 'dark' });

    test('body text on the card', async ({ page }) => {
      await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
      const fg = await computed(page, '.header-section p', 'color');
      const ratio = contrastRatio(fg, 'rgb(30, 41, 59)'); // .card dark surface
      expect(ratio, `contrast ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
    });

    test('body element has an explicit themed colour', async ({ page }) => {
      // admin.css originally set no colour on body at all, so Bootstrap's
      // #212529 won and every uncoloured element rendered near-black on dark.
      await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
      const fg = await computed(page, 'body', 'color');
      const l = luminance(fg);
      expect(l, `body colour luminance ${l.toFixed(3)} should not be near-black`).toBeGreaterThan(0.5);
    });

    test('housekeeping table header text on its header cell', async ({ page }) => {
      await page.goto('/fileserver/housekeeping', { waitUntil: 'domcontentloaded' });
      const fg = await computed(page, '.table thead th', 'color');
      const l = luminance(fg);
      expect(l, `thead colour luminance ${l.toFixed(3)}`).toBeGreaterThan(0.5);
    });
  });

  // ==========================================================================
  // Elements that carry colour inline cannot follow a token
  // ==========================================================================

  test('access-control ALLOW/DENY headings carry no inline colour', async ({ page }) => {
    await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
    for (const heading of ['ALLOW', 'DENY']) {
      const el = page.locator('h2', { hasText: new RegExp(`^${heading}$`, 'i') }).first();
      if ((await el.count()) === 0) continue;
      const style = await el.getAttribute('style');
      expect(style ?? '', `${heading} heading must not hardcode a colour`).not.toMatch(/#[0-9a-f]{3,6}/i);
    }
  });

  // ==========================================================================
  // Hover is a colour step, never a movement
  // ==========================================================================

  /**
   * Every admin page's `.card` used to lift 2px on hover (`translateY(-2px)`
   * plus `--shadow-md`). Comparing the rendered box is the honest test of
   * "stays put": it holds however the movement is implemented, rather than
   * pinning one property that a later refactor could replace with another.
   *
   * The same change was made to `.btn-primary` in the file browser, and
   * file-browser-theme.spec.ts's "the Upload button does not shift on hover"
   * covers it there.
   */
  test('a card does not shift on hover', async ({ page }) => {
    await page.goto('/fileserver/access-control.html', { waitUntil: 'domcontentloaded' });
    const card = page.locator('.card').first();
    const before = await card.boundingBox();

    await card.hover();
    // The wait is what gives this test its teeth. Read straight after .hover()
    // and a re-introduced transition would be measured at ~0 offset on its
    // first frame, so the assertion would pass on exactly the bug it exists to
    // catch. Waiting it out measures where the box actually settles.
    await page.waitForTimeout(300);

    const after = await card.boundingBox();
    expect(after, 'card should not move under the cursor').toEqual(before);
  });
});
