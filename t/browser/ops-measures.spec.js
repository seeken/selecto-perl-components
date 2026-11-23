import {test, expect} from "@playwright/test";
import {spawn, execFileSync} from "node:child_process";
import net from "node:net";
import path from "node:path";
import {fileURLToPath} from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const perl = execFileSync("mise", ["which", "perl"], {cwd: root, encoding: "utf8"}).trim();

test("picker defaults and ratio measures survive browser edits", async ({page}) => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, "127.0.0.1", resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/ops-measures.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  try {
    await expect.poll(async () => {
      try { return (await fetch(base + "/loads", {signal: AbortSignal.timeout(1000)})).status; } catch (_) { return 0; }
    }).toBe(200);
    await page.goto(base + "/loads?q=1&view=aggregate&field=id&group=region&measure=revenue");
    await expect(page.locator('input[name="query_library_segment_choice_count_as"][value="shipments"]')).toBeChecked();
    await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
    const picker = page.locator('[data-sc-picker-kind="measure"]');
    await picker.locator('[data-sc-picker-available-item][data-field="rpu"]').click();
    const ratio = picker.locator('[data-sc-picker-set-item][data-field="rpu"]');
    await expect(ratio.locator('input[name="measure_function"][value="ratio_of_sums"]')).toHaveCount(1);
    await expect(ratio.locator('select[name="measure_function"]')).toHaveCount(0);
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    await expect(page.locator('.sc-results')).toContainText('Revenue per unit');
    await expect(ratio.locator('input[name="measure_function"][value="ratio_of_sums"]')).toHaveCount(1);
    const off = page.locator('input[name="query_library_segment_choice_count_as"][value=""]');
    if (await page.getByRole("button", {name: "Expand view menu", exact: true}).isVisible())
      await page.getByRole("button", {name: "Expand view menu", exact: true}).click();
    await page.locator('[data-sc-builder-tab="filters"]').click();
    await off.check();
    await page.getByRole("button", {name: "Run query", exact: true}).click();
    await expect(off).toBeChecked();
    await expect(page.locator('.sc-results')).toContainText('41.67');
  } finally { server.kill("SIGTERM"); }
});
