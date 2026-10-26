import {expect, test} from "@playwright/test";

async function login(page, actor) {
  await page.goto("/session");
  await page.getByRole("button", {name: actor, exact: true}).click();
  await expect(page.locator("#selecto-results-items")).toContainText(`${actor} One`);
}

test("Console requires a signed-in session", async ({page}) => {
  await page.goto("/api/items/console");
  await expect(page).toHaveURL(/\/session$/);
  expect((await page.request.get("/api/items/catalog")).status()).toBe(401);
});

test("Explorer opens the packaged Console and runs its Detail query with session CSRF", async ({page}) => {
  await login(page, "Alpha");
  const link = page.locator("a[data-sc-api-console]");
  const href = await link.getAttribute("href");
  const initial = JSON.parse(new URLSearchParams(href.split("#")[1]).get("request"));
  const popup = page.waitForEvent("popup");
  await link.click();
  const consolePage = await popup;
  const errors = [];
  consolePage.on("pageerror", error => errors.push(error.message));
  await expect(consolePage.getByRole("button", {name: "Run query", exact: true})).toBeEnabled();
  const exchange = consolePage.waitForResponse(response => new URL(response.url()).pathname === "/api/items/query");
  await consolePage.getByRole("button", {name: "Run query", exact: true}).click();
  const response = await exchange;
  expect(response.status()).toBe(200);
  expect(response.request().headers()["x-csrf-token"]).toBeTruthy();
  const envelope = response.request().postDataJSON();
  expect(envelope.format).toBe("selecto.remote-query");
  expect(envelope.query.select).toEqual(initial.select);
  expect(envelope.query.limit).toBe(initial.limit);
  const table = consolePage.locator("[data-sac-result-body]");
  await expect(table).toContainText("Alpha One");
  await expect(table).toContainText("9007199254740993");
  await expect(table).not.toContainText("Beta");
  expect(errors).toEqual([]);
});

test("direct Console discovery and execution use the current principal", async ({page}) => {
  await login(page, "Beta");
  const metadata = page.waitForResponse(response => new URL(response.url()).pathname === "/api/items/explorer");
  const catalog = page.waitForResponse(response => new URL(response.url()).pathname === "/api/items/catalog");
  await page.goto("/api/items/console");
  expect((await metadata).status()).toBe(200);
  expect((await catalog).status()).toBe(200);
  await page.locator('[data-sac-add-field="name"]').click();
  await page.getByRole("button", {name: "Run query", exact: true}).click();
  const table = page.locator("[data-sac-result-body]");
  await expect(table).toContainText("Beta One");
  await expect(table).not.toContainText("Alpha");
  const csrf = await page.locator("main").getAttribute("data-csrf-token");
  expect((await page.request.post("/logout", {form: {csrf_token: csrf}, maxRedirects: 0})).status()).toBe(302);
  // The shared client rechecks discovery before executing; logout may refuse
  // there before it sends a query at all.
  const refused = page.waitForResponse(response => new URL(response.url()).pathname.startsWith("/api/items")
    && response.status() === 401);
  await page.getByRole("button", {name: "Run query", exact: true}).click();
  expect((await refused).status()).toBe(401);
  await page.reload();
  await expect(page).toHaveURL(/\/session$/);
});
