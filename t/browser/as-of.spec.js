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
  server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/as-of.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  let output = "";
  server.stdout.on("data", chunk => { output += chunk; });
  server.stderr.on("data", chunk => { output += chunk; });
  await expect.poll(async () => {
    if (server.exitCode !== null) throw new Error(output);
    try { return (await fetch(base + "/events", {signal: AbortSignal.timeout(1000)})).status; }
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
const today = "?q=1&field=id&filter_field=day&filter_op=date_shortcut&filter_value=today";
test("changing As of re-runs relative reads and Today restores the real clock", async ({page}) => {
  await page.goto(base + "/events" + today);
  await page.getByRole("button", {name: "Expand view menu"}).click();
  await expect(page.locator('.sc-results tbody tr td:first-child')).toHaveText(["6"]);
  await page.getByRole('tab', {name: /^Filters /}).click();
  await page.locator('[data-sc-as-of-date]').fill('2026-03-15');
  await page.locator('[data-sc-as-of-date]').press('Tab');
  await expect(page.locator('[data-sc-as-of-summary]')).toHaveText('As of 15 Mar 2026');
  await expect(page.locator('.sc-results tbody tr td:first-child')).toHaveText(["1"]);
  await expect.poll(() => new URL(page.url()).searchParams.get('as_of')).toBe('2026-03-15');
  const exportLink = page.locator('[data-sc-export-format="csv"]').first();
  expect(new URL(await exportLink.getAttribute('href'), base).searchParams.get('as_of')).toBe('2026-03-15');
  await page.getByRole("button", {name: "Expand view menu"}).click();
  await page.getByRole('tab', {name: /^Filters /}).click();
  await page.locator('[data-sc-as-of-clear]').click();
  await expect(page.locator('[data-sc-as-of-summary]')).toHaveCount(0);
  await expect(page.locator('.sc-results tbody tr td:first-child')).toHaveText(["6"]);
  await expect.poll(() => new URL(page.url()).searchParams.has('as_of')).toBe(false);
});
test("saved timestamps survive ordinary submits and editing selects a calendar day", async ({page}) => {
  await page.goto(base + "/events" + today + '&as_of=2026-03-16T00%3A30%3A00%2B02%3A00');
  await expect(page.locator('.sc-results tbody tr td:first-child')).toHaveText(["1"]);
  await page.getByRole("button", {name: "Expand view menu"}).click();
  await page.getByRole('button', {name: 'Run query', exact: true}).click();
  await expect.poll(() => page.evaluate(() => !!history.state?.selectoPendingNavigation)).toBe(false);
  await expect.poll(() => new URL(page.url()).searchParams.get('as_of')).toBe('2026-03-16T00:30:00+02:00');
  await page.getByRole("button", {name: "Expand view menu"}).click();
  await page.getByRole('tab', {name: /^Filters /}).click();
  await page.locator('[data-sc-as-of-date]').fill('2026-03-14');
  await page.locator('[data-sc-as-of-date]').press('Tab');
  await expect(page.locator('[data-sc-as-of-summary]')).toHaveText('As of 14 Mar 2026');
  await expect(page.locator('.sc-results tbody tr td:first-child')).toHaveText(["2"]);
  await expect.poll(() => new URL(page.url()).searchParams.get('as_of')).toBe('2026-03-14');
});
