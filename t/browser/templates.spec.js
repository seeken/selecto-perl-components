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
          <div id="search-region" data-selecto-template-node="root.children.5">
            <form method="post" action="/template-instances/one/events"
              hx-ws:send data-selecto-template-event="search_changed">
              <input type="hidden" name="template_action" value="event">
              <input type="hidden" name="csrf_token" value="csrf-one">
              <input type="hidden" name="event" value="search_changed">
              <input type="hidden" name="event_id" value="event-one">
              <input type="hidden" name="state_revision" value="0">
              <input type="hidden" name="component_id" value="root.children.5">
              <input type="hidden" name="component_lifetime" value="lifetime-one">
              <input type="hidden" name="form_revision" value="0">
              <input id="template-search" name="value" value="PO-100">
              <button type="submit">Search</button>
            </form>
          </div>
          <div id="note-region" data-selecto-template-node="root.children.8">
            <input id="template-note" name="note" value="Server note">
          </div>
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

  await page.locator("#template-search").fill("PO-200");
  await page.locator("#template-note").fill("Unsent note");
  await page.evaluate(() => {
    const note = document.querySelector("#template-note");
    note.focus();
    note.setSelectionRange(2, 6);
    document.querySelector('[data-selecto-template-event="search_changed"]').requestSubmit();
  });
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
    component_id: "root.children.5",
    component_lifetime: "lifetime-one",
    form_revision: "1",
    value: "PO-200",
  });
  expect(outgoing).not.toHaveProperty("selecto_request_id");

  await page.evaluate(() => {
    const search = document.querySelector("#template-search");
    search.value = "PO-300";
    search.dispatchEvent(new InputEvent("input", {bubbles: true}));
    search.form.requestSubmit();
  });
  await page.waitForTimeout(20);
  expect(await page.evaluate(() => window.fakeTemplateMessages.length)).toBe(1);

  await page.evaluate(() => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<template hx type="partial" hx-target="#search-region" hx-swap="outerHTML">
        <div id="search-region" data-selecto-template-node="root.children.5">
          <form method="post" action="/template-instances/one/events" hx-ws:send
            data-selecto-template-event="search_changed">
            <input type="hidden" name="template_action" value="event">
            <input type="hidden" name="csrf_token" value="csrf-two">
            <input type="hidden" name="event" value="search_changed">
            <input type="hidden" name="event_id" value="event-two">
            <input type="hidden" name="state_revision" value="2">
            <input type="hidden" name="component_id" value="root.children.5">
            <input type="hidden" name="component_lifetime" value="lifetime-two">
            <input type="hidden" name="form_revision" value="2">
            <input id="template-search" name="value" value="Server search">
            <button type="submit">Search</button>
          </form>
          <span>Updated</span>
        </div>
      </template>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {
        instance_id: "one", state_revision: 2, store_revision: 2,
        event_id: "event-one",
        component_id: "root.children.5",
        component_lifetime: "lifetime-one", form_revision: 1,
      },
    })}));
  });
  await expect.poll(() => page.evaluate(
    () => window.fakeTemplateMessages?.length || 0,
  )).toBe(2);
  const queuedOutgoing = await page.evaluate(
    () => JSON.parse(window.fakeTemplateMessages[1]),
  );
  expect(queuedOutgoing).toMatchObject({
    template_action: "event",
    csrf_token: "csrf-two",
    event: "search_changed",
    event_id: "event-two",
    state_revision: "2",
    component_id: "root.children.5",
    component_lifetime: "lifetime-two",
    form_revision: "2",
    value: "PO-300",
  });

  await page.evaluate(() => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<template hx type="partial" hx-target="#search-region" hx-swap="outerHTML">
        <div id="search-region" data-selecto-template-node="root.children.5">
          <form method="post" action="/template-instances/one/events" hx-ws:send
            data-selecto-template-event="search_changed">
            <input type="hidden" name="template_action" value="event">
            <input type="hidden" name="csrf_token" value="csrf-three">
            <input type="hidden" name="event" value="search_changed">
            <input type="hidden" name="event_id" value="event-three">
            <input type="hidden" name="state_revision" value="3">
            <input type="hidden" name="component_id" value="root.children.5">
            <input type="hidden" name="component_lifetime" value="lifetime-three">
            <input type="hidden" name="form_revision" value="3">
            <input id="template-search" name="value" value="Second server search">
            <button type="submit">Search</button>
          </form>
          <span>Second update</span>
        </div>
      </template>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {
        instance_id: "one", state_revision: 3, store_revision: 3,
        event_id: "event-two",
        component_id: "root.children.5",
        component_lifetime: "lifetime-two", form_revision: 2,
      },
    })}));
  });
  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-state-revision", "3",
  );
  await expect(page.locator("#selecto-channel-template-one")).toHaveCount(1);
  await expect(page.locator("#template-search")).toHaveValue("Second server search");
  await expect(page.locator("#template-note")).toHaveValue("Unsent note");
  expect(await page.evaluate(() => ({
    id: document.activeElement.id,
    start: document.activeElement.selectionStart,
    end: document.activeElement.selectionEnd,
  }))).toEqual({id: "template-note", start: 2, end: 6});

  await page.locator("#template-search").fill("Newer local draft");
  await page.evaluate(async () => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<section data-selecto-template-error="old-validation" role="alert">
        Old validation
      </section>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {
        status: 422, code: "invalid_event_value",
        instance_id: "one", state_revision: 3, store_revision: 3,
        event_id: "event-three", component_id: "root.children.5",
        component_lifetime: "lifetime-three", form_revision: 3,
      },
    })}));
    await new Promise(resolve => setTimeout(resolve, 20));
  });
  await expect(page.locator("#template-search")).toHaveValue("Newer local draft");
  await expect(page.locator('[data-selecto-template-error="old-validation"]'))
    .toHaveCount(0);

  await page.evaluate(async () => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<main id="template-root" data-selecto-template-instance="one"
        data-selecto-state-revision="4" data-selecto-store-revision="4">
        Resurrected component
      </main>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {
        instance_id: "one", state_revision: 4, store_revision: 4,
        event_id: "event-one", component_id: "root.children.5",
        component_lifetime: "lifetime-one", form_revision: 0,
      },
    })}));
    await new Promise(resolve => setTimeout(resolve, 20));
  });
  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-state-revision", "3",
  );
  await expect(page.locator("#template-root")).toContainText("Second update");

  await page.evaluate(async () => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<main id="template-root" data-selecto-template-instance="one"
        data-selecto-state-revision="2" data-selecto-store-revision="2">Stale</main>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {instance_id: "one", state_revision: 2, store_revision: 2},
    })}));
    await new Promise(resolve => setTimeout(resolve, 20));
  });
  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-store-revision", "3",
  );
  await expect(page.locator("#template-root")).toContainText("Second update");

  await page.evaluate(async () => {
    window.fakeTemplateSocket.dispatchEvent(new MessageEvent("message", {data: JSON.stringify({
      content: `<main id="template-root" data-selecto-template-instance="one"
        data-selecto-state-revision="4" data-selecto-store-revision="4">Wrong instance</main>`,
      target: "#template-root",
      swap: "outerHTML",
      selecto: {instance_id: "two", state_revision: 4, store_revision: 4},
    })}));
    await new Promise(resolve => setTimeout(resolve, 20));
  });
  await expect(page.locator("#template-root")).toContainText("Second update");
});

