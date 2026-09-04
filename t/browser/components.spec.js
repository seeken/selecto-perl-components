import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components/selecto-components.js");

async function load(page, html) {
  await page.setContent(html);
  await page.addScriptTag({path: bundle});
}

test("the builder tray collapses and expands in place", async ({page}) => {
  await load(page, `
    <div data-sc-workspace>
      <button data-sc-builder-toggle data-sc-builder-id="orders" aria-expanded="true">
        <span data-sc-builder-chevron>‹</span>
      </button>
      <aside data-sc-builder-shell="orders" data-sc-builder-collapsed="false"></aside>
    </div>
  `);

  const toggle = page.locator("[data-sc-builder-toggle]");
  const tray = page.locator("[data-sc-builder-shell]");
  await toggle.click();
  await expect(tray).toHaveClass(/is-collapsed/);
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(toggle.locator("[data-sc-builder-chevron]")).toHaveText("›");
  await toggle.click();
  await expect(tray).not.toHaveClass(/is-collapsed/);
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
});

test("grid cells, axes, hover, and compact submission stay synchronized", async ({page}) => {
  await load(page, `
    <span data-selecto-connection class="is-live"></span>
    <form data-sc-grid-selection data-sc-grid-max="10">
      <table class="sc-aggregate-grid">
        <thead><tr><th></th><th><input type="checkbox" data-sc-grid-column-toggle="c1"></th><th><input type="checkbox" data-sc-grid-column-toggle="c2"></th></tr></thead>
        <tbody>
          <tr><th><input type="checkbox" data-sc-grid-row-toggle="r1" value="row-r1"></th>
            <td data-sc-grid-row="r1" data-sc-grid-column="c1"><input type="checkbox" data-sc-grid-cell data-sc-grid-row="r1" data-sc-grid-column="c1" value='{"row":"r1","column":"c1"}'></td>
            <td data-sc-grid-row="r1" data-sc-grid-column="c2"><input type="checkbox" data-sc-grid-cell data-sc-grid-row="r1" data-sc-grid-column="c2" value='{"row":"r1","column":"c2"}'></td>
          </tr>
          <tr><th><input type="checkbox" data-sc-grid-row-toggle="r2" value="row-r2"></th>
            <td data-sc-grid-row="r2" data-sc-grid-column="c1"><input type="checkbox" data-sc-grid-cell data-sc-grid-row="r2" data-sc-grid-column="c1" value='{"row":"r2","column":"c1"}'></td>
            <td data-sc-grid-row="r2" data-sc-grid-column="c2"><input type="checkbox" data-sc-grid-cell data-sc-grid-row="r2" data-sc-grid-column="c2" value='{"row":"r2","column":"c2"}'></td>
          </tr>
        </tbody>
      </table>
      <span data-sc-grid-selection-count></span><span data-sc-grid-selection-label></span>
      <p data-sc-grid-selection-help></p><button data-sc-grid-apply type="submit">Apply</button>
      <button data-sc-grid-clear type="button">Clear</button>
    </form>
  `);

  await page.locator('td[data-sc-grid-row="r2"][data-sc-grid-column="c2"]').hover();
  await expect(page.locator('[data-sc-grid-row-toggle="r2"]').locator("xpath=ancestor::th")).toHaveClass(/is-grid-axis-hover/);
  await expect(page.locator('[data-sc-grid-column-toggle="c2"]').locator("xpath=ancestor::th")).toHaveClass(/is-grid-axis-hover/);

  await page.locator('[data-sc-grid-row-toggle="r1"]').click();
  await expect(page.locator('[data-sc-grid-row-toggle="r1"]')).toBeChecked();
  await expect(page.locator('[data-sc-grid-row="r1"] [data-sc-grid-cell]:checked')).toHaveCount(2);
  await expect(page.locator("[data-sc-grid-selection-count]")).toHaveText("2");
  await expect(page.locator('[data-sc-grid-column-toggle="c1"]')).toHaveJSProperty("indeterminate", true);

  await page.evaluate(() => {
    const form = document.querySelector("[data-sc-grid-selection]");
    form.addEventListener("submit", () => {
      window.compactGrid = Array.from(form.querySelectorAll("[data-sc-grid-compact-input]"), input => [input.name, input.value]);
    });
    form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
  });
  expect(await page.evaluate(() => window.compactGrid)).toEqual([["grid_axis", "row-r1"]]);
});

test("row dialog opens and navigates between result rows", async ({page}) => {
  await load(page, `
    <section class="sc-results">
      <div tabindex="0" data-sc-row-click data-sc-row-click-type="iframe_modal" data-sc-row-dialog-id="details" data-sc-row-click-url="/one" data-sc-row-click-title="First">First row</div>
      <div tabindex="0" data-sc-row-click data-sc-row-click-type="iframe_modal" data-sc-row-dialog-id="details" data-sc-row-click-url="/two" data-sc-row-click-title="Second">Second row</div>
      <dialog id="details" data-sc-row-dialog>
        <h2 data-sc-row-dialog-title></h2><span data-sc-row-dialog-position></span>
        <button data-sc-row-dialog-nav="previous"></button><button data-sc-row-dialog-nav="next"></button>
        <a data-sc-row-dialog-open></a><span data-sc-row-dialog-loading></span><iframe data-sc-row-dialog-frame></iframe>
      </dialog>
    </section>
  `);

  await page.locator("[data-sc-row-click]").first().click();
  await expect(page.locator("dialog")).toHaveAttribute("open", "");
  await expect(page.locator("[data-sc-row-dialog-title]")).toHaveText("First");
  await expect(page.locator("[data-sc-row-dialog-position]")).toHaveText("Row 1 of 2 on this page");
  await page.locator('[data-sc-row-dialog-nav="next"]').click();
  await expect(page.locator("[data-sc-row-dialog-title]")).toHaveText("Second");
  await expect(page.locator("[data-sc-row-dialog-frame]")).toHaveAttribute("src", "/two");
});

test("choosing an autocomplete result writes both label and stable value", async ({page}) => {
  await load(page, `
    <div data-sc-action-lookup>
      <input type="hidden" data-sc-lookup-value>
      <input data-sc-lookup-query aria-controls="carrier-results" aria-expanded="true">
      <div id="carrier-results" data-sc-lookup-results>
        <button type="button" data-sc-lookup-option data-sc-lookup-value="42" data-sc-lookup-label="Acme Carrier"><strong>Acme Carrier</strong></button>
      </div>
    </div>
  `);

  await page.locator("[data-sc-lookup-option]").click();
  await expect(page.locator("[data-sc-lookup-value]")).toHaveValue("42");
  await expect(page.locator("[data-sc-lookup-query]")).toHaveValue("Acme Carrier (42)");
  await expect(page.locator("[data-sc-lookup-results]")).toBeHidden();
});
