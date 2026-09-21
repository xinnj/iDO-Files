import { expect, Page } from '@playwright/test';

/**
 * Helpers for asserting that a page's theme actually repaints.
 *
 * The point of measuring rather than pinning hex is that a hex assertion
 * passes the moment it is written and then discourages anyone from ever
 * touching the palette again, while telling you nothing about whether the
 * result is legible. These check the properties that matter: is the surface
 * dark, is the text on it readable, does a state change at all.
 *
 * These live outside tests/ so the Playwright runner does not collect them as
 * a spec — the same reason tests/pages/ exists.
 */

/**
 * Resolve the *painted* background of an element: walk up compositing
 * translucent backgrounds until one is opaque, so `rgba(96,165,250,0.12)` over a
 * dark card is measured as the dark composite it actually renders as rather
 * than as a bright blue.
 *
 * A `linear-gradient` background leaves `background-color` transparent —
 * without the gradient branch such an element would be measured as whatever
 * sits behind it and read as a false failure.
 */
export async function surfaceLuminance(page: Page, selector: string): Promise<number> {
  const first = page.locator(selector).first();
  await expect(first, `${selector} should exist`).toHaveCount(1);
  return first.evaluate((el: Element) => {
    const parse = (c: string) => {
      const m = c.match(/rgba?\(([^)]+)\)/);
      if (!m) return null;
      const p = m[1].split(',').map((v) => parseFloat(v));
      return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
    };
    const linear = (c: number) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
    const lum = (r: number, g: number, b: number) =>
      0.2126 * linear(r / 255) + 0.7152 * linear(g / 255) + 0.0722 * linear(b / 255);

    const stack: { r: number; g: number; b: number; a: number }[] = [];
    let node: Element | null = el;
    while (node) {
      const cs = getComputedStyle(node);
      let c = parse(cs.backgroundColor);
      // A gradient paints even when background-color is transparent. Use its
      // first colour stop as the surface colour.
      if ((!c || c.a === 0) && cs.backgroundImage.includes('gradient')) {
        const inner = cs.backgroundImage.match(/rgba?\([^)]+\)/);
        if (inner) c = parse(inner[0]);
      }
      if (c && c.a > 0) {
        stack.push(c);
        if (c.a >= 1) break;
      }
      node = node.parentElement;
    }

    // Composite bottom-up over white (the light-mode page base).
    let base = { r: 255, g: 255, b: 255 };
    for (let i = stack.length - 1; i >= 0; i--) {
      const c = stack[i];
      base = {
        r: c.r * c.a + base.r * (1 - c.a),
        g: c.g * c.a + base.g * (1 - c.a),
        b: c.b * c.a + base.b * (1 - c.a),
      };
    }
    return lum(base.r, base.g, base.b);
  });
}

/**
 * Raw luminance of a computed `rgb()`/`rgba()` string, in Node.
 *
 * Note this ignores alpha: `rgba(96,165,250,0.3)` reports the luminance of
 * `#60a5fa`, not of what it composites to. Do not feed it a translucent
 * colour and read the result as "how visible is this" — composite first.
 */
export function luminance(css: string): number {
  const p = css.match(/rgba?\(([^)]+)\)/)![1].split(',').map((v) => parseFloat(v));
  const linear = (c: number) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  return 0.2126 * linear(p[0] / 255) + 0.7152 * linear(p[1] / 255) + 0.0722 * linear(p[2] / 255);
}

/** WCAG contrast ratio between two computed colours. */
export function contrastRatio(fg: string, bg: string): number {
  const [hi, lo] = [luminance(fg), luminance(bg)].sort((a, b) => b - a);
  return (hi + 0.05) / (lo + 0.05);
}

/** Read a computed style property, asserting the element exists first. */
export async function computed(page: Page, selector: string, prop: string): Promise<string> {
  const first = page.locator(selector).first();
  await expect(first, `${selector} should exist`).toHaveCount(1);
  return first.evaluate(
    (el: Element, p: string) => getComputedStyle(el).getPropertyValue(p),
    prop,
  );
}

/** The theme currently applied to the document. */
export async function theme(page: Page): Promise<string | null> {
  return page.locator('html').getAttribute('data-theme');
}

/**
 * Assert the *property that matters* — the page is dark and its text is
 * legible — rather than pinning hex values, which would drift the moment the
 * palette is touched.
 */
export function expectDark(l: number, where: string) {
  expect(l, `${where} should be dark (luminance < 0.2, got ${l.toFixed(3)})`).toBeLessThan(0.2);
}
