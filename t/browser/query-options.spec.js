import {expect, test} from '@playwright/test';
import path from 'node:path';

const bundle = path.resolve('public/selecto-components/selecto-components.js');

test('host controls rerun the form and reset pagination', async ({page}) => {
  await page.setContent(`<form>
    <input name="page" value="4"><input type="hidden" name="backend" value="postgresql">
    <label>Snapshot<input type="checkbox" name="backend" value="duckdb" data-sc-query-option></label>
    <label>Mode<select name="mode" data-sc-query-option><option>normal</option><option>fast</option></select></label>
  </form>`);
  await page.evaluate(() => {
    window.submissions = [];
    document.querySelector('form').addEventListener('submit', event => {
      event.preventDefault();
      window.submissions.push([...new FormData(event.target).entries()]);
    });
  });
  await page.addScriptTag({path: bundle});
  await page.getByLabel('Snapshot').check();
  expect(await page.evaluate(() => window.submissions[0])).toContainEqual(['page', '1']);
  expect(await page.evaluate(() => window.submissions[0])).toContainEqual(['backend', 'duckdb']);
  await page.getByLabel('Snapshot').uncheck();
  expect((await page.evaluate(() => window.submissions[1])).filter(([key]) => key === 'backend'))
    .toEqual([['backend', 'postgresql']]);
  await page.getByLabel('Mode').selectOption('fast');
  expect(await page.evaluate(() => window.submissions[2])).toContainEqual(['mode', 'fast']);
});

test('action lookups and pivot searches carry host choices', async ({page}) => {
  await page.setContent(`<form data-sc-action-form>
    <input type="hidden" data-sc-query-option-value name="backend" value="duckdb">
    <div data-sc-action-lookup>
      <input type="hidden" name="action_input_carrier" data-sc-lookup-value>
      <input type="search" data-sc-lookup-query data-sc-lookup-url="https://example.test/lookup"
        data-sc-lookup-input="carrier" data-sc-lookup-minimum-length="2" aria-label="Carrier">
      <div data-sc-lookup-results role="listbox" hidden></div>
    </div>
  </form>
  <form action="https://example.test/events">
    <input type="hidden" name="backend" value="postgresql">
    <input type="checkbox" name="backend" value="duckdb" data-sc-query-option checked>
    <div data-sc-picker-set-item data-field="region"><div data-sc-pivot-values>
      <input type="search" data-sc-pivot-search aria-label="Pivot values"><div data-sc-pivot-options></div>
    </div></div>
  </form>`);
  await page.evaluate(() => {
    window.requests = [];
    window.fetch = async (url, options) => {
      window.requests.push({url: String(url), body: options.body && options.body.toString()});
      return {ok: true, json: async () => ({results: [], choices: []})};
    };
  });
  await page.addScriptTag({path: bundle});
  await page.getByLabel('Carrier').fill('Acme');
  await expect.poll(() => page.evaluate(() => window.requests.length)).toBe(1);
  const lookup = await page.evaluate(() => window.requests[0]);
  expect(new URL(lookup.url).searchParams.get('backend')).toBe('duckdb');
  await page.getByLabel('Pivot values').fill('East');
  await expect.poll(() => page.evaluate(() => window.requests.some(request =>
    request.body && new URLSearchParams(request.body).get('term') === 'East'))).toBe(true);
  const pivot = await page.evaluate(() => window.requests.find(request =>
    request.body && new URLSearchParams(request.body).get('term') === 'East'));
  expect(new URLSearchParams(pivot.body).getAll('backend')).toEqual(['duckdb']);
});

test('browser-built export URLs omit defaults and keep one non-default value', async ({page}) => {
  await page.route('https://example.test/**', route => route.fulfill({contentType: 'text/html', body: '<main></main>'}));
  await page.goto('https://example.test/events');
  await page.setContent(`<section id="selecto-surface-events"><form action="/events" data-sc-builder="events">
    <input type="hidden" name="backend" value="postgresql">
    <input type="checkbox" name="backend" value="duckdb" data-sc-query-option data-sc-query-option-default="postgresql">
    </form><a data-sc-export-format="csv" href="/events?format=csv">CSV</a></section>`);
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.addEventListener('click', event => event.preventDefault()));
  await page.getByText('CSV', {exact: true}).click();
  expect(new URL(await page.getByText('CSV', {exact: true}).getAttribute('href'), page.url()).searchParams.has('backend'))
    .toBe(false);
  await page.locator('[data-sc-query-option]').evaluate(input => { input.checked = true; });
  await page.getByText('CSV', {exact: true}).click();
  expect(new URL(await page.getByText('CSV', {exact: true}).getAttribute('href'), page.url()).searchParams.getAll('backend'))
    .toEqual(['duckdb']);
});
