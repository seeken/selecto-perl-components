import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  "../../public/selecto-components/canned-page.js");

test("a canned record link opens its local summary in an accessible dialog", async ({page}) => {
  await page.route("http://canned.test/orders", (route) => route.fulfill({
    contentType: "text/html",
    body: `<main class="selecto-canned-page">
      <a href="/portal-views/order-display/42" data-sc-canned-modal-link
         data-sc-canned-modal-title="Order ID Display">42</a>
    </main>`,
  }));
  await page.route("http://canned.test/portal-views/order-display/42", (route) => route.fulfill({
    contentType: "text/html", body: "<main>Order 42 summary</main>",
  }));
  await page.goto("http://canned.test/orders");
  await page.addScriptTag({path: script});

  const link = page.getByRole("link", {name: "42"});
  await link.click();
  const dialog = page.getByRole("dialog", {name: "Order ID Display"});
  await expect(dialog).toBeVisible();
  await expect(page.frameLocator("dialog iframe").getByText("Order 42 summary")).toBeVisible();
  await dialog.getByRole("button", {name: "Close"}).click();
  await expect(dialog).toHaveCount(0);
  await expect(link).toBeFocused();
});

test("a record dialog in a full-height host frame opens where the user can see it", async ({page}) => {
  await page.setViewportSize({width: 1000, height: 700});
  await page.route("http://canned.test/host", (route) => route.fulfill({
    contentType: "text/html",
    body: `<body style="margin:0"><header style="height:150px">Portal</header>
      <iframe src="/orders" style="display:block;border:0;width:100%;height:3000px"></iframe></body>`,
  }));
  await page.route("http://canned.test/orders", (route) => route.fulfill({
    contentType: "text/html",
    body: `<main class="selecto-canned-page" style="height:2900px">
      <a href="/portal-views/order-display/42" data-sc-canned-modal-link
         data-sc-canned-modal-title="Order ID Display">42</a>
    </main>`,
  }));
  await page.route("http://canned.test/portal-views/order-display/42", (route) => route.fulfill({
    contentType: "text/html", body: "<main>Order 42 summary</main>",
  }));
  await page.goto("http://canned.test/host");
  const frame = page.frame({url: "http://canned.test/orders"});
  await frame.addScriptTag({path: script});

  await frame.getByRole("link", {name: "42"}).click();
  await expect(frame.getByRole("dialog", {name: "Order ID Display"})).toBeVisible();
  const placement = await page.evaluate(() => ({
    scrollY: window.scrollY,
    box: document.querySelector("iframe").contentDocument
      .querySelector("dialog").getBoundingClientRect().toJSON(),
    frameTop: document.querySelector("iframe").getBoundingClientRect().top,
  }));
  expect(placement.scrollY).toBe(0);
  expect(placement.frameTop + placement.box.top).toBeGreaterThanOrEqual(150);
  expect(placement.frameTop + placement.box.bottom).toBeLessThanOrEqual(700);
});

test("canned page ignores a stale WebSocket result", async ({page}) => {
  await page.setContent(`
    <section id="selecto-page-channel-products" hx-ws:connect="/products/ws">
      <main class="selecto-canned-page">
        <form method="post"><button>Apply</button></form>
      </main>
    </section>
  `);
  await page.evaluate(() => {
    const channel = document.querySelector("#selecto-page-channel-products");
    channel._htmx = {ws: {connection: {socket: {readyState: WebSocket.OPEN}}}};
  });
  await page.addScriptTag({path: script});
  const result = await page.evaluate(async () => {
    const form = document.querySelector("form");
    const channel = document.querySelector("#selecto-page-channel-products");
    form.addEventListener("submit", (event) => event.preventDefault());
    form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
    form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
    const incoming = async (requestId) => {
      const promises = [];
      const detail = {
        message: {json: () => Promise.resolve({selecto: {request_id: requestId}})},
        waitUntil: (promise) => promises.push(promise),
        cancelled: false,
      };
      channel.dispatchEvent(new CustomEvent("htmx:ws:before:message:incoming",
        {bubbles: true, detail}));
      await Promise.all(promises);
      return detail.cancelled;
    };
    return {
      latest: channel.dataset.latestCannedRequest,
      formId: form.querySelector('[name="selecto_request_id"]').value,
      oldCancelled: await incoming("1"),
      currentCancelled: await incoming("2"),
    };
  });
  expect(result).toEqual({
    latest: "2", formId: "2", oldCancelled: true, currentCancelled: false,
  });
});

test("accepted public result updates its shareable URL", async ({page}) => {
  await page.route("http://canned.test/products", (route) => route.fulfill({
    contentType: "text/html",
    body: `<section id="selecto-page-channel-products" hx-ws:connect="/products/ws">
      <main class="selecto-canned-page"><form action="/products" method="get">
        <input name="submitted" value="1"><input name="f_brand" value="North">
        <button name="page" value="1">Apply</button>
      </form></main></section>`,
  }));
  await page.goto("http://canned.test/products");
  await page.evaluate(() => {
    const channel = document.querySelector("#selecto-page-channel-products");
    channel._htmx = {ws: {connection: {socket: {readyState: WebSocket.OPEN}}}};
  });
  await page.addScriptTag({path: script});
  await page.evaluate(async () => {
    const form = document.querySelector("form");
    form.addEventListener("submit", (event) => event.preventDefault());
    form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
    const promises = [];
    const detail = {
      message: {json: () => Promise.resolve({selecto: {request_id: "1"}})},
      waitUntil: (promise) => promises.push(promise),
      cancelled: false,
    };
    document.querySelector("#selecto-page-channel-products").dispatchEvent(
      new CustomEvent("htmx:ws:before:message:incoming", {bubbles: true, detail}));
    await Promise.all(promises);
  });
  expect(page.url()).toContain("f_brand=North");
  expect(page.url()).not.toContain("selecto_request_id");
});
