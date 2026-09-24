import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  "../../public/selecto-components/canned-page.js");

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
