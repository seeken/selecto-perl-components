import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public/selecto-components/selecto-components.js");

const tools = ["get_query_context", "search_choices", "validate_query_target", "apply_query_draft", "undo_query_draft"]
  .map(name => ({
    name, description: name, inputSchema: {
      type: "object",
      properties: {draft_id: {type: "string"}, base_revision: {type: "integer"}, context_version: {type: "string"}, target: {type: "object"}, request_id: {type: "string"}, undo_token: {type: "string"}},
      required: ["draft_id", ...(name === "undo_query_draft" ? ["base_revision", "undo_token"] : [])], additionalProperties: false
    }
  }));

function surface() {
  return `<section id="selecto-surface-products" data-sc-query-assistant="/explore/products/assistant/drafts"
      data-sc-query-assistant-csrf="csrf-token">
    <div data-sc-workspace><aside data-sc-builder-shell="products" data-sc-builder-collapsed="false">
      <form data-sc-builder data-sc-edit-generation="0">
        <input name="q" value="1"><input name="view" value="detail">
        <input name="field" value="product_name"><input name="limit" value="25">
        <strong data-sc-builder-pending></strong>
      </form>
      <div data-sc-query-assistant-status></div>
      <button type="button" data-sc-query-assistant-undo hidden>Undo</button>
    </aside><section id="results">Committed results stay here</section></div>
  </section>`;
}

test("WebMCP registers five tools and applies a builder-only response", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async definition => { window.registeredTools.push(definition); }
    }});
    window.fetchCalls = [];
    window.fetch = async (url, options) => {
      const request = {url: String(url), body: JSON.parse(options.body)};
      window.fetchCalls.push(request);
      if (request.url.endsWith("/assistant/drafts")) {
        return {ok: true, json: async () => ({ok: true, draft_id: "draft-1", revision: 0, context_version: "ctx-1", tools})};
      }
      if (request.url.endsWith("/tools/apply_query_draft")) {
        return {ok: true, json: async () => ({
          ok: true, revision: 1, undo_token: "undo-1", changes: [{path: "/view"}],
          builder_html: `<aside data-sc-builder-shell="products" data-sc-builder-collapsed="false">
            <form data-sc-builder><input name="view" value="graph"><strong data-sc-builder-pending></strong></form>
            <div data-sc-query-assistant-status></div><button type="button" data-sc-query-assistant-undo hidden>Undo</button>
          </aside>`
        })};
      }
      if (request.url.endsWith("/tools/undo_query_draft")) {
        return {ok: true, json: async () => ({ok: true, revision: 2,
          builder_html: `<aside data-sc-builder-shell="products"><form data-sc-builder><input name="view" value="detail"></form>
            <div data-sc-query-assistant-status></div><button type="button" data-sc-query-assistant-undo hidden>Undo</button></aside>`})};
      }
      return {ok: true, json: async () => ({ok: true, revision: 0, context_version: "ctx-1", active_target: {view: "detail"}})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  expect(await page.evaluate(() => window.registeredTools.map(tool => tool.name))).toEqual(tools.map(tool => tool.name));
  expect(await page.evaluate(() => window.registeredTools[0].inputSchema.properties.draft_id)).toBeUndefined();
  expect(await page.evaluate(() => window.registeredTools[4].inputSchema.required)).toEqual([]);
  expect(await page.evaluate(() => window.registeredTools[4].inputSchema.properties.undo_token)).toBeUndefined();

  const result = await page.evaluate(async () => {
    const tool = window.registeredTools.find(item => item.name === "apply_query_draft");
    return tool.execute({request_id: "req-1", target: {view: "graph"}});
  });
  expect(result.ok).toBe(true);
  expect(result.ui_applied).toBe(true);
  await expect(page.locator('[data-sc-builder] input[name="view"]')).toHaveValue("graph");
  await expect(page.locator("#results")).toHaveText("Committed results stay here");
  await expect(page.locator("[data-sc-query-assistant-undo]")).toBeVisible();
  const request = await page.evaluate(() => window.fetchCalls.find(call => call.url.endsWith("/tools/apply_query_draft")));
  expect(request.body).toMatchObject({draft_id: "draft-1", base_revision: 0, context_version: "ctx-1"});
  const undone = await page.evaluate(() => window.registeredTools.find(tool => tool.name === "undo_query_draft").execute({}));
  expect(undone.ui_applied).toBe(true);
  await expect(page.locator('[data-sc-builder] input[name="view"]')).toHaveValue("detail");
  await expect(page.locator("[data-sc-query-assistant-undo]")).toBeHidden();
  const undoRequest = await page.evaluate(() => window.fetchCalls.find(call => call.url.endsWith("/tools/undo_query_draft")));
  expect(undoRequest.body).toMatchObject({base_revision: 1, undo_token: "undo-1"});
});

