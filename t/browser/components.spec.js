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

test("columns and filters can add the same field more than once", async ({page}) => {
  await load(page, `
    <form data-sc-builder>
      <div data-sc-picker-root data-sc-picker-kind="field" data-sc-picker-max="10">
        <div data-sc-picker-available>
          <button type="button" data-sc-picker-action="add" data-sc-picker-available-item
            data-sc-picker-repeatable data-field="created_on" data-label="Created"
            data-type="datetime" data-search="created datetime">Add Created</button>
        </div>
        <span data-sc-picker-available-count></span><span data-sc-picker-set-count></span>
        <div data-sc-picker-set><p class="sc-picker-empty">Choose fields.</p></div>
      </div>
      <div data-sc-filter-root data-sc-filter-max="10">
        <div data-sc-filter-available>
          <button type="button" data-sc-filter-action="add" data-sc-filter-available-item
            data-field="created_on" data-label="Created" data-type="datetime"
            data-search="created datetime">Add Created filter</button>
        </div>
        <span data-sc-filter-available-count></span><span data-sc-filter-set-count></span>
        <div data-sc-filter-set><p class="sc-picker-empty">Choose filters.</p></div>
      </div>
    </form>
  `);

  const addColumn = page.locator('[data-sc-picker-action="add"]');
  await addColumn.click();
  await addColumn.click();
  await expect(page.locator('[data-sc-picker-set-item][data-field="created_on"]')).toHaveCount(2);
  await expect(addColumn).toBeVisible();

  const addFilter = page.locator('[data-sc-filter-action="add"]');
  await addFilter.click();
  await addFilter.click();
  await expect(page.locator('[data-sc-filter-set-item][data-field="created_on"]')).toHaveCount(2);
  await expect(addFilter).toBeVisible();
});

test("an export uses the columns currently selected in the builder", async ({page}) => {
  await load(page, `
    <section id="selecto-surface-truck">
      <a data-sc-export-format="tsv" href="/explorer/truck?q=1&format=tsv">TSV</a>
      <form data-sc-builder action="http://selecto.test/explorer/truck">
        <input name="q" value="1"><input name="view" value="detail">
        <input name="field" value="vin"><input name="field" value="lic_no">
        <input name="filter_field" value="status"><input name="filter_op" value="eq">
        <input name="filter_value" value="at">
      </form>
    </section>
  `);

  const href = await page.evaluate(() => {
    const link = document.querySelector("[data-sc-export-format]");
    link.addEventListener("click", (event) => event.preventDefault(), {once: true});
    link.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
    return link.href;
  });
  const url = new URL(href, "http://selecto.test");
  expect(url.pathname).toBe("/explorer/truck");
  expect(url.searchParams.getAll("field")).toEqual(["vin", "lic_no"]);
  expect(url.searchParams.get("filter_field")).toBe("status");
  expect(url.searchParams.get("filter_value")).toBe("at");
  expect(url.searchParams.get("format")).toBe("tsv");
});

test("a back-forward cache restore preserves results and reconnects without a query", async ({page}) => {
  await load(page, `
    <section id="selecto-channel-orders" hx-ws:connect="/explore/orders/ws">
      <span data-selecto-connection class="is-live">Live</span>
      <form><input name="query_library_view" value="late-orders"></form>
      <div data-saved-results>Previously loaded rows</div>
    </section>
  `);

  const restored = await page.evaluate(() => {
    const originalChannel = document.querySelector("#selecto-channel-orders");
    const originalResults = document.querySelector("[data-saved-results]");
    let processCalls = 0;
    window.htmx = {process() { processCalls += 1; }};
    const event = new Event("pageshow");
    Object.defineProperty(event, "persisted", {value: true});
    window.dispatchEvent(event);
    return {
      channelReplaced: originalChannel !== document.querySelector("#selecto-channel-orders"),
      resultsPreserved: originalResults === document.querySelector("[data-saved-results]"),
      processCalls,
      savedView: document.querySelector('[name="query_library_view"]').value,
      resultsText: document.querySelector("[data-saved-results]").textContent,
    };
  });

  expect(restored).toEqual({
    channelReplaced: true,
    resultsPreserved: true,
    processCalls: 1,
    savedView: "late-orders",
    resultsText: "Previously loaded rows",
  });
  await expect(page.locator("[data-selecto-connection]")).toHaveText("Connecting");
});

