import {test, expect} from "@playwright/test";
import {spawn, execFileSync} from "node:child_process";
import {once} from "node:events";
import net from "node:net";
import path from "node:path";
import {fileURLToPath} from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
let server, base;
test.beforeAll(async () => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${listener.address().port}`;
  await new Promise(resolve => listener.close(resolve));
  const perl = execFileSync("mise", ["which", "perl"], {cwd: root, encoding: "utf8"}).trim();
  server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/same-field-groups.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  let output = "";
  server.stdout.on("data", chunk => { output += chunk; });
  server.stderr.on("data", chunk => { output += chunk; });
  await expect.poll(async () => {
    if (server.exitCode !== null) throw new Error(output);
    try { return (await fetch(base + "/seasonality", {signal: AbortSignal.timeout(1000)})).status; }
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

test("same date can be picked twice, pivoted, drilled and separated into graph series", async ({page}) => {
  await page.goto(base + "/seasonality?q=1&view=aggregate&field=id&field=created_on&group=created_on&group_format=month_of_year&measure=count");
  await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
  const picker = page.locator('[data-sc-picker-kind="group"]');
  await picker.locator('[data-sc-picker-available-item][data-field="created_on"]').click();
  const groups = picker.locator('[data-sc-picker-set-item][data-field="created_on"]');
  await expect(groups).toHaveCount(2);
  const year = groups.nth(1);
  await year.locator("summary").click();
  await year.locator('[name="group_format"]').selectOption("year");
  await year.locator('[name="pivot_column"]').check();
  await page.getByRole("button", {name: "Run query", exact: true}).click();
  await expect(page.locator('.sc-pivot-table thead tr:nth-child(2) th')).toHaveText(["2024", "2025"]);
  await expect(page.locator('.sc-pivot-table tbody tr:not(.sc-rollup-total)')).toHaveCount(12);
  const permalink = page.getByRole("link", {name: "Permalink", exact: true});
  expect(await permalink.getAttribute("href")).toContain("pivot_column=created_on%40year");
  const march = page.locator('.sc-pivot-table tbody tr:not(.sc-rollup-total)').nth(2);
  await march.locator('button[name="grid_cell"]').nth(1).click();
  await expect(page.locator('.sc-results tbody tr')).toHaveCount(2);
  await expect(page.locator('.sc-results tbody')).toContainText("2025-03");
  await page.goto(base + "/seasonality?q=1&view=graph&chart_type=line&field=id&group=created_on&group=created_on&group_format=month_of_year&group_format=year&graph_series_group=created_on%40year&measure=count");
  await expect(page.locator('[data-sc-chart]')).toHaveClass(/is-ready/);
  const chart = await page.locator('[data-sc-chart]').evaluate(node => JSON.parse(node.dataset.chartData));
  expect(chart.datasets.map(dataset => dataset.label)).toEqual(["2024", "2025"]);
  expect(chart.labels).toHaveLength(12);
});

test("shared group controls follow their instance when reordered", async ({page}) => {
  await page.goto(base + "/seasonality?q=1&view=aggregate&field=id&group=created_on&group=created_on&group_format=month_of_year&group_format=year&pivot_column=created_on%40year&measure=count");
  await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
  const groups = page.locator('[data-sc-picker-kind="group"] [data-sc-picker-set-item]');
  await groups.nth(1).getByRole("button", {name: "Move Created up", exact: true}).click();
  await expect(groups.nth(0).locator('[name="pivot_column"]')).toBeChecked();
  await expect(groups.nth(0).locator('[name="pivot_column"]')).toHaveValue("group:1");
  await page.getByRole("button", {name: "Run query", exact: true}).click();
  await expect(page.locator('.sc-pivot-table thead tr:nth-child(2) th')).toHaveText(["2024", "2025"]);
});
