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
  server = spawn("script/with-local-sibling", [perl, "t/browser/fixtures/boolean-groups.pl", "daemon", "-l", base], {cwd: root, stdio: "pipe"});
  let output = "";
  server.stdout.on("data", chunk => { output += chunk; });
  server.stderr.on("data", chunk => { output += chunk; });
  await expect.poll(async () => {
    if (server.exitCode !== null) throw new Error(output);
    try { return (await fetch(base + "/flags", {signal: AbortSignal.timeout(1000)})).status; }
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

test("boolean pivot labels preserve raw drilldowns, overrides and export labels", async ({page}) => {
  const query = "?q=1&view=aggregate&field=id&group=region&group=rush&pivot_column=rush&measure=count";
  await page.goto(base + "/flags" + query);
  const headings = page.locator('.sc-pivot-table thead tr:nth-child(2) th');
  await expect(headings).toHaveText(["No", "Yes", "[NULL]"]);
  const yes = page.getByRole("button", {name: "Show details for Rush Yes", exact: true});
  expect(JSON.parse(await yes.getAttribute("value"))).toEqual({axis: 1, value: 1});
  await yes.click();
  await expect(page.locator('.sc-results tbody tr')).toHaveCount(2);
  await expect(page.locator('.sc-results tbody tr td:first-child')).toHaveText(["1", "3"]);
  await page.goto(base + "/flags" + query.replaceAll("rush", "invoiced"));
  await expect(headings).toHaveText(["Not invoiced", "Invoiced"]);
  await page.goto(base + "/localized" + query);
  await expect(headings).toHaveText(["Non", "Oui", "[NULL]"]);
  const csv = await page.request.get(base + "/flags?q=1&view=aggregate&field=id&group=rush&measure=count&format=csv");
  expect(csv.ok()).toBe(true);
  expect(await csv.text()).toContain('"No","1"');
  expect(await csv.text()).toContain('"Yes","2"');
});