test("an HTTP template swap preserves other dirty fields and focused selection", async ({page}) => {
  await page.route("http://selecto.test/**", route => {
    if (route.request().method() === "POST") {
      return route.fulfill({
        status: 200,
        contentType: "text/html",
        headers: {
          "X-Selecto-Template-Instance": "one",
          "X-Selecto-State-Revision": "1",
          "X-Selecto-Store-Revision": "1",
          "X-Selecto-Event-ID": "event-one",
        },
        body: `<template hx type="partial" hx-target="#search-region" hx-swap="outerHTML">
          <div id="search-region" data-selecto-template-node="root.children.5">
            <form method="post" action="/events" hx-post="/events"
              hx-target="#template-root" hx-swap="outerHTML">
              <input type="hidden" name="event_id" value="event-one">
              <input id="template-search" name="value" value="Server search">
            </form>
          </div>
        </template>`,
      });
    }
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><html><body>
        <main id="template-root" data-selecto-template-instance="one"
          data-selecto-state-revision="0" data-selecto-store-revision="0">
          <div id="search-region" data-selecto-template-node="root.children.5">
            <form method="post" action="/events" hx-post="/events"
              hx-target="#template-root" hx-swap="outerHTML">
              <input type="hidden" name="event_id" value="event-one">
              <input id="template-search" name="value" value="Initial search">
            </form>
          </div>
          <div id="note-region" data-selecto-template-node="root.children.8">
            <input id="template-note" name="note" value="Server note">
          </div>
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

  await page.locator("#template-search").fill("Submitted search");
  await page.locator("#template-note").fill("Unsent note");
  await page.evaluate(() => {
    const note = document.querySelector("#template-note");
    note.focus();
    note.setSelectionRange(1, 7);
    document.querySelector("#template-search").form.requestSubmit();
  });
  await page.evaluate(() => window.templateRequestFinished);

  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-store-revision", "1",
  );
  await expect(page.locator("#template-search")).toHaveValue("Server search");
  await expect(page.locator("#template-note")).toHaveValue("Unsent note");
  expect(await page.evaluate(() => ({
    id: document.activeElement.id,
    start: document.activeElement.selectionStart,
    end: document.activeElement.selectionEnd,
  }))).toEqual({id: "template-note", start: 1, end: 7});
});

test("HTTP template events wait per form and rebuild queued requests from fresh server fields", async ({page}) => {
  const requests = [];
  let releaseFirstResponse;
  const firstResponseGate = new Promise(resolve => { releaseFirstResponse = resolve; });
  let firstRequestStarted;
  const firstStarted = new Promise(resolve => { firstRequestStarted = resolve; });
  await page.route("http://selecto.test/**", async route => {
    const request = route.request();
    if (request.method() === "POST") {
      requests.push(request);
      const requestNumber = requests.length;
      if (requestNumber === 1) {
        firstRequestStarted();
        await firstResponseGate;
      }
      const next = requestNumber === 1
        ? {eventId: "event-two", csrf: "csrf-two", revision: "1", value: "First server search"}
        : {eventId: "event-three", csrf: "csrf-three", revision: "2", value: "Second server search"};
      return route.fulfill({
        status: 200,
        contentType: "text/html",
        headers: {
          "X-Selecto-Template-Instance": "one",
          "X-Selecto-State-Revision": next.revision,
          "X-Selecto-Store-Revision": next.revision,
          "X-Selecto-Event-ID": requestNumber === 1 ? "event-one" : "event-two",
          "X-Selecto-Component-ID": "root.children.5",
          "X-Selecto-Component-Lifetime": requestNumber === 1
            ? "lifetime-one" : "lifetime-two",
          "X-Selecto-Form-Revision": requestNumber === 1 ? "1" : "2",
        },
        body: `<template hx type="partial" hx-target="#search-region" hx-swap="outerHTML">
          <div id="search-region" data-selecto-template-node="root.children.5">
            <form method="post" action="/events" hx-post="/events"
              hx-target="#template-root" hx-swap="outerHTML"
              data-selecto-template-event="search_changed">
              <input type="hidden" name="template_action" value="event">
              <input type="hidden" name="csrf_token" value="${next.csrf}">
              <input type="hidden" name="event" value="search_changed">
              <input type="hidden" name="event_id" value="${next.eventId}">
              <input type="hidden" name="state_revision" value="${next.revision}">
              <input type="hidden" name="component_id" value="root.children.5">
              <input type="hidden" name="component_lifetime"
                value="${requestNumber === 1 ? "lifetime-two" : "lifetime-three"}">
              <input type="hidden" name="form_revision" value="${next.revision}">
              <input id="template-search" name="value" value="${next.value}">
              <button type="submit">Search</button>
            </form>
          </div>
        </template>`,
      });
    }
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><html><body>
        <main id="template-root" data-selecto-template-instance="one"
          data-selecto-state-revision="0" data-selecto-store-revision="0">
          <div id="search-region" data-selecto-template-node="root.children.5">
            <form method="post" action="/events" hx-post="/events"
              hx-target="#template-root" hx-swap="outerHTML"
              data-selecto-template-event="search_changed">
              <input type="hidden" name="template_action" value="event">
              <input type="hidden" name="csrf_token" value="csrf-one">
              <input type="hidden" name="event" value="search_changed">
              <input type="hidden" name="event_id" value="event-one">
              <input type="hidden" name="state_revision" value="0">
              <input type="hidden" name="component_id" value="root.children.5">
              <input type="hidden" name="component_lifetime" value="lifetime-one">
              <input type="hidden" name="form_revision" value="0">
              <input id="template-search" name="value" value="PO-100">
              <button type="submit">Search</button>
            </form>
          </div>
        </main>
      </body></html>`,
    });
  });
  await page.goto("http://selecto.test/templates/orders");
  await page.addScriptTag({path: htmxBundle});
  await page.addScriptTag({path: componentsBundle});
  await page.evaluate(() => window.htmx.process(document.body));

  await page.locator("#template-search").fill("PO-200");
  await page.locator("#template-search").evaluate(input => input.form.requestSubmit());
  await firstStarted;
  await page.evaluate(() => {
    const search = document.querySelector("#template-search");
    search.value = "PO-300";
    search.dispatchEvent(new InputEvent("input", {bubbles: true}));
    search.form.requestSubmit();
  });
  await page.waitForTimeout(20);
  expect(requests).toHaveLength(1);

  releaseFirstResponse();
  await expect.poll(() => requests.length).toBe(2);
  const firstBody = new URLSearchParams(requests[0].postData());
  const secondBody = new URLSearchParams(requests[1].postData());
  expect(Object.fromEntries(firstBody)).toMatchObject({
    csrf_token: "csrf-one", event_id: "event-one", state_revision: "0", value: "PO-200",
    component_id: "root.children.5", component_lifetime: "lifetime-one",
    form_revision: "1",
  });
  expect(Object.fromEntries(secondBody)).toMatchObject({
    csrf_token: "csrf-two", event_id: "event-two", state_revision: "1", value: "PO-300",
    component_id: "root.children.5", component_lifetime: "lifetime-two",
    form_revision: "2",
  });
  await expect(page.locator("#template-root")).toHaveAttribute(
    "data-selecto-state-revision", "2",
  );
  await expect(page.locator("#template-search")).toHaveValue("Second server search");
});

test("a late HTTP validation response cannot replace a newer local draft", async ({page}) => {
  let releaseResponse;
  const responseGate = new Promise(resolve => { releaseResponse = resolve; });
  let requestStarted;
  const started = new Promise(resolve => { requestStarted = resolve; });
  await page.route("http://selecto.test/**", async route => {
    if (route.request().method() === "POST") {
      requestStarted();
      await responseGate;
      return route.fulfill({
        status: 422,
        contentType: "text/html",
        headers: {
          "X-Selecto-Template-Instance": "one",
          "X-Selecto-State-Revision": "0",
          "X-Selecto-Store-Revision": "0",
          "X-Selecto-Event-ID": "event-one",
          "X-Selecto-Component-ID": "root.children.5",
          "X-Selecto-Component-Lifetime": "lifetime-one",
          "X-Selecto-Form-Revision": "1",
        },
        body: '<section data-selecto-template-error="old-validation">Old validation</section>',
      });
    }
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><html><body>
        <main id="template-root" data-selecto-template-instance="one"
          data-selecto-state-revision="0" data-selecto-store-revision="0"
          hx-status:4xx="swap: outerHTML">
          <div data-selecto-template-node="root.children.5">
            <form method="post" action="/events" hx-post="/events"
              hx-target="#template-root" hx-swap="outerHTML"
              data-selecto-template-event="search_changed">
              <input type="hidden" name="template_action" value="event">
              <input type="hidden" name="csrf_token" value="csrf-one">
              <input type="hidden" name="event" value="search_changed">
              <input type="hidden" name="event_id" value="event-one">
              <input type="hidden" name="state_revision" value="0">
              <input type="hidden" name="component_id" value="root.children.5">
              <input type="hidden" name="component_lifetime" value="lifetime-one">
              <input type="hidden" name="form_revision" value="0">
              <input id="template-search" name="value" value="Initial">
              <button type="submit">Search</button>
            </form>
          </div>
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

  await page.locator("#template-search").fill("Submitted invalid draft");
  await page.locator("#template-search").evaluate(input => input.form.requestSubmit());
  await started;
  await page.locator("#template-search").fill("Newer local draft");
  releaseResponse();
  await page.evaluate(() => window.templateRequestFinished);

  await expect(page.locator("#template-root")).toHaveCount(1);
  await expect(page.locator("#template-search")).toHaveValue("Newer local draft");
  await expect(page.locator('[data-selecto-template-error="old-validation"]'))
    .toHaveCount(0);
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

test("Back and bfcache restoration reauthorize a private template document", async ({page}) => {
  let session = "alice";
  let templateRequests = 0;
  await page.route("http://selecto.test/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/away") {
      return route.fulfill({
        status: 200,
        contentType: "text/html",
        body: "<!doctype html><title>Away</title><p>Outside the template</p>",
      });
    }
    templateRequests += 1;
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      headers: {"Cache-Control": "no-store, private"},
      body: `<!doctype html><html><body>
        <main data-selecto-template-instance="${session}"
          data-selecto-state-revision="0" data-selecto-store-revision="0">
          Session ${session}
        </main>
      </body></html>`,
    });
  });

  await page.goto("http://selecto.test/templates/private");
  await expect(page.locator("main")).toHaveText("Session alice");
  await page.goto("http://selecto.test/away");
  session = "bob";
  await page.goBack();
  await expect(page.locator("main")).toHaveText("Session bob");
  expect(templateRequests).toBe(2);

  await page.addScriptTag({path: componentsBundle});
  session = "carol";
  await page.evaluate(() => {
    window.dispatchEvent(new PageTransitionEvent("pageshow", {persisted: true}));
  });
  await expect(page.locator("main")).toHaveText("Session carol");
  expect(templateRequests).toBe(3);
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
