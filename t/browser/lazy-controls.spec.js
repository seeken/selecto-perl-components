import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components/selecto-components.js");
const fixture = `<form data-sc-builder="products" data-sc-controls-url="/explorer/products/controls" data-sc-controls-csrf="token">
  <input name="q" value="1" type="hidden">
  <label>Detail<input type="radio" name="view" value="detail" checked></label>
  <label>Aggregate<input type="radio" name="view" value="aggregate"></label>
  <label>Graph<input type="radio" name="view" value="graph"></label>
  <p data-sc-controls-status role="status" hidden></p>
  <fieldset data-sc-result-view-panel="detail">
    <input type="hidden" name="field" value="created"><input name="field_alias" value="Created date">
    <input type="hidden" name="field" value="created"><input name="field_alias" value="Created time">
    <input type="hidden" name="group" value="status"><input type="hidden" name="measure" value="count">
  </fieldset>
  <fieldset data-sc-result-view-panel="summary" data-sc-view-lazy hidden disabled></fieldset>
  <input name="filter_value" value="original" aria-label="Filter">
  <button type="submit">Run query</button>
</form>`;
const summary = `<input name="group" value="status" aria-label="Group">
  <input name="measure" value="count" aria-label="Measure">
  <input type="hidden" name="field" value="created"><input type="hidden" name="field_alias" value="Created date">
  <input type="hidden" name="field" value="created"><input type="hidden" name="field_alias" value="Created time">`;

async function load(page) {
  await page.route("https://example.test/explorer/products", route => route.fulfill({contentType: "text/html", body: fixture}));
  await page.goto("https://example.test/explorer/products");
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => {
    document.dispatchEvent(new Event("DOMContentLoaded"));
    window.submits = 0;
    document.querySelector("form").addEventListener("submit", event => {event.preventDefault(); window.submits++;});
  });
}

test("inactive controls load only on demand, preserve repeated fields, and reuse the loaded panel", async ({page}) => {
  let requests = [];
  let release;
  await page.route("**/controls", async route => {
    requests.push(new URLSearchParams(route.request().postData()));
    await new Promise(resolve => {release = resolve;});
    await route.fulfill({json: {html: summary}});
  });
  await load(page);
  expect(requests).toHaveLength(0);
  await page.getByLabel("Graph", {exact: true}).check();
  await expect(page.locator("[data-sc-controls-status]")).toHaveText("Loading view controls…");
  await page.getByRole("button", {name: "Run query"}).click();
  expect(await page.evaluate(() => window.submits)).toBe(0);
  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0].getAll("field_alias")).toEqual(["Created date", "Created time"]);
  expect(requests[0].get("csrf_token")).toBe("token");
  release();
  await expect(page.getByLabel("Group", {exact: true})).toBeVisible();
  await page.getByLabel("Group", {exact: true}).fill("category");
  await page.getByLabel("Detail", {exact: true}).check();
  await page.locator('input[name="field_alias"]').first().fill("Date edited");
  await page.getByLabel("Aggregate", {exact: true}).check();
  expect(requests).toHaveLength(1);
  await expect(page.getByLabel("Group", {exact: true})).toHaveValue("category");
  expect(await page.evaluate(() => new FormData(document.querySelector("form")).getAll("field_alias")))
    .toEqual(["Date edited", "Created time"]);
});

test("an in-flight draft edit cannot be replaced by stale controls", async ({page}) => {
  let releases = [];
  let bodies = [];
  await page.route("**/controls", async route => {
    bodies.push(new URLSearchParams(route.request().postData()));
    await new Promise(resolve => releases.push(resolve));
    await route.fulfill({json: {html: summary}});
  });
  await load(page);
  await page.getByLabel("Aggregate", {exact: true}).check();
  await expect.poll(() => releases.length).toBe(1);
  await page.getByLabel("Filter", {exact: true}).fill("new filter");
  releases[0]();
  await expect.poll(() => releases.length).toBe(2);
  expect(bodies[1].get("filter_value")).toBe("new filter");
  releases[1]();
  await expect(page.getByLabel("Group", {exact: true})).toBeVisible();
  await expect(page.getByLabel("Filter", {exact: true})).toHaveValue("new filter");
});

test("failed controls leave the current draft usable and allow retry", async ({page}) => {
  let calls = 0;
  await page.route("**/controls", route => {
    calls++;
    return route.fulfill(calls === 1
      ? {status: 403, json: {error: "Access denied"}}
      : {json: {html: summary}});
  });
  await load(page);
  // A fast rejected response restores Detail before check() asserts Graph.
  await page.getByLabel("Graph", {exact: true}).click();
  await expect(page.locator("[data-sc-controls-status]")).toContainText("Access denied");
  await expect(page.getByLabel("Detail", {exact: true})).toBeChecked();
  await expect(page.locator('[data-sc-result-view-panel="detail"]')).toBeVisible();
  await page.getByLabel("Graph", {exact: true}).check();
  await expect(page.getByLabel("Group", {exact: true})).toBeVisible();
});

test("switching back while controls load discards the late response", async ({page}) => {
  let release;
  await page.route("**/controls", async route => {
    await new Promise(resolve => {release = resolve;});
    await route.fulfill({json: {html: summary}});
  });
  await load(page);
  await page.getByLabel("Graph", {exact: true}).check();
  await expect.poll(() => typeof release).toBe("function");
  await page.getByLabel("Detail", {exact: true}).check();
  release();
  await expect(page.locator('[data-sc-result-view-panel="summary"]')).toHaveAttribute("data-sc-view-lazy", "");
  await expect(page.locator('[data-sc-result-view-panel="detail"]')).toBeVisible();
  await expect(page.locator("form")).not.toHaveAttribute("aria-busy");
});

test("a stalled controls request times out and leaves the draft usable", async ({page}) => {
  await page.clock.install();
  let requested = false;
  await page.route("**/controls", () => { requested = true; });
  await load(page);
  await page.getByLabel("Graph", {exact: true}).check();
  await expect.poll(() => requested).toBe(true);
  await page.clock.fastForward(31000);
  await expect(page.locator("[data-sc-controls-status]")).toContainText("too long to load");
  await expect(page.getByLabel("Detail", {exact: true})).toBeChecked();
  await expect(page.locator("form")).not.toHaveAttribute("data-sc-controls-loading");
});