test("the ordinary form remains usable when WebMCP is absent", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.fetch = async () => ({ok: true, json: async () => ({
      ok: true, draft_id: "draft-2", revision: 0, context_version: "ctx-2", tools
    })});
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect(page.locator("[data-sc-query-assistant-status]"))
    .toContainText("does not expose WebMCP");
  await expect(page.locator("[data-sc-builder]")).toBeVisible();
});

test("manual edits synchronize before a tool call and invalidate undo", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async definition => window.registeredTools.push(definition)
    }});
    window.fetchCalls = [];
    window.fetch = async (url, options) => {
      const request = {url: String(url), body: JSON.parse(options.body)};
      window.fetchCalls.push(request);
      if (request.url.endsWith("/assistant/drafts")) {
        return {ok: true, json: async () => ({ok: true, draft_id: "draft-sync", revision: 0, context_version: "ctx-sync", tools})};
      }
      if (request.url.endsWith("/sync")) {
        return {ok: true, json: async () => ({ok: true, revision: 1})};
      }
      return {ok: true, json: async () => ({ok: true, revision: 1, context_version: "ctx-sync", active_target: {view: "detail"}})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  await page.locator('[data-sc-builder] input[name="limit"]').fill("50");
  await page.evaluate(async () => {
    const tool = window.registeredTools.find(item => item.name === "get_query_context");
    await tool.execute({});
  });
  const calls = await page.evaluate(() => window.fetchCalls.map(call => call.url));
  expect(calls.findIndex(url => url.endsWith("/sync"))).toBeLessThan(
    calls.findIndex(url => url.endsWith("/tools/get_query_context"))
  );
  const sync = await page.evaluate(() => window.fetchCalls.find(call => call.url.endsWith("/sync")));
  expect(sync.body.input.limit).toBe("50");
});

test("a stale async response never replaces a locally changed form", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    window.releaseReady = false;
    let release;
    window.releaseApply = () => release();
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async definition => window.registeredTools.push(definition)
    }});
    window.fetch = async (url) => {
      if (String(url).endsWith("/assistant/drafts")) {
        return {ok: true, json: async () => ({ok: true, draft_id: "draft-stale", revision: 0, context_version: "ctx-stale", tools})};
      }
      if (String(url).endsWith("/tools/apply_query_draft")) {
        await new Promise(resolve => { release = resolve; window.releaseReady = true; });
        return {ok: true, json: async () => ({
          ok: true, revision: 1, undo_token: "undo-stale",
          builder_html: `<aside data-sc-builder-shell="products"><form data-sc-builder><input name="view" value="graph"></form><div data-sc-query-assistant-status></div></aside>`
        })};
      }
      return {ok: true, json: async () => ({ok: true, revision: 0})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  const pending = page.evaluate(async () => {
    const tool = window.registeredTools.find(item => item.name === "apply_query_draft");
    return tool.execute({request_id: "stale", target: {view: "graph"}});
  });
  await expect.poll(() => page.evaluate(() => window.releaseReady)).toBe(true);
  await page.locator('[data-sc-builder] input[name="limit"]').fill("50");
  await page.evaluate(() => window.releaseApply());
  const result = await pending;
  expect(result.ui_applied).toBe(false);
  await expect(page.locator('[data-sc-builder] input[name="view"]')).toHaveValue("detail");
  await expect(page.locator("[data-sc-query-assistant-status]")).toContainText("changed locally");
});

test("a replaced surface gets a fresh draft and failed registration aborts partial tools", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.bootstrapCount = 0;
    window.signals = [];
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async (definition, options) => {
        window.signals.push(options.signal);
        if (window.bootstrapCount === 1 && definition.name === "validate_query_target") {
          throw new Error("registration rejected");
        }
      }
    }});
    window.fetch = async url => {
      if (String(url).endsWith("/assistant/drafts")) {
        window.bootstrapCount += 1;
        return {ok: true, json: async () => ({ok: true, draft_id: `draft-${window.bootstrapCount}`, revision: 0, context_version: "ctx", tools})};
      }
      return {ok: true, json: async () => ({ok: true})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect(page.locator("[data-sc-query-assistant-status]")).toContainText("registration rejected");
  expect(await page.evaluate(() => window.signals.every(signal => signal.aborted))).toBe(true);
  await page.evaluate(html => {
    document.querySelector("[data-sc-query-assistant]").outerHTML = html;
    document.dispatchEvent(new Event("htmx:after:swap", {bubbles: true}));
  }, surface());
  await expect.poll(() => page.evaluate(() => window.bootstrapCount)).toBe(2);
});