test("Back restores the previous applied query without rerunning it", async ({page}) => {
  let documentRequests = 0;
  await page.route("http://selecto.test/**", async route => {
    documentRequests += 1;
    await route.fulfill({contentType: "text/html", body: `
      <section id="selecto-channel-orders" hx-ws:connect="/explore/orders/ws">
        <span data-selecto-connection class="is-live">Live</span>
        <section id="selecto-surface-orders">
          <div data-sc-workspace>
            <form data-sc-grid-selection data-sc-grid-max="10">
              <input type="checkbox" checked data-sc-grid-cell data-sc-grid-row="late" data-sc-grid-column="east">
            </form>
            <section class="sc-results"><div data-grid-results>Saved grid results</div></section>
          </div>
        </section>
      </section>
    `});
  });
  await page.goto("http://selecto.test/explore/orders?query_library_view=test-grid");
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => {
    window.htmx = {process() {}};
    document.dispatchEvent(new Event("DOMContentLoaded"));
    window.dispatchEvent(new Event("pagehide"));
    document.querySelector("#selecto-surface-orders").outerHTML = `
      <section id="selecto-surface-orders">
        <div data-sc-workspace><section class="sc-results">
          <div data-detail-results>Selected-cell details</div>
        </section></div>
      </section>`;
    document.dispatchEvent(new CustomEvent("htmx:ws:after:message:incoming", {
      detail: {message: {json: () => Promise.resolve({
        selecto: {url: "/explore/orders?view=detail&grid_cell=late-east"}
      })}}
    }));
  });

  await expect.poll(() => page.url()).toContain("view=detail");
  await expect(page.locator("[data-detail-results]")).toHaveText("Selected-cell details");
  await page.goBack();
  await expect(page.locator("[data-grid-results]")).toHaveText("Saved grid results");
  await expect(page.locator("[data-sc-grid-cell]")).toBeChecked();
  expect(page.url()).toContain("query_library_view=test-grid");
  expect(documentRequests).toBe(1);
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

test("record editor saves through the governed endpoint and replaces the result row", async ({page}) => {
  await page.route("https://selecto.test/**", async route => {
    const request = route.request();
    if (request.url().endsWith("/editor/101") && request.method() === "GET") {
      return route.fulfill({status: 200, contentType: "text/html", body: `
        <form action="https://selecto.test/editor/101" data-sc-record-editor-form>
          <label data-sc-record-editor-field="product_name">Name
            <input name="editor_field_product_name" value="Old name" required>
            <small data-sc-record-editor-error hidden></small>
          </label>
          <div data-sc-record-editor-result hidden></div>
          <button type="submit" data-sc-record-editor-save disabled>Save changes</button>
        </form>`});
    }
    if (request.url().endsWith("/editor/101") && request.method() === "POST") {
      return route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({
        ok: true, row_id: "101", authorized: 1,
        changed_fields: ["product_name"], return_to: "https://selecto.test/results",
        message: "Updated"
      })});
    }
    return route.fulfill({status: 200, contentType: "text/html", body: `
      <table><tbody><tr data-sc-record-id="101" data-sc-row-click
        data-sc-row-click-type="record_editor" data-sc-row-dialog-id="editor-dialog"
        data-sc-row-click-url="https://selecto.test/editor/101"><td>New name</td></tr></tbody></table>`});
  });
  await load(page, `
    <section class="sc-results"><table><tbody><tr tabindex="0" data-sc-record-id="101"
      data-sc-row-click data-sc-row-click-type="record_editor" data-sc-row-dialog-id="editor-dialog"
      data-sc-row-click-url="https://selecto.test/editor/101" data-sc-row-click-title="Edit product">
      <td>Old name</td></tr></tbody></table>
      <dialog id="editor-dialog" data-sc-row-dialog data-sc-row-dialog-kind="record_editor">
        <h2 data-sc-row-dialog-title></h2><span data-sc-row-dialog-position></span>
        <button data-sc-row-dialog-nav="previous"></button><button data-sc-row-dialog-nav="next"></button>
        <span data-sc-row-dialog-loading hidden></span><div data-sc-row-editor-body></div>
      </dialog>
    </section>`);

  await page.locator("[data-sc-record-id='101']").click();
  await expect(page.locator("[data-sc-record-editor-form]")).toBeVisible();
  await expect(page.locator("[data-sc-record-editor-save]")).toBeDisabled();
  await page.locator('[name="editor_field_product_name"]').fill("New name");
  await expect(page.locator("[data-sc-record-editor-save]")).toBeEnabled();
  await page.locator("[data-sc-record-editor-save]").click();
  await expect(page.locator("[data-sc-record-id='101'] td")).toHaveText("New name");
  await expect(page.locator("#editor-dialog")).not.toHaveAttribute("open", "");
});

