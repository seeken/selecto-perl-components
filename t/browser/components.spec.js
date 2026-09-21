import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components/selecto-components.js");
const htmxBundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components/htmx.min.js");
const websocketBundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components/hx-ws.min.js");

async function load(page, html) {
  await page.setContent(html);
  await page.addScriptTag({path: bundle});
}

test("a live Explorer builder sends its complete query over the WebSocket", async ({page}) => {
  await page.route("http://selecto.test/**", route => route.fulfill({
    contentType: "text/html",
    body: `
      <section id="selecto-channel-quotes" hx-ext="ws" hx-ws:connect="/explorer/quote/ws">
        <span data-selecto-connection>Connecting</span>
        <section id="selecto-surface-quotes">
          <div data-sc-workspace>
            <aside data-sc-builder-shell="quotes" data-sc-builder-collapsed="false">
              <form action="/explorer/quote" method="get" hx-ws:send hx-trigger="submit"
                data-sc-builder="quotes">
                <input name="q" value="1">
                <input name="view" value="detail">
                <input name="field" value="id">
                <input name="query_library_segment" value="active">
                <input name="page" value="1">
                <button type="submit">Run query</button>
              </form>
            </aside>
            <section id="selecto-results-quotes" class="sc-results">Quote rows</section>
          </div>
        </section>
      </section>
    `,
  }));
  await page.addInitScript(() => {
    class FakeWebSocket extends EventTarget {
      static CONNECTING = 0;
      static OPEN = 1;
      static CLOSING = 2;
      static CLOSED = 3;
      constructor(url) {
        super();
        this.url = url;
        this.readyState = FakeWebSocket.CONNECTING;
        window.fakeSelectoSocket = this;
        queueMicrotask(() => {
          this.readyState = FakeWebSocket.OPEN;
          this.dispatchEvent(new Event("open"));
        });
      }
      send(message) {
        window.fakeSelectoMessages ||= [];
        window.fakeSelectoMessages.push(message);
      }
      close() {
        this.readyState = FakeWebSocket.CLOSED;
        this.dispatchEvent(new CloseEvent("close", {code: 1000}));
      }
    }
    window.WebSocket = FakeWebSocket;
  });
  await page.goto("http://selecto.test/explorer/quote");
  await page.addScriptTag({path: htmxBundle});
  await page.addScriptTag({path: websocketBundle});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => {
    window.htmx.process(document.body);
    document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true}));
  });
  await expect(page.locator("[data-selecto-connection]")).toHaveText("Live");

  await page.locator('button[type="submit"]').click();

  await expect.poll(() => page.evaluate(() => window.fakeSelectoMessages?.length || 0)).toBe(1);
  const payload = await page.evaluate(() => JSON.parse(window.fakeSelectoMessages[0]));
  expect(payload).toMatchObject({
    q: "1",
    view: "detail",
    field: "id",
    query_library_segment: "active",
    render_scope: "results",
  });
});

test("a missing WebSocket connection falls back to the complete HTTP query", async ({page}) => {
  await load(page, `
    <section hx-ws:connect="/explorer/truck/ws">
      <span data-selecto-connection class="is-live">Live</span>
      <form action="/explorer/truck" method="get" hx-ws:send data-sc-builder>
        <input name="q" value="1">
        <input name="field" value="id">
        <input name="selecto_request_id" value="selecto-stale-request">
        <button type="submit">Run query</button>
      </form>
    </section>
  `);
  await page.evaluate(() => {
    HTMLFormElement.prototype.submit = function () {
      window.selectoHttpFallback = {
        action: this.getAttribute("action"),
        values: Array.from(new FormData(this).entries()),
      };
    };
    const form = document.querySelector("[data-sc-builder]");
    form.dispatchEvent(new CustomEvent("htmx:ws:error", {
      bubbles: true,
      detail: {error: "Connection not open"},
    }));
  });

  await expect.poll(() => page.evaluate(() => window.selectoHttpFallback)).not.toBeNull();
  expect(await page.evaluate(() => window.selectoHttpFallback)).toEqual({
    action: "/explorer/truck",
    values: [["q", "1"], ["field", "id"]],
  });
  await expect(page.locator("[data-selecto-connection]")).toHaveText("Reconnecting");
});

test("a message error does not mark an open WebSocket as reconnecting", async ({page}) => {
  await load(page, `
    <section hx-ws:connect="/explorer/truck/ws">
      <span data-selecto-connection>Connecting</span>
      <form hx-ws:send><button>Run</button></form>
    </section>
  `);
  await page.evaluate(() => {
    const connection = {socket: {readyState: WebSocket.OPEN}};
    const channel = document.querySelector('[hx-ws\\:connect]');
    channel._htmx = {ws: {connection}};
    channel.querySelector("form").dispatchEvent(new CustomEvent("htmx:ws:error", {
      bubbles: true,
      detail: {connection, error: new Error("response swap failed")},
    }));
  });

  await expect(page.locator("[data-selecto-connection]")).toHaveText("Live");
  await expect(page.locator("[data-selecto-connection]")).toHaveClass(/is-live/);
});

