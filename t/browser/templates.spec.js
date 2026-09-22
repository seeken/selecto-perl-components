import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const htmxBundle = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../public/selecto-components/htmx.min.js",
);
const websocketBundle = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../public/selecto-components/hx-ws.min.js",
);
const componentsBundle = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../public/selecto-components/selecto-components.js",
);

async function loadTemplate(page, response) {
  const requests = [];
  await page.route("http://selecto.test/**", async route => {
    const request = route.request();
    if (request.method() === "POST") {
      requests.push(request);
      return route.fulfill({
        status: response.status,
        contentType: "text/html",
        body: response.body,
      });
    }
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><html><body>
        <main id="template-root" hx-history="false"
          hx-status:4xx="swap: outerHTML" hx-status:5xx="swap: outerHTML">
          <form method="post" action="/template-instances/one/events"
            hx-post="/template-instances/one/events"
            hx-target="#template-root" hx-swap="outerHTML">
            <input name="value" value="PO-100">
            <button type="submit">Search</button>
          </form>
        </main>
      </body></html>`,
    });
  });
  await page.goto("http://selecto.test/templates/orders");
  await page.addScriptTag({path: htmxBundle});
  await page.evaluate(() => {
    window.templateResponseErrors = [];
    document.addEventListener("htmx:response:error", event => {
      window.templateResponseErrors.push(event.detail.ctx.response.status);
    });
    window.htmx.process(document.body);
  });
  return requests;
}

test("a template event swaps its stable root with the pinned htmx runtime", async ({page}) => {
  const requests = await loadTemplate(page, {
    status: 200,
    body: '<main id="template-root" data-selecto-state-revision="1">Updated</main>',
  });

  await page.getByRole("button", {name: "Search"}).click();

  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-state-revision", "1",
  );
  expect(requests).toHaveLength(1);
  expect(requests[0].headers()["hx-request"]).toBe("true");
  expect(requests[0].headers()["hx-target"]).toBe("main#template-root");
});

test("a template event uses the pinned WebSocket envelope without replacing its channel", async ({page}) => {
  await page.route("http://selecto.test/**", route => route.fulfill({
    status: 200,
    contentType: "text/html",
    body: `<!doctype html><html><body>
      <section id="selecto-channel-template-one" hx-ext="ws"
        hx-ws:connect="/template-instances/one/ws" hx-swap="none">
        <main id="template-root" data-selecto-template-instance="one"
          data-selecto-state-revision="0" data-selecto-store-revision="0">
          <form method="post" action="/template-instances/one/events"
            hx-ws:send data-selecto-template-event="search_changed">
            <input type="hidden" name="template_action" value="event">
            <input type="hidden" name="csrf_token" value="csrf-one">
            <input type="hidden" name="event" value="search_changed">
            <input type="hidden" name="event_id" value="event-one">
            <input type="hidden" name="state_revision" value="0">
            <input name="value" value="PO-100">
            <button type="submit">Search</button>
          </form>
        </main>
      </section>
    </body></html>`,
  }));
  await page.addInitScript(() => {
    class FakeWebSocket extends EventTarget {
      static CONNECTING = 0;
      static OPEN = 1;
      static CLOSING = 2;
      static CLOSED = 3;
      constructor(url) {
        super();
        this.url = url;
        this.readyState = FakeWebSocket.CONNECTING;
        window.fakeTemplateSocket = this;
        queueMicrotask(() => {
          this.readyState = FakeWebSocket.OPEN;
          this.dispatchEvent(new Event("open"));
        });
      }
      send(message) {
        window.fakeTemplateMessages ||= [];
        window.fakeTemplateMessages.push(message);
      }
      close() {
        this.readyState = FakeWebSocket.CLOSED;
        this.dispatchEvent(new CloseEvent("close", {code: 1000}));
      }
    }
    window.WebSocket = FakeWebSocket;
  });
  await page.goto("http://selecto.test/templates/orders");
  await page.addScriptTag({path: htmxBundle});
  await page.addScriptTag({path: websocketBundle});
  await page.addScriptTag({path: componentsBundle});
  await page.evaluate(() => {
    window.htmx.process(document.body);
    document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true}));
  });

  await page.getByRole("button", {name: "Search"}).click();
  await expect.poll(() => page.evaluate(
    () => window.fakeTemplateMessages?.length || 0,
  )).toBe(1);
  const outgoing = await page.evaluate(() => JSON.parse(window.fakeTemplateMessages[0]));
  expect(outgoing).toMatchObject({
    template_action: "event",
    csrf_token: "csrf-one",
    event: "search_changed",
    event_id: "event-one",
    state_revision: "0",
    value: "PO-100",
  });
  expect(outgoing).not.toHaveProperty("selecto_request_id");

  await page.evaluate(() => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<main id="template-root" data-selecto-template-instance="one"
        data-selecto-state-revision="2" data-selecto-store-revision="2">Updated</main>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {instance_id: "one", state_revision: 2, store_revision: 2},
    })}));
  });
  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-state-revision", "2",
  );
  await expect(page.locator("#selecto-channel-template-one")).toHaveCount(1);

  await page.evaluate(async () => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<main id="template-root" data-selecto-template-instance="one"
        data-selecto-state-revision="1" data-selecto-store-revision="1">Stale</main>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {instance_id: "one", state_revision: 1, store_revision: 1},
    })}));
    await new Promise(resolve => setTimeout(resolve, 20));
  });
  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-store-revision", "2",
  );
  await expect(page.locator("#template-root")).toHaveText("Updated");

  await page.evaluate(async () => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<main id="template-root" data-selecto-template-instance="one"
        data-selecto-state-revision="3" data-selecto-store-revision="3">Wrong instance</main>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {instance_id: "two", state_revision: 3, store_revision: 3},
    })}));
    await new Promise(resolve => setTimeout(resolve, 20));
  });
  await expect(page.locator("#template-root")).toHaveText("Updated");
});

test("a late HTTP template response cannot replace a newer root revision", async ({page}) => {
  let releaseResponse;
  const responseGate = new Promise(resolve => { releaseResponse = resolve; });
  let requestStarted;
  const started = new Promise(resolve => { requestStarted = resolve; });
  await page.route("http://selecto.test/**", async route => {
    const request = route.request();
    if (request.method() === "POST") {
      requestStarted();
      await responseGate;
      return route.fulfill({
        status: 200,
        contentType: "text/html",
        headers: {
          "X-Selecto-Template-Instance": "one",
          "X-Selecto-State-Revision": "1",
          "X-Selecto-Store-Revision": "1",
        },
        body: `<main id="template-root" data-selecto-template-instance="one"
          data-selecto-state-revision="1" data-selecto-store-revision="1">Late</main>`,
      });
    }
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><html><body>
        <main id="template-root" data-selecto-template-instance="one"
          data-selecto-state-revision="0" data-selecto-store-revision="0">
          <form method="post" action="/template-instances/one/events"
            hx-post="/template-instances/one/events"
            hx-target="#template-root" hx-swap="outerHTML">
            <button type="submit">Search</button>
          </form>
        </main>
      </body></html>`,
    });
  });
  await page.goto("http://selecto.test/templates/orders");
  await page.addScriptTag({path: htmxBundle});
  await page.addScriptTag({path: componentsBundle});
  await page.evaluate(() => {
    window.templateRequestFinished = new Promise(resolve => {
      document.addEventListener("htmx:finally:request", () => resolve(true), {once: true});
    });
    window.htmx.process(document.body);
  });

  await page.getByRole("button", {name: "Search"}).click();
  await started;
  await page.locator("#template-root").evaluate(root => {
    root.dataset.selectoStateRevision = "2";
    root.dataset.selectoStoreRevision = "2";
    root.replaceChildren("Newer");
  });
  releaseResponse();
  await page.evaluate(() => window.templateRequestFinished);

  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-store-revision", "2",
  );
  await expect(page.locator("#template-root")).toHaveText("Newer");
});

for (const status of [409, 422]) {
  test(`a ${status} template response deliberately swaps its bounded error fragment`, async ({page}) => {
    await loadTemplate(page, {
      status,
      body: `<section data-selecto-template-error="status-${status}" role="alert">
        Reload and try again.
      </section>`,
    });

    await page.getByRole("button", {name: "Search"}).click();

    await expect(page.locator(`[data-selecto-template-error="status-${status}"]`))
      .toBeVisible();
    await expect(page.locator("#template-root")).toHaveCount(0);
    expect(await page.evaluate(() => window.templateResponseErrors)).toEqual([status]);
  });
}
