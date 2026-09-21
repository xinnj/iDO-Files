import { test, expect, Page } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';
import { computed, contrastRatio } from '../utils/theme';

/**
 * Light/dark parity for the file-list toolbar — the search box, New folder and
 * Upload, and the states that only exist while you interact with them.
 *
 * `theme.spec.ts` covers the toggle *behaviour* (does the attribute flip, does
 * it persist). This file covers what the flip actually paints, which is the
 * half that fails silently: a control can follow `data-theme` correctly and
 * still be unreadable, because its colour came from a literal or from a token
 * that means something else in dark.
 *
 * Two lessons from `admin-theme.spec.ts` are baked in here: assert the property
 * that matters rather than a hex value, and give every sweep a light-mode
 * positive control so a page that failed to load cannot pass vacuously.
 */

let fb: FileBrowserPage;

test.beforeEach(async ({ page }) => {
  fb = new FileBrowserPage(page);
  await fb.gotoBucket('download');
});

/**
 * Switch theme the way the app does — write the stored preference, then reload
 * so the anti-FOUC head script applies it before paint — and assert it landed
 * before anything is measured.
 */
async function useTheme(page: Page, t: 'light' | 'dark') {
  await page.evaluate((v) => localStorage.setItem('theme', v), t);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await expect(page.locator('html')).toHaveAttribute('data-theme', t);
}

/**
 * Assert a control's background actually changes on hover, and by enough to
 * see.
 *
 * The sleep is now belt-and-braces rather than load-bearing: `getComputedStyle`
 * during a transition returns the *interpolated* colour, so it was mandatory
 * while `.btn` and `.search-clear` carried `transition: all 0.2s`. Those
 * transitions were removed along with the rest of the hover motion, so every
 * element this helper is called with now steps its colour at once. The wait is
 * kept because it is cheap and it is what keeps this honest if a transition is
 * ever reintroduced — the assertion below would otherwise read a frame
 * part-way there and report a smaller delta than the control really has.
 *
 * The 1.1 threshold is measured rather than invented — light mode's own working
 * hover delta is 1.13:1 — so this asks for "at least as visible as the
 * affordance that already works".
 */
async function expectHoverVisible(page: Page, selector: string, where: string) {
  const rest = await computed(page, selector, 'background-color');
  await page.locator(selector).hover();
  await page.waitForTimeout(300);
  const hover = await computed(page, selector, 'background-color');
  expect(hover, `${where} should change background on hover`).not.toBe(rest);
  const delta = contrastRatio(hover, rest);
  expect(
    delta,
    `${where} hover ${rest} -> ${hover} is only ${delta.toFixed(3)}:1, want > 1.1`,
  ).toBeGreaterThan(1.1);
}