test("a closed hosted channel is rebuilt without rerunning its query", async ({page}) => {
  await load(page, `
    <section id="selecto-channel-trucks" hx-ext="ws" hx-ws:connect="/explorer/truck/ws">
      <span data-selecto-connection class="is-live">Live</span>
      <form action="/explorer/truck" method="get" hx-ws:send data-sc-builder>
        <input name="field" value="id">
        <button type="submit">Run query</button>
      </form>
    </section>
  `);
  await page.evaluate(() => {
    window.selectoRecoveryProcessCalls = 0;
    window.selectoUnexpectedSubmits = 0;
    window.htmx = {
      process(channel) {
        window.selectoRecoveryProcessCalls += 1;
        const connection = {socket: {readyState: WebSocket.OPEN}};
        channel._htmx = {ws: {connection}};
        channel.dispatchEvent(new CustomEvent("htmx:ws:after:connection", {
          bubbles: true,
          detail: {connection},
        }));
      },
    };
    document.querySelector("form").addEventListener("submit", () => {
      window.selectoUnexpectedSubmits += 1;
    });
    const channel = document.querySelector("#selecto-channel-trucks");
    const connection = {socket: {readyState: WebSocket.CLOSED}};
    channel._htmx = {ws: {connection}};
    channel.dispatchEvent(new CustomEvent("htmx:ws:close", {
      bubbles: true,
      detail: {connection, code: 1000},
    }));
  });

  await expect.poll(() => page.evaluate(() => window.selectoRecoveryProcessCalls)).toBe(1);
  await expect(page.locator("[data-selecto-connection]")).toHaveText("Live");
  await expect(page.locator('input[name="field"]')).toHaveValue("id");
  expect(await page.evaluate(() => window.selectoUnexpectedSubmits)).toBe(0);
});

test("a completed query refreshes the API console link outside the results swap", async ({page}) => {
  await load(page, `
    <section id="selecto-surface-loads">
      <a data-sc-api-console href="/api2/load/v1/console#request=old">API</a>
      <section id="selecto-results-loads">Rows</section>
    </section>
  `);
  await page.evaluate(() => {
    document.dispatchEvent(new CustomEvent("htmx:ws:after:message:incoming", {
      detail: {message: {json: () => Promise.resolve({
        selecto: {
          url: "/explorer/load?q=1&query_library_segment=unassigned",
          api_console_control: '<a class="sc-button sc-secondary" data-sc-api-console ' +
            'target="_blank" rel="noopener" ' +
            'href="/api2/load/v1/console#request=with-segment">API</a>',
        },
      })}},
    }));
  });

  await expect(page.locator("[data-sc-api-console]"))
    .toHaveAttribute("href", "/api2/load/v1/console#request=with-segment");
  await expect(page.locator("[data-sc-api-console]"))
    .toHaveAttribute("target", "_blank");
});

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

