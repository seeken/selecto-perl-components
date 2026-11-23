import {test, expect} from "@playwright/test";
import {spawn} from "node:child_process";
import {once} from "node:events";
import net from "node:net";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {testPerl} from "./test-perl.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
let server, base;
test.beforeAll(async () => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${listener.address().port}`;
  await new Promise(resolve => listener.close(resolve));
  const perl = testPerl(root);
  server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/hbar.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  let output = "";
  server.stdout.on("data", chunk => { output += chunk; });
  server.stderr.on("data", chunk => { output += chunk; });
  await expect.poll(async () => {
    if (server.exitCode !== null) throw new Error(output);
    try { return (await fetch(base + "/sales", {signal: AbortSignal.timeout(1000)})).status; }
    catch (_) { return 0; }
  }).toBe(200);
});
test.afterAll(async () => {
  if (server && server.exitCode === null) {
    const stopped = once(server, "exit");
    server.kill("SIGTERM");
    await stopped;
  }
});

async function graph(page, extra = {}) {
  const params = new URLSearchParams({q: "1", field: "id", view: "graph", chart_type: "horizontal_bar",
    group: "customer_id", measure: "revenue", order: "measure:revenue", direction: "desc", limit: "15"});
  for (const [key, value] of Object.entries(extra)) {
    params.delete(key);
    for (const item of Array.isArray(value) ? value : [value]) params.append(key, item);
  }
  await page.goto(base + "/sales?" + params);
  await expect(page.locator("[data-sc-chart]")).toHaveClass(/is-ready/);
  await page.evaluate(() => {
    const chart = window.Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    chart.options.animation = false;
    chart.update();
  });
}

test("horizontal dimension labels, currency ticks, top categories and drilldown", async ({page}) => {
  await graph(page);
  await expect(page.locator(".sc-chart-categories")).toHaveText("Top 15 of 146 categories");
  const result = await page.evaluate(() => {
    const chart = Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    const tooltip = chart.options.plugins.tooltip.callbacks;
    const dataset = chart.data.datasets[0];
    return {
      labels: chart.data.labels,
      ticks: chart.scales.y.ticks.map(tick => tick.label),
      values: dataset.data,
      xTicks: chart.scales.x.ticks.map(tick => tick.label),
      title: tooltip.title([{label: chart.data.labels[0]}]),
      tooltip: tooltip.label({dataset, parsed: {x: dataset.data[0], y: 0}}),
      zero: chart.scales.x.options.beginAtZero
    };
  });
  expect(result.labels).toHaveLength(15);
  expect(result.ticks[0]).toBe(result.labels[0].slice(0, 35) + "…");
  expect(result.ticks.slice(1)).toEqual(result.labels.slice(1));
  expect(result.xTicks.every(label => label.startsWith("$"))).toBe(true);
  expect(result.zero).toBe(true);
  expect(result.values).toEqual(Array.from({length: 15}, (_, i) => (146 - i) * 20 + 1));
  expect(result.title).toBe(result.labels[0]);
  expect(result.tooltip).toBe("Revenue: $2,921.00");
  // Exercise Chart.js's real click path, then the native detail query.
  await page.locator("[data-sc-chart] canvas").scrollIntoViewIfNeeded();
  // The chart sizes itself from its category count, and a late resize moves
  // the bars. Click only once the first bar holds still across two frames.
  const barPoint = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => {
    const chart = Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    chart.stop();
    const bar = chart.getDatasetMeta(0).data[0];
    const rect = chart.canvas.getBoundingClientRect();
    resolve({x: Math.round(rect.left + (bar.x + bar.base) / 2), y: Math.round(rect.top + bar.y)});
  })));
  let point = await barPoint();
  await expect.poll(async () => {
    const next = await barPoint();
    const still = next.x === point.x && next.y === point.y;
    point = next;
    return still;
  }).toBe(true);
  await page.mouse.click(point.x, point.y);
  // Detail is a full query; allow for a loaded machine (the whole suite runs in parallel).
  await expect(page.locator(".sc-results tbody tr")).toHaveCount(2, {timeout: 20000});
  await expect(page.locator('.sc-results tbody')).toContainText("292");
});

test("horizontal bars retain two value axes and their units", async ({page}) => {
  await graph(page, {measure: ["revenue", "volume"], measure_axis: ["left", "right"]});
  const axes = await page.evaluate(() => {
    const chart = Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    return {ids: chart.data.datasets.map(dataset => [dataset.xAxisID, dataset.yAxisID]),
      positions: [chart.scales.x.position, chart.scales.x2.position],
      currencies: chart.scales.x.ticks.map(tick => tick.label),
      counts: chart.scales.x2.ticks.map(tick => tick.label),
      types: [chart.scales.x.type, chart.scales.x2.type, chart.scales.y.type]};
  });
  expect(axes.ids).toEqual([["x", "y"], ["x2", "y"]]);
  expect(axes.positions).toEqual(["bottom", "top"]);
  expect(axes.types).toEqual(["linear", "linear", "category"]);
  expect(axes.currencies.every(label => label.startsWith("$"))).toBe(true);
  expect(axes.counts.every(label => /^\d[\d,]*$/.test(label))).toBe(true);
});

test("horizontal stack groups use both matching axes", async ({page}) => {
  await graph(page, {measure: ["revenue", "revenue"], measure_series_id: ["first", "second"], measure_stack: ["money", "money"]});
  const stack = await page.evaluate(() => {
    const chart = Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    chart.stop();
    chart.update("none");
    return {x: chart.scales.x.options.stacked, y: chart.scales.y.options.stacked,
      groups: chart.data.datasets.map(dataset => dataset.stack),
      bases: chart.getDatasetMeta(1).data.map(bar => bar.base),
      ends: chart.getDatasetMeta(0).data.map(bar => bar.x)};
  });
  expect(stack.x).toBe(true);
  expect(stack.y).toBe(true);
  expect(stack.groups).toEqual(["money", "money"]);
  stack.bases.forEach((base, index) => expect(base).toBeCloseTo(stack.ends[index], 1));
});

test("100 horizontal categories keep every label in a scrollable chart", async ({page}) => {
  await graph(page, {limit: "100", order: "customer_id", direction: "asc"});
  const layout = await page.evaluate(() => {
    const chart = Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    const viewport = document.querySelector(".sc-chart-canvas");
    return {labels: chart.data.labels, ticks: chart.scales.y.ticks.map(tick => tick.label),
      spacing: chart.scales.y.getPixelForValue(1) - chart.scales.y.getPixelForValue(0),
      height: viewport.clientHeight, scrollHeight: viewport.scrollHeight,
      overflow: getComputedStyle(viewport).overflowY};
  });
  expect(layout.labels).toHaveLength(100);
  expect(layout.ticks).toEqual(layout.labels);
  expect(layout.spacing).toBeGreaterThan(20);
  expect(layout.height).toBeLessThanOrEqual(900);
  expect(layout.scrollHeight).toBeGreaterThan(layout.height);
  expect(layout.overflow).toBe("auto");
  await page.locator(".sc-chart-canvas").evaluate(viewport => { viewport.scrollTop = viewport.scrollHeight; });
  const last = await page.evaluate(() => {
    const chart = Chart.getChart(document.querySelector("[data-sc-chart] canvas"));
    const rect = chart.canvas.getBoundingClientRect();
    const viewport = document.querySelector(".sc-chart-canvas").getBoundingClientRect();
    const y = rect.top + chart.scales.y.getPixelForValue(99);
    return y > viewport.top && y < viewport.bottom;
  });
  expect(last).toBe(true);
});

for (const type of ["bar", "line"]) {
  test(`${type} rotates category labels before skipping`, async ({page}) => {
    await graph(page, {chart_type: type, limit: "100"});
    expect(await page.evaluate(() => Chart.getChart(document.querySelector("[data-sc-chart] canvas")).scales.x.labelRotation)).toBeGreaterThanOrEqual(30);
  });
}
