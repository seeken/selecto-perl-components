import {expect, test} from "@playwright/test";
import path from "node:path";
import {fileURLToPath} from "node:url";

const htmxBundle = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../public/selecto-components/htmx.min.js",
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
