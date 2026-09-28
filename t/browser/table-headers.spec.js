import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const publicRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components");

async function loadTable(page, {grid = false, toolbar = true} = {}) {
  await page.setViewportSize({width: 1100, height: 700});
  await page.setContent(`
    <style>
      body { margin: 0; ${toolbar ? "--toolbar-bar-height: 60px; --sc-sticky-top: var(--toolbar-bar-height); padding-top: var(--toolbar-bar-height)" : ""} }
      #toolbar { position: fixed; inset: 0 0 auto; height: var(--toolbar-bar-height); background: red; z-index: 1000; }
      main { width: 900px; margin: 0 20px; }
      .spacer { height: 150px; }
      footer { height: 1000px; }
    </style>
    ${toolbar ? '<nav id="toolbar">Toolbar Menu</nav>' : ""}
    <main><div class="spacer">Explorer</div><section class="sc-results">
      <div class="sc-table-wrap ${grid ? "sc-aggregate-grid-wrap" : ""}">
        <table ${grid ? 'class="sc-aggregate-grid"' : ""} style="width:1600px">
          <thead><tr><th id="first-heading"><button>Order ID</button></th><th>Customer</th><th>Destination</th></tr>
            ${grid ? '<tr><th>Period</th><th>Revenue</th><th>Expenses</th></tr>' : ""}</thead>
          <tbody>${Array.from({length: 50}, (_, i) => `<tr>
            ${grid ? "<th>" : "<td>"}${i + 1}${grid ? "</th>" : "</td>"}
            <td>Example customer ${i}</td><td>Destination ${i}</td></tr>`).join("")}</tbody>
        </table>
      </div>
    </section></main><footer></footer>`);
  await page.addStyleTag({path: path.join(publicRoot, "selecto-components.css")});
  await page.addScriptTag({path: path.join(publicRoot, "selecto-components.js")});
}

async function headerTop(page, expected) {
  await expect.poll(() => page.locator(".sc-table-wrap > table > thead").evaluate(head =>
    Math.round(head.getBoundingClientRect().top))).toBe(expected);
  await expect.poll(() => page.locator("#first-heading").evaluate(head =>
    Math.round(head.getBoundingClientRect().top))).toBe(expected);
}

test("Explorer headers stay below a resizing toolbar through vertical and horizontal scrolling", async ({page}) => {
  await loadTable(page);
  await page.evaluate(() => window.scrollTo(0, 450));
  await headerTop(page, 60);
  // The native controls remain visible/clickable, with no duplicate header.
  await expect(page.getByRole("button", {name: "Order ID"})).toHaveCount(1);
  await page.getByRole("button", {name: "Order ID"}).click({trial: true});
  await page.locator(".sc-table-wrap").evaluate(wrap => { wrap.scrollLeft = 400; });
  await expect.poll(() => page.locator("#first-heading").evaluate(head =>
    Math.round(head.getBoundingClientRect().left))).toBe(21);
  await headerTop(page, 60);
  const alignment = await page.locator(".sc-table-wrap").evaluate(wrap => ({
    heading: wrap.querySelector("thead th:nth-child(2)").getBoundingClientRect().left,
    cell: wrap.querySelector("tbody td:nth-child(2)").getBoundingClientRect().left,
  }));
  expect(Math.abs(alignment.heading - alignment.cell)).toBeLessThan(1);

  await page.evaluate(() => document.body.style.setProperty("--toolbar-bar-height", "92px"));
  await headerTop(page, 92);
  await page.evaluate(() => window.scrollTo(0, 260));
  await headerTop(page, 92);
  await page.evaluate(() => window.scrollTo(0, 0));
  await expect.poll(() => page.locator("thead").evaluate(head => head.getBoundingClientRect().top)).toBeGreaterThan(92);

  // A table cannot leave its floating header behind after scrolling past it.
  await page.locator(".sc-table-wrap").evaluate(wrap => window.scrollTo(0,
    wrap.getBoundingClientRect().bottom + window.scrollY + 10));
  await expect.poll(() => page.locator("thead").evaluate(head => head.getBoundingClientRect().bottom)).toBeLessThan(0);
});

test("grid header rows stay together with both page scrolling and inner scrolling", async ({page}) => {
  await loadTable(page, {grid: true});
  await page.evaluate(() => window.scrollTo(0, 300));
  await headerTop(page, 60);
  await page.locator(".sc-table-wrap").evaluate(wrap => { wrap.scrollTop = 320; wrap.scrollLeft = 180; });
  await headerTop(page, 60);
  const rows = await page.locator("thead").evaluate(head => {
    const first = head.rows[0].getBoundingClientRect();
    const second = head.rows[1].getBoundingClientRect();
    return {bottom: first.bottom, next: second.top};
  });
  expect(Math.abs(rows.bottom - rows.next)).toBeLessThan(1);
});

test("replacement results initialize their headers, and standalone views need no host toolbar", async ({page}) => {
  await loadTable(page, {toolbar: false});
  await page.evaluate(() => window.scrollTo(0, 400));
  await headerTop(page, 0);
  await page.evaluate(() => {
    const results = document.querySelector(".sc-results");
    const replacement = results.cloneNode(true);
    replacement.querySelector(".sc-table-wrap").removeAttribute("style");
    results.replaceWith(replacement);
    document.dispatchEvent(new CustomEvent("htmx:after:swap"));
  });
  await headerTop(page, 0);
  await page.evaluate(() => window.scrollTo(0, 300));
  await headerTop(page, 0);
});

test("nested detail headers stay in their row and modal tables keep their own scroll offset", async ({page}) => {
  await loadTable(page);
  await page.evaluate(() => {
    document.querySelector("tbody tr:nth-child(20) td:nth-child(2)").innerHTML =
      '<table class="sc-nested-table"><thead><tr><th>Vehicle</th></tr></thead><tbody><tr><td>Example</td></tr></tbody></table>';
    const dialog = document.createElement("dialog");
    dialog.innerHTML = '<div class="sc-table-wrap"><table><thead><tr><th>Dialog heading</th></tr></thead><tbody><tr><td>Value</td></tr></tbody></table></div>';
    document.body.appendChild(dialog);
    document.dispatchEvent(new CustomEvent("htmx:after:swap"));
    window.scrollTo(0, 400);
  });
  await expect.poll(() => page.locator(".sc-nested-table th").evaluate(head =>
    head.getBoundingClientRect().top)).toBeGreaterThan(60);
  await expect(page.locator(".sc-nested-table th")).toHaveCSS("position", "static");
  await page.locator("dialog").evaluate(dialog => dialog.showModal());
  await expect(page.locator("dialog .sc-table-wrap")).not.toHaveAttribute("style", /--sc-table-header-offset/);
  const bounds = await page.locator("dialog .sc-table-wrap").evaluate(wrap => ({
    wrap: wrap.getBoundingClientRect().top + wrap.clientTop,
    head: wrap.querySelector("thead").getBoundingClientRect().top,
  }));
  expect(Math.abs(bounds.head - bounds.wrap)).toBeLessThan(1);
});
