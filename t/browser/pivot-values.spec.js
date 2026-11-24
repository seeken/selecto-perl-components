import {test, expect} from "@playwright/test";
import {spawn} from "node:child_process";
import net from "node:net";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {testPerl} from "./test-perl.js";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const perl = testPerl(root);

test("pivot value chooser adds, reorders, removes and rerenders columns", async ({page}) => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, "127.0.0.1", resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/pivot-values.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  let output = "";
  server.stdout.on("data", chunk => {output += chunk;});
  server.stderr.on("data", chunk => {output += chunk;});
  try {
    await expect.poll(async () => {
      try { return (await fetch(base + "/orders", {signal: AbortSignal.timeout(1000)})).status; } catch (_) { return output.includes("Unknown") ? output : 0; }
    }).toBe(200);
    await page.goto(base + "/orders?q=1&view=aggregate&field=id&group=region&group=state_code&measure=quoted_amount&pivot_column=state_code");
    await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
    await page.locator('[data-sc-picker-kind="group"] [data-sc-picker-set-item][data-field="state_code"] summary').click();
    const box = page.locator('[data-sc-picker-set-item][data-field="state_code"] [data-sc-pivot-values]');
    await box.getByLabel("Search column values").fill("OP");
    await box.locator('[data-sc-pivot-add="OP"]').click();
    await box.getByLabel("Search column values").fill("PL");
    await box.locator('[data-sc-pivot-add="PL"]').click();
    await box.locator("li").nth(1).getByRole("button", {name: "Move value up", exact: true}).click();
    expect(await box.locator('input[name="pivot_column_value"]').evaluateAll(nodes => nodes.map(n => n.value))).toEqual(["PL", "OP"]);
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    const headings = page.locator('.sc-pivot-table thead tr:nth-child(2) > th');
    await expect(headings).toHaveText(["PL", "OP"]);
    // A rerender retains the chosen values in the Configure panel.
    if (await page.getByRole("button", {name: "Expand view menu", exact: true}).isVisible())
      await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
    const configure = page.locator('[data-sc-picker-kind="group"] [data-sc-picker-set-item][data-field="state_code"] summary');
    if (!(await box.getByLabel("Search column values").isVisible())) await configure.click();
    await box.locator("li").first().getByRole("button", {name: "Remove value", exact: true}).click();
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    await expect(headings).toHaveText(["OP"]);
    if (await page.getByRole("button", {name: "Expand view menu", exact: true}).isVisible())
      await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
    await page.locator(".sc-view-tab").filter({has: page.locator('[name="view"][value="graph"]')}).click();
    await page.locator('select[name="graph_series_group"]').selectOption("state_code");
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    await expect(page.locator("[data-sc-chart]")).toHaveCount(1);
    const chart = JSON.parse(await page.locator("[data-sc-chart]").getAttribute("data-chart-data"));
    expect(chart.datasets.map(dataset => dataset.label)).toEqual(["OP"]);
  } finally {
    server.kill("SIGTERM");
  }
});

test("Top N column order appears on input and survives query and view changes", async ({page}) => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, "127.0.0.1", resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/pivot-values.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  try {
    await expect.poll(async () => {
      try { return (await fetch(base + "/orders", {signal: AbortSignal.timeout(1000)})).status; } catch (_) { return 0; }
    }).toBe(200);
    await page.goto(base + "/orders?q=1&view=aggregate&field=id&group=region&group=state_code&measure=quoted_amount&pivot_column=state_code&pivot_column_other=1");
    const box = page.locator('[data-sc-picker-set-item][data-field="state_code"] [data-sc-pivot-values]');
    async function configure() {
      const menu = page.getByRole("button", {name: "Expand view menu", exact: true});
      if (await menu.isVisible()) await menu.click();
      if (!(await box.getByLabel("Top columns", {exact: true}).isVisible()))
        await page.locator('[data-sc-picker-kind="group"] [data-sc-picker-set-item][data-field="state_code"] summary').click();
    }
    await configure();
    const order = box.getByLabel("Column order", {exact: true});
    await expect(order).toBeHidden();
    await box.getByLabel("Top columns", {exact: true}).fill("2");
    await expect(order).toBeVisible();
    await expect(order).toHaveValue("rank");
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    const headings = page.locator('.sc-pivot-table thead tr:nth-child(2) > th');
    await expect(headings).toHaveText(["1 · OP", "2 · DL", "Other"]);
    await configure();
    await order.selectOption("natural");
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    await expect(headings).toHaveText(["DL", "OP", "Other"]);
    await configure();
    await expect(order).toHaveValue("natural");
    const permalink = page.getByRole("link", {name: "Permalink", exact: true});
    expect(await permalink.getAttribute("href")).toContain("pivot_column_top_order=natural");
    await page.locator(".sc-view-tab").filter({has: page.locator('[name="view"][value="graph"]')}).click();
    await page.locator('select[name="graph_series_group"]').selectOption("state_code");
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    await expect(page.locator("[data-sc-chart]")).toHaveCount(1);
    const chart = JSON.parse(await page.locator("[data-sc-chart]").getAttribute("data-chart-data"));
    expect(chart.datasets.map(dataset => dataset.label)).toEqual(["DL", "OP", "Other"]);
    await configure();
    await box.getByLabel("Top columns", {exact: true}).fill("");
    await expect(order).toBeHidden();
    await expect(order).toBeDisabled();
  } finally {
    server.kill("SIGTERM");
  }
});

test("summary pivot row labels stay frozen while columns scroll", async ({page}) => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, "127.0.0.1", resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/pivot-values.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  let output = "";
  server.stdout.on("data", chunk => {output += chunk;});
  server.stderr.on("data", chunk => {output += chunk;});
  try {
    await expect.poll(async () => {
      try { return (await fetch(base + "/orders", {signal: AbortSignal.timeout(1000)})).status; } catch (_) { return output.includes("Unknown") ? output : 0; }
    }).toBe(200);
    // One row group: each body row is named by a th, not a td.
    await page.goto(base + "/orders?q=1&view=aggregate&field=id&group=region&group=state_code&measure=quoted_amount&pivot_column=state_code");
    await expect(page.locator(".sc-pivot-table")).toHaveCount(1);
    const wrap = page.locator(".sc-table-wrap").filter({has: page.locator(".sc-pivot-table")});
    const label = page.locator(".sc-pivot-table > tbody > tr:nth-child(2) > :first-child");
    const heading = page.locator(".sc-pivot-table > thead > tr:first-child > th:first-child");
    // Narrow the scrollport so the state_code columns overflow it.
    await wrap.evaluate(node => { node.style.width = "180px"; });
    expect(await wrap.evaluate(node => node.scrollWidth > node.clientWidth + 100)).toBe(true);
    const before = await label.boundingBox();
    const headingBefore = await heading.boundingBox();
    await wrap.evaluate(node => { node.scrollLeft = node.scrollWidth; });
    await expect.poll(async () => (await label.boundingBox()).x).toBeCloseTo(before.x, 0);
    expect((await heading.boundingBox()).x).toBeCloseTo(headingBefore.x, 0);
    expect(await label.evaluate(node => node.tagName)).toBe("TH");
  } finally {
    server.kill("SIGTERM");
  }
});