test("a row that no longer matches keeps its column cells and uses a spanning notice", async ({page}) => {
  await page.route("https://selecto.test/**", async route => {
    const request = route.request();
    if (request.url().endsWith("/editor/303") && request.method() === "GET") {
      return route.fulfill({status: 200, contentType: "text/html", body: `
        <form action="https://selecto.test/editor/303" data-sc-record-editor-form>
          <input name="editor_field_status" value="Open">
          <div data-sc-record-editor-result hidden></div>
          <button type="submit" data-sc-record-editor-save disabled>Save changes</button>
        </form>`});
    }
    if (request.url().endsWith("/editor/303") && request.method() === "POST") {
      return route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({
        ok: true, row_id: "303", authorized: 1, changed_fields: ["status"],
        return_to: "https://selecto.test/results", message: "Updated"
      })});
    }
    return route.fulfill({status: 200, contentType: "text/html", body: `
      <table><tbody><tr data-sc-record-id="999"><td>Different row</td><td>Open</td></tr></tbody></table>`});
  });
  await load(page, `
    <section class="sc-results"><table><tbody><tr tabindex="0" data-sc-record-id="303"
      data-sc-row-click data-sc-row-click-type="record_editor" data-sc-row-dialog-id="editor-dialog"
      data-sc-row-click-url="https://selecto.test/editor/303">
      <td>Truck 303</td><td>Open</td></tr></tbody></table>
      <dialog id="editor-dialog" data-sc-row-dialog data-sc-row-dialog-kind="record_editor">
        <span data-sc-row-dialog-position></span><button data-sc-row-dialog-nav="previous"></button>
        <button data-sc-row-dialog-nav="next"></button><span data-sc-row-dialog-loading hidden></span>
        <div data-sc-row-editor-body></div></dialog></section>`);

  await page.locator("[data-sc-record-id='303']").click();
  await page.locator('[name="editor_field_status"]').fill("Closed");
  await page.locator("[data-sc-record-editor-save]").click();
  const row = page.locator("[data-sc-record-id='303']");
  await expect(row.locator("td")).toHaveCount(2);
  await expect(row.locator("td").first()).toHaveText("Truck 303");
  await expect(row.locator(".sc-row-retired-badge")).toHaveCount(0);
  const notice = row.locator("xpath=following-sibling::tr[1]");
  await expect(notice).toHaveClass(/sc-row-retired-notice/);
  await expect(notice.locator("td")).toHaveAttribute("colspan", "2");
  await expect(notice.locator(".sc-row-retired-badge"))
    .toHaveText("Updated — no longer matches this result");
  await expect(notice.locator("[data-sc-refresh-results]")).toBeVisible();
});