test.describe('File browser toolbar theme', () => {
  // ==========================================================================
  // Light is the reference — pinned exactly, once
  // ==========================================================================

  test('light mode is unchanged by the token split', async ({ page }) => {
    // The only test here that pins values. Light mode is the acceptance
    // criterion for this change, so the exact colours it must keep are written
    // down; everything below measures a property instead, because a pinned
    // value tells you nothing about whether the result is legible.
    await useTheme(page, 'light');

    expect(await computed(page, '#upload-btn', 'background-color')).toBe('rgb(59, 130, 246)');
    expect(await computed(page, '#upload-btn', 'color')).toBe('rgb(255, 255, 255)');
    expect(await computed(page, '#new-folder-btn', 'background-color')).toBe('rgb(241, 245, 249)');

    await page.locator('#new-folder-btn').hover();
    await page.waitForTimeout(300);
    expect(await computed(page, '#new-folder-btn', 'background-color')).toBe('rgb(226, 232, 240)');
  });

  // ==========================================================================
  // Dark: the surfaces
  // ==========================================================================

  test('the Upload label is legible on its dark surface', async ({ page }) => {
    await useTheme(page, 'dark');
    // Read `background-color`, not `background` — the shorthand goes empty when
    // a gradient is involved, and an empty string would make this vacuous.
    const fg = await computed(page, '#upload-btn', 'color');
    const bg = await computed(page, '#upload-btn', 'background-color');
    const ratio = contrastRatio(fg, bg);
    expect(ratio, `label ${fg} on ${bg} is only ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
  });

  test('the Upload button does not shift on hover', async ({ page }) => {
    await useTheme(page, 'dark');
    // It used to translateY(-1px) and raise a shadow. Comparing the rendered
    // box is the honest test of "stays put" — it holds however the movement is
    // implemented, rather than asserting on one particular property.
    const btn = page.locator('#upload-btn');
    // Measured before the pointer arrives — expectHoverVisible leaves the mouse
    // on the button, so this has to be read first or "rest" is the hover colour.
    const before = await btn.boundingBox();

    // ...but it must still show it is hovered. The colour step is what carries
    // the state now that the lift is gone.
    await expectHoverVisible(page, '#upload-btn', 'Upload');

    const after = await btn.boundingBox();
    expect(after, 'button should not move under the cursor').toEqual(before);
  });

  test('the New folder button changes on hover in dark', async ({ page }) => {
    await useTheme(page, 'dark');
    // In dark, --bg-tertiary and --border are both #334155, so this button's
    // hover used to paint the colour it already had: no feedback at all.
    await expectHoverVisible(page, '#new-folder-btn', 'New folder');
  });

  test('the search-clear button changes on hover in dark', async ({ page }) => {
    await useTheme(page, 'dark');
    // Only rendered once there is a query to clear.
    await page.locator('#search-input').fill('a');
    await expect(page.locator('#search-clear')).toHaveClass(/visible/);
    await expectHoverVisible(page, '#search-clear', 'search-clear');
  });

  // ==========================================================================
  // Dark: the states that only exist during interaction
  // ==========================================================================

  test('the search box reacts to hover, and focus still wins', async ({ page }) => {
    for (const t of ['light', 'dark'] as const) {
      await useTheme(page, t);
      const rest = await computed(page, '#search-input', 'border-color');

      await page.locator('#search-input').hover();
      await page.waitForTimeout(350);
      const hover = await computed(page, '#search-input', 'border-color');
      expect(hover, `${t}: search box should react to hover`).not.toBe(rest);

      // .search-input:hover and .search-input:focus are both (0,2,0), so only
      // source order decides. This is the assertion that catches the hover rule
      // being moved below the focus rule and stealing the accent border.
      await page.locator('#search-input').focus();
      await page.waitForTimeout(350);
      const focused = await computed(page, '#search-input', 'border-color');
      expect(focused, `${t}: focus should still restyle the border`).not.toBe(hover);
    }
  });

  test('the search box focus ring is visible and themed', async ({ page }) => {
    const ringFor = async (t: 'light' | 'dark') => {
      await useTheme(page, t);
      await page.locator('#search-input').focus();
      // .search-input is in the `box-shadow 0.3s ease` transition list.
      await page.waitForTimeout(350);
      return computed(page, '#search-input', 'box-shadow');
    };

    const light = await ringFor('light');
    const dark = await ringFor('dark');

    // Positive control: if the light ring is missing, this element has no
    // focus affordance at all and the dark comparison below proves nothing.
    expect(light, 'light ring should be present').toContain('rgba(59, 130, 246');
    expect(dark, 'dark ring should differ from light').not.toBe(light);

    // Deliberately NOT contrastRatio(): luminance() ignores alpha, so feeding
    // it rgba(96,165,250,0.3) reports #60a5fa's luminance rather than what the
    // ring actually composites to over the input — confidently wrong.
    const alpha = dark.match(/rgba\(\s*[\d.]+\s*,\s*[\d.]+\s*,\s*[\d.]+\s*,\s*([\d.]+)\s*\)/)?.[1];
    expect(Number(alpha), `dark ring alpha in "${dark}"`).toBeGreaterThanOrEqual(0.25);
  });

  test('native input chrome follows the theme', async ({ page }) => {
    const placeholderFor = async (t: 'light' | 'dark') => {
      await useTheme(page, t);
      return page
        .locator('#search-input')
        .evaluate((el) => getComputedStyle(el, '::placeholder').color);
    };

    await useTheme(page, 'dark');
    expect(await computed(page, 'html', 'color-scheme')).toBe('dark');
    const dark = await placeholderFor('dark');
    const darkField = await computed(page, '#search-input', 'background-color');

    await useTheme(page, 'light');
    expect(await computed(page, 'html', 'color-scheme')).toBe('light');
    const light = await placeholderFor('light');

    // The user-visible symptom: "Search files..." was UA grey in both themes.
    expect(light, 'light placeholder should resolve').not.toBe('');
    expect(dark, 'dark placeholder should resolve').not.toBe('');
    expect(dark, 'placeholder should differ between themes').not.toBe(light);

    // Differing is not the same as readable. Placeholders are not held to the
    // 4.5 body-text bar, but they still have to be seen to do their job.
    const ratio = contrastRatio(dark, darkField);
    expect(ratio, `placeholder ${dark} on ${darkField} is only ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(3);
  });
});