test("an edit during synchronization is preserved when the assistant response arrives", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    window.fetchCalls = [];
    window.syncPending = false;
    let release;
    window.releaseSync = () => release();
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async definition => window.registeredTools.push(definition)
    }});
    window.fetch = async (url, options) => {
      window.fetchCalls.push({url: String(url), body: JSON.parse(options.body)});
      if (String(url).endsWith("/assistant/drafts")) {
        return {ok: true, json: async () => ({ok: true, draft_id: "draft-sync-race", revision: 0, context_version: "ctx", tools})};
      }
      if (String(url).endsWith("/sync")) {
        await new Promise(resolve => {release = resolve; window.syncPending = true;});
        return {ok: true, json: async () => ({ok: true, revision: 1})};
      }
      return {ok: true, json: async () => ({ok: true, revision: 2, undo_token: "undo",
        builder_html: `<aside data-sc-builder-shell="products"><form data-sc-builder><input name="limit" value="100"></form></aside>`})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  await page.locator('[data-sc-builder] input[name="limit"]').fill("50");
  const pending = page.evaluate(() => window.registeredTools.find(tool => tool.name === "apply_query_draft")
    .execute({request_id: "sync-race", target: {view: "detail"}}));
  await expect.poll(() => page.evaluate(() => window.syncPending)).toBe(true);
  await page.locator('[data-sc-builder] input[name="limit"]').fill("75");
  await page.evaluate(() => window.releaseSync());
  const result = await pending;
  expect(result.ui_applied).toBe(false);
  await expect(page.locator('[data-sc-builder] input[name="limit"]')).toHaveValue("75");
  expect(await page.evaluate(() => window.fetchCalls.find(call => call.url.endsWith("/sync")).body.input.limit)).toBe("50");
});

test("concurrent tool calls share one synchronization and use the resulting revision", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    window.fetchCalls = [];
    window.syncPending = false;
    let release;
    window.releaseSync = () => release();
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async definition => window.registeredTools.push(definition)
    }});
    window.fetch = async (url, options) => {
      window.fetchCalls.push({url: String(url), body: JSON.parse(options.body)});
      if (String(url).endsWith("/assistant/drafts")) {
        return {ok: true, json: async () => ({ok: true, draft_id: "draft-queue", revision: 0, context_version: "ctx", tools})};
      }
      if (String(url).endsWith("/sync")) {
        await new Promise(resolve => {release = resolve; window.syncPending = true;});
      }
      return {ok: true, json: async () => ({ok: true, revision: 1})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  await page.locator('[data-sc-builder] input[name="limit"]').fill("50");
  const pending = page.evaluate(() => Promise.all([
    window.registeredTools.find(tool => tool.name === "get_query_context").execute({}),
    window.registeredTools.find(tool => tool.name === "validate_query_target").execute({target: {view: "detail"}})
  ]));
  await expect.poll(() => page.evaluate(() => window.syncPending)).toBe(true);
  await page.evaluate(() => window.releaseSync());
  await pending;
  const calls = await page.evaluate(() => window.fetchCalls);
  expect(calls.filter(call => call.url.endsWith("/sync"))).toHaveLength(1);
  expect(calls.find(call => call.url.endsWith("/tools/validate_query_target")).body.base_revision).toBe(1);
});

test("an abandoned bootstrap cannot delete or register tools for a replacement surface", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    window.bootstrapCount = 0;
    window.bootstrapPending = false;
    window.oldSignal = null;
    let release;
    window.releaseBootstrap = () => release();
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async (definition, options) => window.registeredTools.push({definition, signal: options.signal})
    }});
    window.fetch = async (url, options) => {
      if (String(url).endsWith("/assistant/drafts")) {
        const count = ++window.bootstrapCount;
        if (count === 1) {
          window.oldSignal = options.signal;
          // Simulate a response that already arrived when cancellation occurred.
          await new Promise(resolve => {release = resolve; window.bootstrapPending = true;});
        }
        return {ok: true, json: async () => ({ok: true, draft_id: `draft-${count}`, revision: 0, context_version: "ctx", tools})};
      }
      return {ok: true, json: async () => ({ok: true, revision: 0})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.bootstrapPending)).toBe(true);
  await page.evaluate(html => {
    document.querySelector("[data-sc-query-assistant]").outerHTML = html;
    document.dispatchEvent(new Event("htmx:after:swap", {bubbles: true}));
  }, surface());
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  expect(await page.evaluate(() => window.oldSignal.aborted)).toBe(true);
  await page.evaluate(() => window.releaseBootstrap());
  await page.evaluate(() => document.dispatchEvent(new Event("htmx:after:swap", {bubbles: true})));
  expect(await page.evaluate(() => window.bootstrapCount)).toBe(2);
  expect(await page.evaluate(() => window.registeredTools.length)).toBe(5);
  await expect(page.locator("[data-sc-query-assistant-status]")).toContainText("registered");
});