test("columns, measures, and filters can add the same field more than once", async ({page}) => {
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
      <div data-sc-picker-root data-sc-picker-kind="measure" data-sc-picker-max="10">
        <div data-sc-picker-available>
          <button type="button" data-sc-picker-action="add" data-sc-picker-available-item
            data-sc-picker-repeatable data-field="customer_price" data-label="Customer Price"
            data-type="decimal" data-default-function="sum"
            data-search="customer price decimal">Add Customer Price</button>
        </div>
        <span data-sc-picker-available-count></span><span data-sc-picker-set-count></span>
        <div data-sc-picker-set><p class="sc-picker-empty">Choose measures.</p></div>
      </div>
    </form>
  `);

  const addColumn = page.locator('[data-sc-picker-kind="field"] [data-sc-picker-action="add"]');
  await addColumn.click();
  await addColumn.click();
  await expect(page.locator('[data-sc-picker-set-item][data-field="created_on"]')).toHaveCount(2);
  await expect(addColumn).toBeVisible();

  const addMeasure = page.locator('[data-sc-picker-kind="measure"] [data-sc-picker-action="add"]');
  await addMeasure.click();
  await addMeasure.click();
  await expect(page.locator(
    '[data-sc-picker-kind="measure"] [data-sc-picker-set-item][data-field="customer_price"]'
  )).toHaveCount(2);
  await expect(page.locator('[data-sc-picker-kind="measure"] select[name="measure_chart_type"]')).toHaveCount(2);
  await expect(page.locator('[data-sc-picker-kind="measure"] select[name="measure_axis"]')).toHaveCount(2);
  await expect(page.locator('[data-sc-picker-kind="measure"] input[name="measure_stack"]')).toHaveCount(2);
  await expect(page.locator('[data-sc-picker-kind="measure"] input[name="measure_color"]')).toHaveCount(2);
  expect(await page.locator('[data-sc-picker-kind="measure"] select[name="measure_ignore_nulls"]')
    .evaluateAll(selects => selects.map(select => select.value))).toEqual(["auto", "auto"]);
  await expect(page.locator('[data-sc-picker-kind="measure"] select[name="measure_transform"]')).toHaveCount(2);
  expect(await page.locator('[data-sc-picker-kind="measure"] input[name="measure_series_id"]')
    .evaluateAll(inputs => inputs.map(input => input.value))).toEqual(["series_1", "series_2"]);
  await page.locator('[data-sc-picker-kind="measure"] details').first().locator("summary").click();
  const autoColor = page.locator('[data-sc-picker-kind="measure"] [data-sc-measure-color-auto]').first();
  const colorPicker = page.locator('[data-sc-picker-kind="measure"] [data-sc-measure-color-picker]').first();
  await expect(autoColor).toBeChecked();
  await expect(colorPicker).toBeDisabled();
  await autoColor.uncheck();
  await expect(colorPicker).toBeEnabled();
  await colorPicker.fill("#123456");
  await expect(page.locator('[data-sc-picker-kind="measure"] input[name="measure_color"]').first())
    .toHaveValue("#123456");
  const firstTransform = page.locator('[data-sc-picker-kind="measure"] select[name="measure_transform"]').first();
  await firstTransform.selectOption("moving_average");
  await expect(page.locator('[data-sc-picker-kind="measure"] [data-sc-measure-transform-window]').first())
    .toBeVisible();
  await expect(addMeasure).toBeVisible();

  const addFilter = page.locator('[data-sc-filter-action="add"]');
  await addFilter.click();
  await addFilter.click();
  await expect(page.locator('[data-sc-filter-set-item][data-field="created_on"]')).toHaveCount(2);
  await expect(addFilter).toBeVisible();
});

test("date-only values remain stable for datetime filters", async ({page}) => {
  await load(page, `
    <article data-sc-filter-set-item data-field="timestamp" data-label="Created"
      data-type="utc_datetime">
      <div class="sc-filter-editor">
        <select name="filter_op">
          <option value="gte" selected>on or after</option>
          <option value="lt">before</option>
        </select>
        <div data-sc-filter-values>
          <input type="date" name="filter_value" value="2024-10-01">
          <input type="hidden" name="filter_value_end" value="">
        </div>
      </div>
    </article>
  `);

  await page.locator('[name="filter_op"]').selectOption("lt");
  await expect(page.locator('[name="filter_value"]')).toHaveAttribute("type", "date");
  await expect(page.locator('[name="filter_value"]')).toHaveValue("2024-10-01");
});

test("mixed graph series configure independent left and right axes", async ({page}) => {
  await page.setContent(`
    <div data-sc-chart data-chart-type="bar"
      data-chart-data='{"labels":["Jan","Feb"],"axes":{"y":{"side":"left","label":"Count","unit":{"kind":"count"}},"y1":{"side":"right","label":"USD","unit":{"kind":"currency","code":"USD"},"stacked":true}},"datasets":[{"label":"Loads","data":[2,4],"rawData":[2,4],"unit":{"kind":"count"},"type":"bar","scType":"bar","yAxisID":"y"},{"label":"Revenue","data":[10,15],"rawData":[10,20],"unit":{"kind":"currency","code":"USD"},"transforms":["moving_average"],"type":"line","scType":"line","yAxisID":"y1"},{"label":"Carrier pay","data":[4,5],"unit":{"kind":"currency","code":"USD"},"type":"bar","scType":"bar","yAxisID":"y1","stack":"expenses"},{"label":"Driver pay","data":[2,3],"unit":{"kind":"currency","code":"USD"},"type":"bar","scType":"bar","yAxisID":"y1","stack":"expenses"}]}'
    ><canvas></canvas>
      <form data-sc-graph-drilldown="1"><button>Drill down</button></form>
    </div>
  `);
  await page.evaluate(() => {
    window.Chart = function (_canvas, config) {
      window.capturedChartConfig = config;
      window.capturedCurrencyTick = config.options.scales.y1.ticks.callback(1234.5);
      window.capturedCurrencyTooltip = config.options.plugins.tooltip.callbacks.label({
        dataset: config.data.datasets[1], parsed: {y: 15}, raw: 15
      });
      this.destroy = function () {};
    };
    window.Chart.register = function () {};
    window.Chart.getChart = function () { return null; };
    window.Chart.version = "test";
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => Boolean(window.capturedChartConfig))).toBe(true);
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  await expect(page.locator("[data-sc-chart]")).toHaveAttribute("aria-busy", "false");
  const chart = await page.evaluate(() => window.capturedChartConfig);
  expect(chart.data.datasets.map(dataset => [dataset.type, dataset.yAxisID, dataset.stack || ""]))
    .toEqual([
      ["bar", "y", ""], ["line", "y1", ""],
      ["bar", "y1", "expenses"], ["bar", "y1", "expenses"]
    ]);
  expect(chart.options.scales.y.position).toBe("left");
  expect(chart.options.scales.y1.position).toBe("right");
  expect(chart.options.scales.y1.stacked).toBe(true);
  expect(chart.options.scales.x.stacked).toBe(true);
  expect(chart.options.scales.y1.grid.drawOnChartArea).toBe(false);
  expect(await page.evaluate(() => window.capturedCurrencyTick)).toContain("1,234.5");
  expect(await page.evaluate(() => window.capturedCurrencyTooltip)).toContain("Revenue:");
  const axisDrilldown = await page.evaluate(() => {
    const form = document.querySelector('[data-sc-graph-drilldown="1"]');
    let submitted = false;
    form.addEventListener("submit", event => {
      event.preventDefault();
      submitted = true;
    });
    const chart = {
      canvas: {style: {}},
      scales: {x: {
        top: 100, bottom: 140, left: 20, right: 220,
        getValueForPixel: () => 1
      }}
    };
    window.capturedChartConfig.options.onHover({x: 120, y: 120}, [], chart);
    const cursor = chart.canvas.style.cursor;
    window.capturedChartConfig.options.onClick({x: 120, y: 120}, [], chart);
    return {submitted, cursor};
  });
  expect(axisDrilldown).toEqual({submitted: true, cursor: "pointer"});
});

test("a chart initialization failure reveals the fallback without flashing it first", async ({page}) => {
  await page.setContent(`
    <div data-sc-chart data-chart-type="bar" data-chart-data='{"labels":["Jan"],"datasets":[]}'
      aria-busy="true">
      <div class="sc-chart-canvas"><canvas></canvas></div>
      <div class="sc-chart-fallback">Fallback values</div>
    </div>
  `);
  await page.evaluate(() => {
    window.Chart = function () { throw new Error("chart failed"); };
    window.Chart.register = function () {};
    window.Chart.getChart = function () { return null; };
    window.Chart.version = "test";
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-fallback/);
  await expect(page.locator("[data-sc-chart]")).not.toHaveClass(/is-ready/);
  await expect(page.locator("[data-sc-chart]")).toHaveAttribute("aria-busy", "false");
  await expect(page.locator("[data-sc-chart-error-notice]")).toBeVisible();
  await page.evaluate(() => {
    window.Chart = function () { this.destroy = function () {}; };
    window.Chart.register = function () {};
    window.Chart.getChart = function () { return null; };
    window.Chart.version = "test";
  });
  await page.locator("[data-sc-chart-retry]").click();
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  await expect(page.locator("[data-sc-chart-error-notice]")).toBeHidden();
});

test("a transient chart initialization failure retries automatically", async ({page}) => {
  await page.setContent(`
    <div data-sc-chart data-chart-type="bar" data-chart-data='{"labels":["Jan"],"datasets":[]}'
      aria-busy="true">
      <div class="sc-chart-canvas"><canvas></canvas></div>
      <div class="sc-chart-fallback">Fallback values</div>
    </div>
  `);
  await page.evaluate(() => {
    window.chartAttempts = 0;
    window.Chart = function () {
      window.chartAttempts += 1;
      if (window.chartAttempts === 1) throw new Error("layout was not ready");
      this.destroy = function () {};
    };
    window.Chart.register = function () {};
    window.Chart.getChart = function () { return null; };
    window.Chart.version = "test";
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  expect(await page.evaluate(() => window.chartAttempts)).toBe(2);
});

test("a legacy Chart global does not prevent Chart.js from loading", async ({page}) => {
  await page.setContent(`
    <section data-sc-chart-src>
      <div data-sc-chart data-chart-type="bar" data-chart-data='{"labels":["Jan"],"datasets":[]}'
        aria-busy="true">
        <div class="sc-chart-canvas"><canvas></canvas></div>
        <div class="sc-chart-fallback">Fallback values</div>
      </div>
    </section>
  `);
  await page.evaluate(() => {
    window.Chart = function LegacyChart() {};
    const source = [
      "window.Chart=function(){this.destroy=function(){}}",
      "window.Chart.register=function(){}",
      "window.Chart.getChart=function(){return null}",
      "window.Chart.version='loaded-chartjs'"
    ].join(";");
    document.querySelector("[data-sc-chart-src]").dataset.scChartSrc =
      "data:text/javascript," + encodeURIComponent(source);
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  expect(await page.evaluate(() => window.Chart.version)).toBe("loaded-chartjs");
});

test("switching to graph mode raises the point limit and removes page selection", async ({page}) => {
  await load(page, `
    <form data-sc-builder>
      <input type="radio" name="view" value="detail" checked>
      <input type="radio" name="view" value="graph">
      <fieldset data-sc-result-view-panel="detail"></fieldset>
      <fieldset data-sc-result-view-panel="summary" hidden disabled></fieldset>
      <fieldset data-sc-graph-options hidden disabled></fieldset>
      <fieldset data-sc-aggregate-options hidden disabled></fieldset>
      <label><span data-sc-limit-label>Rows</span>
        <select name="limit" data-sc-limit>
          <option value="50" selected>50</option><option value="250">250</option><option value="500">500</option>
        </select>
      </label>
      <label data-sc-page-control>Page<input name="page" value="4"></label>
    </form>
  `);
  await page.locator('input[name="view"][value="graph"]').check();
  await expect(page.locator('[data-sc-limit-label]')).toHaveText("Points");
  await expect(page.locator('[data-sc-limit]')).toHaveValue("500");
  await expect(page.locator('[data-sc-limit] option[value="50"]')).toHaveAttribute("disabled", "");
  await expect(page.locator('[data-sc-page-control]')).toBeHidden();
  await expect(page.locator('[data-sc-page-control] input')).toBeDisabled();
  await expect(page.locator('[data-sc-page-control] input')).toHaveValue("1");
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
  await page.setContent(`
    <section id="selecto-channel-orders" hx-ws:connect="/explore/orders/ws">
      <span data-selecto-connection class="is-live">Live</span>
      <form><input name="query_library_view" value="late-orders"></form>
      <div data-saved-results>Previously loaded rows</div>
      <div data-sc-chart data-chart-type="bar" data-chart-data='{"labels":["Jan"],"datasets":[]}'
        aria-busy="true"><div class="sc-chart-canvas"><canvas></canvas></div>
        <div class="sc-chart-fallback">Fallback</div></div>
    </section>
  `);
  await page.evaluate(() => {
    window.chartConstructions = 0;
    window.chartDestroyCalls = 0;
    window.Chart = function () {
      window.chartConstructions += 1;
      this.destroy = function () { window.chartDestroyCalls += 1; };
    };
    window.Chart.register = function () {};
    window.Chart.getChart = function () { return null; };
    window.Chart.version = "test";
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);

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
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  expect(await page.evaluate(() => ({
    constructions: window.chartConstructions,
    destroys: window.chartDestroyCalls,
  }))).toEqual({constructions: 2, destroys: 1});
  await expect(page.locator("[data-selecto-connection]")).toHaveText("Connecting");
});

test("a toolbar-hosted popstate reloads the exact Explorer history URL", async ({page}) => {
  let documentRequests = 0;
  await page.route("http://selecto.test/**", async route => {
    documentRequests += 1;
    await route.fulfill({contentType: "text/html", body: `
      <body class="sc-host-menu-toolbar">
        <toolbar-menu data-host-menu sidebar-always-open>Tenant navigation</toolbar-menu>
        <section id="selecto-channel-loads" hx-ws:connect="/explorer/load/ws">
          <section id="selecto-surface-loads"><div data-graph>Monthly loads</div></section>
        </section>
      </body>
    `});
  });
  const url = "http://selecto.test/explorer/load?view=graph&page=3&filter_value=2024-10-01";
  await page.goto(url);
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded")));
  await expect(page.locator("body")).toHaveClass(/toolbar-left-menu-open/);

  await page.evaluate(() => {
    window.dispatchEvent(new PopStateEvent("popstate", {state: window.history.state}));
  });

  await expect.poll(() => documentRequests).toBe(2);
  await expect(page).toHaveURL(url);
  await expect(page.locator("[data-host-menu]")).toHaveText("Tenant navigation");
  await expect(page.locator("[data-graph]")).toHaveText("Monthly loads");
});

test("a legacy-menu popstate reloads the complete Explorer document", async ({page}) => {
  let documentRequests = 0;
  await page.route("http://selecto.test/**", async route => {
    documentRequests += 1;
    await route.fulfill({contentType: "text/html", body: `
      <body class="sc-host-menu-dynamic menu_adjusted_left">
        <nav data-host-menu>Legacy tenant navigation</nav>
        <section id="selecto-channel-loads" hx-ws:connect="/explorer/load/ws">
          <section id="selecto-surface-loads"><div data-graph>Monthly loads</div></section>
        </section>
      </body>
    `});
  });
  const url = "http://selecto.test/explorer/load?view=graph&page=2";
  await page.goto(url);
  await page.addScriptTag({path: bundle});

  await page.evaluate(() => {
    window.dispatchEvent(new PopStateEvent("popstate", {state: window.history.state}));
  });

  await expect.poll(() => documentRequests).toBe(2);
  await expect(page).toHaveURL(url);
  await expect(page.locator("[data-host-menu]")).toHaveText("Legacy tenant navigation");
  await expect(page.locator("[data-graph]")).toHaveText("Monthly loads");
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

test("Back rebuilds a graph from a clean history snapshot", async ({page}) => {
  let documentRequests = 0;
  await page.route("http://selecto.test/**", async route => {
    documentRequests += 1;
    await route.fulfill({contentType: "text/html", body: `
      <nav data-host-menu>Tenant navigation</nav>
      <section id="selecto-channel-loads" hx-ws:connect="/explorer/load/ws">
        <span data-selecto-connection class="is-live">Live</span>
        <section id="selecto-surface-loads" data-sc-chart-src="/chart.js">
          <div data-sc-workspace>
            <form action="/explorer/load" method="get" data-sc-builder>
              <input name="view" value="graph">
            </form>
            <section class="sc-results">
              <div data-sc-chart data-chart-type="bar"
                data-chart-data='{"labels":["Jan"],"datasets":[]}' aria-busy="true">
                <div class="sc-chart-canvas"><canvas></canvas></div>
                <div class="sc-chart-fallback">Fallback values</div>
                <form action="/explorer/load" method="get" hx-ws:send
                  data-sc-graph-drilldown="0">
                  <input name="view" value="detail">
                  <input name="filter_value" value="Jan">
                </form>
              </div>
            </section>
          </div>
        </section>
      </section>
    `});
  });
  await page.goto("http://selecto.test/explorer/load?view=graph");
  await page.evaluate(() => {
    window.chartConstructions = 0;
    window.Chart = function (canvas) {
      window.chartConstructions += 1;
      canvas.width = 900;
      canvas.height = 420;
      canvas.style.width = "900px";
      this.destroy = function () {};
    };
    window.Chart.register = function () {};
    window.Chart.getChart = function () { return null; };
    window.Chart.version = "test";
    window.htmx = {process() {}};
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await page.evaluate(() => document.dispatchEvent(
    new CustomEvent("htmx:ws:after:connection", {bubbles: true})
  ));
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  await page.evaluate(() => {
    const drilldown = document.querySelector('[data-sc-graph-drilldown="0"]');
    drilldown.addEventListener("submit", event => event.preventDefault(), {once: true});
    drilldown.requestSubmit();
    if (!window.history.state.selectoPendingNavigation) {
      throw new Error("graph drilldown did not reserve its history entry during submit");
    }
    if (!window.sessionStorage.getItem(
      "selecto-history:" + window.history.state.selectoSnapshot
    )) {
      throw new Error("graph history snapshot was not persisted for document restoration");
    }
    document.dispatchEvent(new CustomEvent("htmx:before:swap", {
      detail: {target: document.querySelector(".sc-results")}
    }));
    document.querySelector("#selecto-surface-loads").outerHTML = `
      <section id="selecto-surface-loads"><div data-sc-workspace>
        <section class="sc-results"><div data-detail-results>January loads</div></section>
      </div></section>`;
    document.dispatchEvent(new CustomEvent("htmx:ws:after:message:incoming", {
      detail: {message: {json: () => Promise.resolve({
        selecto: {url: "/explorer/load?view=detail&filter_value=Jan"}
      })}}
    }));
  });
  await expect.poll(() => page.url()).toContain("view=detail");
  await page.goBack();
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  await expect(page.locator("[data-sc-chart]")).not.toHaveClass(/is-fallback/);
  await expect(page.locator("[data-sc-builder]")).toBeVisible();
  await expect(page.locator("[data-host-menu]")).toHaveText("Tenant navigation");
  expect(await page.evaluate(() => window.chartConstructions)).toBe(2);
  expect(documentRequests).toBe(1);
});

test("a reconnecting Explorer keeps drilldown and Back inside browser history", async ({page}) => {
  let documentRequests = 0;
  await page.route("http://selecto.test/**", async route => {
    documentRequests += 1;
    await route.fulfill({contentType: "text/html", body: `
      <nav data-host-menu>Tenant navigation</nav>
      <section id="selecto-channel-loads" hx-ws:connect="/explorer/load/ws">
        <span data-selecto-connection>Reconnecting</span>
        <section id="selecto-surface-loads">
          <div data-sc-workspace><section class="sc-results">
            <div data-aggregate-results>Aggregate results</div>
            <form action="/explorer/load" method="get" hx-ws:send data-drilldown>
              <input name="view" value="detail">
              <input name="filter_value" value="Monday">
              <button>Open</button>
            </form>
          </section></div>
        </section>
      </section>
    `});
  });
  await page.goto("http://selecto.test/explorer/load?view=aggregate");
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => {
    window.nativeSubmitCalled = false;
    HTMLFormElement.prototype.submit = function () { window.nativeSubmitCalled = true; };
    const form = document.querySelector("[data-drilldown]");
    // This deliberately models the short interval before HTMX has attached
    // its listener to a freshly swapped form. Selecto itself must prevent a
    // full document request while leaving the event available to HTMX.
    form.requestSubmit();
  });
  await expect.poll(() => page.url()).toContain("view=detail");
  expect(await page.evaluate(() => window.nativeSubmitCalled)).toBe(false);
  expect(await page.evaluate(() => window.history.state.selectoPendingNavigation)).toBe(true);
  const pendingRequestId = await page.evaluate(() => window.history.state.selectoRequestId);
  expect(pendingRequestId).toMatch(/^selecto-/);
  expect(page.url()).not.toContain("selecto_request_id");
  expect(await page.evaluate(() => window.sessionStorage.getItem(
    "selecto-history:" + window.history.state.selectoSnapshot
  ))).not.toContain("selecto_request_id");
  await page.goBack();
  await expect(page.locator("[data-aggregate-results]")).toHaveText("Aggregate results");
  await expect(page.locator("[data-host-menu]")).toHaveText("Tenant navigation");
  const staleResponseCancelled = await page.evaluate(async requestId => {
    let waiting;
    const detail = {
      message: {json: () => Promise.resolve({selecto: {request_id: requestId}})},
      cancelled: false,
      waitUntil(promise) { waiting = promise; },
    };
    document.dispatchEvent(new CustomEvent("htmx:ws:before:message:incoming", {detail}));
    await waiting;
    return detail.cancelled;
  }, pendingRequestId);
  expect(staleResponseCancelled).toBe(true);
  await expect(page.locator("[data-aggregate-results]")).toHaveText("Aggregate results");
  await expect(page.locator("[data-host-menu]")).toHaveText("Tenant navigation");
  expect(documentRequests).toBe(1);
});

test("browser Back restores an Explorer history entry inside a legacy host frame", async ({page}) => {
  let explorerDocuments = 0;
  await page.route("http://selecto.test/**", async route => {
    const url = new URL(route.request().url());
    if (url.pathname === "/host") {
      await route.fulfill({contentType: "text/html", body: `
        <frameset cols="180,*">
          <frame name="x1" src="/menu">
          <frame name="x2" src="/explorer/load?view=aggregate">
        </frameset>
      `});
      return;
    }
    if (url.pathname === "/menu") {
      await route.fulfill({contentType: "text/html", body: `
        <nav data-host-menu>Tenant navigation</nav>
      `});
      return;
    }
    explorerDocuments += 1;
    await route.fulfill({contentType: "text/html", body: `
      <section id="selecto-channel-loads" hx-ws:connect="/explorer/load/ws">
        <span data-selecto-connection>Connecting</span>
        <section id="selecto-surface-loads">
          <form action="/explorer/load" method="get" data-sc-builder>
            <input name="view" value="aggregate">
          </form>
          <section class="sc-results">
            <div data-aggregate-results>Aggregate results</div>
            <form action="/explorer/load" method="get" hx-ws:send class="sc-drilldown-form">
              <input name="view" value="detail">
              <input name="filter_value" value="at">
              <button>Open</button>
            </form>
          </section>
        </section>
      </section>
    `});
  });
  await page.goto("http://selecto.test/host");
  let frame = page.frames().find(candidate => candidate.url().includes("/explorer/load"));
  await frame.evaluate(() => { window.htmx = {process() {}}; });
  await frame.addScriptTag({path: bundle});
  await frame.evaluate(() => {
    document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true}));
    document.dispatchEvent(new CustomEvent("htmx:ws:after:connection", {bubbles: true}));
    const form = document.querySelector(".sc-drilldown-form");
    form.addEventListener("submit", event => event.preventDefault(), {once: true});
    form.requestSubmit();
    document.querySelector("#selecto-surface-loads").outerHTML = `
      <section id="selecto-surface-loads">
        <section class="sc-results"><div data-detail-results>Detail results</div></section>
      </section>`;
    document.dispatchEvent(new CustomEvent("htmx:ws:after:message:incoming", {
      detail: {message: {json: () => Promise.resolve({
        selecto: {url: "/explorer/load?view=detail&filter_value=at"}
      })}}
    }));
  });
  await expect.poll(() => frame.url()).toContain("view=detail");
  await page.evaluate(() => window.history.back());
  await expect.poll(() => page.frames().some(candidate =>
    candidate.url().includes("/explorer/load?view=aggregate")
  )).toBe(true);
  frame = page.frames().find(candidate => candidate.url().includes("/explorer/load"));
  await expect(frame.locator("[data-aggregate-results]")).toHaveText("Aggregate results");
  await expect(page.frame({name: "x1"}).locator("[data-host-menu]")).toHaveText("Tenant navigation");
  expect(explorerDocuments).toBe(1);
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
    <title>Load Explorer</title>
    <section class="sc-results">
      <div tabindex="0" data-sc-row-click data-sc-row-click-type="iframe_modal" data-sc-row-dialog-id="details" data-sc-row-click-url="/one" data-sc-row-click-title="First">First row</div>
      <div tabindex="0" data-sc-row-click data-sc-row-click-type="iframe_modal" data-sc-row-dialog-id="details" data-sc-row-click-url="/two" data-sc-row-click-title="Second">Second row</div>
      <dialog id="details" data-sc-row-dialog>
        <h2 data-sc-row-dialog-title></h2><span data-sc-row-dialog-position></span>
        <button data-sc-row-dialog-nav="previous"></button><button data-sc-row-dialog-nav="next"></button>
        <button data-sc-row-dialog-close>Close</button>
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
  await page.evaluate(() => { document.title = "Legacy Load 101"; });
  await expect(page).toHaveTitle("Load Explorer");
  await page.evaluate(() => {
    document.title = "Legacy Load 102";
    document.querySelector("[data-sc-row-dialog-close]").click();
  });
  await expect(page).toHaveTitle("Load Explorer");
});

test("record editor saves through the governed endpoint and replaces the result row", async ({page}) => {
  let saved = false;
  let editorGets = 0;
  let releaseReload;
  const reloadGate = new Promise(resolve => { releaseReload = resolve; });
  await page.route("https://selecto.test/**", async route => {
    const request = route.request();
    if (request.url().endsWith("/editor/101") && request.method() === "GET") {
      editorGets += 1;
      if (saved) await reloadGate;
      return route.fulfill({status: 200, contentType: "text/html", body: `
        <form action="https://selecto.test/editor/101" data-sc-record-editor-form>
          <label data-sc-record-editor-field="product_name">Name
            <input name="editor_field_product_name" value="${saved ? "New name" : "Old name"}" required>
            <small data-sc-record-editor-error hidden></small>
          </label>
          <div data-sc-record-editor-result hidden></div>
          <button type="submit" data-sc-record-editor-save disabled>Save changes</button>
        </form>`});
    }
    if (request.url().endsWith("/editor/101") && request.method() === "POST") {
      saved = true;
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
  await expect.poll(() => editorGets).toBe(2);
  await expect(page.locator("#editor-dialog")).toHaveAttribute("open", "");
  await expect(page.locator('[name="editor_field_product_name"]')).toHaveValue("New name");
  await expect(page.locator("[data-sc-record-editor-result]")).toBeHidden();
  releaseReload();
  await expect(page.locator("#editor-dialog")).toHaveAttribute("open", "");
  await expect(page.locator('[name="editor_field_product_name"]')).toHaveValue("New name");
  await expect(page.locator("[data-sc-record-editor-result]")).toHaveText("Updated");
  await expect(page.locator("[data-sc-record-editor-save]")).toBeDisabled();
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

test("record editor actions stay open unless their response requests close", async ({page}) => {
  let actionRuns = 0;
  await page.route("https://selecto.test/**", async route => {
    const request = route.request();
    if (request.url().endsWith("/editor/505")) {
      return route.fulfill({status: 200, contentType: "text/html", body: `
        <div data-sc-record-editor-result hidden></div>
        <form action="https://selecto.test/action/505" data-sc-record-editor-action-form
          data-sc-record-id="505" data-sc-return-to="https://selecto.test/results">
          <input name="action_input_note" value="Checked">
          <button type="submit">Run action</button>
          <div data-sc-action-result hidden></div>
        </form>`});
    }
    if (request.url().endsWith("/action/505") && request.method() === "POST") {
      actionRuns += 1;
      return route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({
        ok: true, message: "Action complete", close_dialog: actionRuns === 2
      })});
    }
    return route.fulfill({status: 200, contentType: "text/html", body: `
      <table><tbody><tr data-sc-record-id="505" data-sc-row-click
        data-sc-row-click-type="record_editor" data-sc-row-dialog-id="editor-dialog"
        data-sc-row-click-url="https://selecto.test/editor/505"><td>Truck 505</td></tr></tbody></table>`});
  });
  await load(page, `
    <section class="sc-results"><table><tbody><tr tabindex="0" data-sc-record-id="505"
      data-sc-row-click data-sc-row-click-type="record_editor" data-sc-row-dialog-id="editor-dialog"
      data-sc-row-click-url="https://selecto.test/editor/505"><td>Truck 505</td></tr></tbody></table>
      <dialog id="editor-dialog" data-sc-row-dialog data-sc-row-dialog-kind="record_editor">
        <span data-sc-row-dialog-position></span><button data-sc-row-dialog-nav="previous"></button>
        <button data-sc-row-dialog-nav="next"></button><span data-sc-row-dialog-loading hidden></span>
        <div data-sc-row-editor-body></div></dialog></section>`);

  await page.locator("[data-sc-record-id='505']").click();
  await page.getByRole("button", {name: "Run action"}).click();
  await expect(page.locator("#editor-dialog")).toHaveAttribute("open", "");
  await expect(page.locator("[data-sc-record-editor-result]")).toHaveText("Action complete");
  await page.getByRole("button", {name: "Run action"}).click();
  await expect(page.locator("#editor-dialog")).not.toHaveAttribute("open", "");
  expect(actionRuns).toBe(2);
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