test("a record that leaves authorization remains as a minimal inert tombstone", async ({page}) => {
  await page.route("https://selecto.test/**", async route => {
    if (route.request().method() === "GET") {
      return route.fulfill({status: 200, contentType: "text/html", body: `
        <form action="https://selecto.test/editor/202" data-sc-record-editor-form>
          <input name="editor_field_product_name" value="Restricted value">
          <div data-sc-record-editor-result hidden></div>
          <button type="submit" data-sc-record-editor-save disabled>Save changes</button>
        </form>`});
    }
    return route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({
      ok: true, row_id: "202", authorized: 0, changed_fields: ["product_name"],
      return_to: "https://selecto.test/results", message: "Updated"
    })});
  });
  await load(page, `
    <section class="sc-results"><table><tbody><tr tabindex="0" data-sc-record-id="202"
      data-sc-row-click data-sc-row-click-type="record_editor" data-sc-row-dialog-id="editor-dialog"
      data-sc-row-click-url="https://selecto.test/editor/202"><td>Restricted value</td><td>Secret</td></tr>
      </tbody></table><dialog id="editor-dialog" data-sc-row-dialog data-sc-row-dialog-kind="record_editor">
        <span data-sc-row-dialog-position></span><button data-sc-row-dialog-nav="previous"></button>
        <button data-sc-row-dialog-nav="next"></button><span data-sc-row-dialog-loading hidden></span>
        <div data-sc-row-editor-body></div></dialog></section>`);

  await page.locator("[data-sc-record-id='202']").click();
  await page.locator('[name="editor_field_product_name"]').fill("Hidden now");
  await page.locator("[data-sc-record-editor-save]").click();
  const row = page.locator("[data-sc-record-id='202']");
  await expect(row).toHaveAttribute("aria-disabled", "true");
  await expect(row).not.toHaveAttribute("data-sc-row-click", "");
  await expect(row).not.toContainText("Secret");
  await expect(row.locator(".sc-row-retired-badge")).toHaveText("Updated — no longer available");
  await expect(row.locator("[data-sc-refresh-results]")).toBeVisible();
});