test("removed surfaces unregister their tools and a history restore starts a new draft", async ({page}) => {
  await page.route("http://selecto.test/explorer", route => route.fulfill({body: surface(), contentType: "text/html"}));
  await page.goto("http://selecto.test/explorer");
  await page.evaluate(({tools}) => {
    window.bootstrapCount = 0;
    window.registrations = [];
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async (definition, options) => window.registrations.push({definition, signal: options.signal})
    }});
    window.fetch = async () => ({ok: true, json: async () => ({
      ok: true, draft_id: `draft-${++window.bootstrapCount}`, revision: 0, context_version: "ctx", tools
    })});
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registrations.length)).toBe(5);
  await page.evaluate(() => {
    const state = window.history.state;
    document.querySelector('[data-sc-builder] input[name="limit"]').value = "75";
    window.dispatchEvent(new PopStateEvent("popstate", {state}));
  });
  await expect.poll(() => page.evaluate(() => window.registrations.length)).toBe(10);
  expect(await page.evaluate(() => window.registrations.slice(0, 5).every(item => item.signal.aborted))).toBe(true);
  await expect(page.locator('[data-sc-builder] input[name="limit"]')).toHaveValue("25");
  await page.evaluate(() => {
    document.querySelector("[data-sc-query-assistant]").remove();
    document.dispatchEvent(new Event("htmx:after:swap", {bubbles: true}));
  });
  expect(await page.evaluate(() => window.registrations.every(item => item.signal.aborted))).toBe(true);
});

test("an old idempotency receipt cannot replace a newer draft or restore its undo token", async ({page}) => {
  await page.setContent(surface());
  await page.evaluate(({tools}) => {
    window.registeredTools = [];
    window.fetchCalls = [];
    Object.defineProperty(document, "modelContext", {value: {
      registerTool: async definition => window.registeredTools.push(definition)
    }});
    window.fetch = async (url, options) => {
      const request = {url: String(url), body: JSON.parse(options.body)};
      window.fetchCalls.push(request);
      if (request.url.endsWith("/assistant/drafts")) {
        return {ok: true, json: async () => ({ok: true, draft_id: "draft-replay", revision: 0, context_version: "ctx-1", tools})};
      }
      if (request.url.endsWith("/tools/apply_query_draft")) {
        return {ok: true, json: async () => ({ok: true, revision: 1, context_version: "ctx-1", undo_token: "undo-old",
          builder_html: `<aside data-sc-builder-shell="products"><form data-sc-builder><input name="view" value="graph"></form>
            <button data-sc-query-assistant-undo hidden>Undo</button><div data-sc-query-assistant-status></div></aside>`})};
      }
      if (request.url.endsWith("/tools/undo_query_draft")) {
        return {ok: true, json: async () => ({ok: true, revision: 2, context_version: "ctx-2",
          builder_html: `<aside data-sc-builder-shell="products"><form data-sc-builder><input name="view" value="detail"></form>
            <button data-sc-query-assistant-undo hidden>Undo</button><div data-sc-query-assistant-status></div></aside>`})};
      }
      return {ok: true, json: async () => ({ok: true, revision: 2, context_version: "ctx-2"})};
    };
  }, {tools});
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded", {bubbles: true})));
  await expect.poll(() => page.evaluate(() => window.registeredTools.length)).toBe(5);
  const replay = await page.evaluate(async () => {
    const apply = window.registeredTools.find(tool => tool.name === "apply_query_draft");
    await apply.execute({request_id: "original", target: {view: "graph"}});
    await window.registeredTools.find(tool => tool.name === "undo_query_draft").execute({});
    const replay = await apply.execute({request_id: "original", target: {view: "graph"}});
    await window.registeredTools.find(tool => tool.name === "validate_query_target").execute({target: {view: "detail"}});
    return replay;
  });
  expect(replay.ui_applied).toBe(false);
  expect(replay.stale_receipt).toBe(true);
  await expect(page.locator('[data-sc-builder] input[name="view"]')).toHaveValue("detail");
  await expect(page.locator("[data-sc-query-assistant-undo]")).toBeHidden();
  const validate = await page.evaluate(() => window.fetchCalls.find(call => call.url.endsWith("/tools/validate_query_target")));
  expect(validate.body).toMatchObject({base_revision: 2, context_version: "ctx-2"});
});