test("record editor actions open one compact form on demand", async ({page}) => {
  await load(page, `
    <section class="sc-record-editor-actions">
      <header><h4>Operational actions</h4></header>
      <div class="sc-record-editor-action-buttons">
        <button type="button" data-sc-record-editor-action-open="action-note"
          aria-controls="action-note" aria-expanded="false">Add note</button>
        <button type="button" data-sc-record-editor-action-open="action-status"
          aria-controls="action-status" aria-expanded="false">Set status</button>
      </div>
      <div class="sc-record-editor-action-panels">
        <form id="action-note" data-sc-record-editor-action-panel hidden>
          <input name="note"><button type="button" data-sc-record-editor-action-close>Back to actions</button>
        </form>
        <form id="action-status" data-sc-record-editor-action-panel hidden>
          <select name="status"><option>Active</option></select>
          <button type="button" data-sc-record-editor-action-close>Back to actions</button>
        </form>
      </div>
    </section>`);

  await expect(page.locator("[data-sc-record-editor-action-panel]:visible")).toHaveCount(0);
  await page.getByRole("button", {name: "Add note"}).click();
  await expect(page.locator("#action-note")).toBeVisible();
  await expect(page.locator("#action-status")).toBeHidden();
  await expect(page.getByRole("button", {name: "Add note"})).toHaveAttribute("aria-expanded", "true");
  await page.locator("#action-note [data-sc-record-editor-action-close]").click();
  await expect(page.locator("#action-note")).toBeHidden();
  await expect(page.getByRole("button", {name: "Add note"})).toBeFocused();
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

test("a row action dialog targets only the row whose button opened it", async ({page}) => {
  await load(page, `
    <section class="sc-results">
      <div data-sc-bulk-action data-sc-action-id="assign_equipment"
        data-sc-action-mode="row-dialog" data-sc-action-max-rows="1"
        data-sc-action-submit-label="Assign equipment">
        <dialog id="assign-equipment-dialog" data-sc-action-dialog>
          <form action="/actions/assign-equipment" data-sc-action-form>
            <div data-sc-action-targets></div>
            <input name="action_input_driver_id" required>
            <div data-sc-action-result hidden></div>
            <footer>
              <button type="button" data-sc-action-close>Cancel</button>
              <button type="submit">Assign equipment</button>
            </footer>
          </form>
        </dialog>
      </div>
      <table><tbody>
        <tr><td><button type="button" data-sc-action-open="assign-equipment-dialog"
          data-sc-action-id="assign_equipment" data-sc-row-action-target="101">Assign</button></td></tr>
        <tr><td><button type="button" data-sc-action-open="assign-equipment-dialog"
          data-sc-action-id="assign_equipment" data-sc-row-action-target="202">Assign</button></td></tr>
      </tbody></table>
    </section>
  `);

  await page.locator("[data-sc-row-action-target='202']").click();
  await expect(page.locator("[data-sc-action-dialog]")).toHaveAttribute("open", "");
  await expect(page.locator("[data-sc-action-targets] input[name='selected_id']")).toHaveCount(1);
  await expect(page.locator("[data-sc-action-targets] input[name='selected_id']")).toHaveValue("202");
});

test("an inline row action submits only the row containing its form", async ({page}) => {
  await load(page, `
    <section class="sc-results">
      <div data-sc-bulk-action data-sc-action-id="set_odometer"
        data-sc-action-mode="row-inline" data-sc-action-max-rows="1"
        data-sc-action-submit-label="Record" data-sc-row-id="101">
        <form action="/actions/set-odometer" data-sc-action-form>
          <div data-sc-action-targets></div>
          <input name="action_input_odometer" value="12000" required>
          <div data-sc-action-result hidden></div>
          <button type="submit">Record</button>
        </form>
      </div>
      <div data-sc-bulk-action data-sc-action-id="set_odometer"
        data-sc-action-mode="row-inline" data-sc-action-max-rows="1"
        data-sc-action-submit-label="Record" data-sc-row-id="202">
        <form action="/actions/set-odometer" data-sc-action-form>
          <div data-sc-action-targets></div>
          <input name="action_input_odometer" value="34000" required>
          <div data-sc-action-result hidden></div>
          <button type="submit">Record</button>
        </form>
      </div>
    </section>
  `);
  await page.evaluate(() => {
    window.fetch = async (_url, options) => {
      window.submittedAction = Array.from(options.body.entries());
      return {ok: true, json: async () => ({ok: true, message: "Recorded"})};
    };
  });

  await page.locator("[data-sc-row-id='202'] button[type='submit']").click();
  await expect.poll(() => page.evaluate(() => window.submittedAction)).toContainEqual(["selected_id", "202"]);
  expect(await page.evaluate(() => window.submittedAction)).not.toContainEqual(["selected_id", "101"]);
  await expect(page.locator("[data-sc-row-id='202'] [data-sc-action-result]")).toContainText("Recorded");
});

test("Copy SQL copies the standalone interpolated statement", async ({page}) => {
  await load(page, `
    <button type="button" data-sc-debug-copy="parameterized"
      data-sc-debug-copy-source="standalone">Copy SQL</button>
    <pre id="parameterized">SELECT * FROM load WHERE id = $1</pre>
    <pre id="standalone" hidden>SELECT * FROM load WHERE id = E'42'</pre>
  `);
  await page.evaluate(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {writeText(text) { window.copiedDebugSql = text; return Promise.resolve(); }},
    });
  });

  await page.locator("[data-sc-debug-copy]").click();
  await expect.poll(() => page.evaluate(() => window.copiedDebugSql)).toBe(
    "SELECT * FROM load WHERE id = E'42'"
  );
  await expect(page.locator("[data-sc-debug-copy]")).toHaveText("Copied");
});
