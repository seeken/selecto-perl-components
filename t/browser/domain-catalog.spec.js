import {test, expect} from '@playwright/test';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import net from 'node:net';
import path from 'node:path';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {testPerl} from './test-perl.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
let server, base;
test.beforeAll(async () => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${listener.address().port}`;
  await new Promise(resolve => listener.close(resolve));
  server = spawn('script/with-local-sibling', [testPerl(root), 't/browser/fixtures/domain-catalog.pl', 'daemon', '-l', base], {cwd: root, stdio: 'pipe'});
  let output = '';
  server.stdout.on('data', chunk => { output += chunk; });
  server.stderr.on('data', chunk => { output += chunk; });
  await expect.poll(async () => {
    if (server.exitCode !== null) throw new Error(output);
    try { return (await fetch(base + '/catalog', {signal: AbortSignal.timeout(1000)})).status; }
    catch (_) { return 0; }
  }).toBe(200);
});
test.afterAll(async () => {
  if (server && server.exitCode === null) {
    const stopped = once(server, 'exit');
    server.kill('SIGTERM');
    await stopped;
  }
});

for (const scheme of ['light', 'dark']) {
  for (const viewport of [{width: 1280, height: 800}, {width: 375, height: 812}]) {
    for (const detail of [false, true]) {
      test(`${detail ? 'domain' : 'list'} ${scheme} ${viewport.width}`, async ({page}) => {
        await page.setViewportSize(viewport);
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        const external = [];
        page.on('request', request => { if (!request.url().startsWith(base)) external.push(request.url()); });
        await page.goto(base + `/catalog?scheme=${scheme}${detail ? '&domain=store_orders' : ''}`);
        await expect(page.locator('h1')).toHaveText(detail ? 'Stored orders' : 'Domain catalog');
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        expect(errors).toEqual([]);
        expect(external).toEqual([]);
        if (process.env.CATALOG_SCREENSHOT_DIR) {
          await mkdir(process.env.CATALOG_SCREENSHOT_DIR, {recursive: true});
          await page.screenshot({path: path.join(process.env.CATALOG_SCREENSHOT_DIR,
            `${detail ? 'domain' : 'list'}-${scheme}-${viewport.width}.png`), fullPage: false});
        }
      });
    }
  }
}
test('filters, baseline selection and canonical JSON copy work', async ({page, context}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.goto(base + '/catalog');
  await page.getByRole('searchbox', {name: 'Search'}).fill('Stored orders');
  await page.getByRole('button', {name: 'Filter', exact: true}).click();
  await expect(page.locator('tbody tr')).toHaveCount(1);
  await page.getByRole('link', {name: 'Stored orders', exact: true}).click();
  await page.getByLabel('Earlier fingerprint or baseline ID').fill('first');
  await page.getByRole('button', {name: 'Compare', exact: true}).click();
  await expect(page).toHaveURL(/against=first/);
  await page.locator('summary').click();
  const canonical = await page.locator('#sc-catalog-json').textContent();
  await page.getByRole('button', {name: 'Copy JSON', exact: true}).click();
  await expect(page.locator('[data-sc-catalog-copy-status]')).toHaveText('Copied');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(canonical);
  expect(JSON.parse(canonical).domain_version).toBe('1');
});
test('ordinary GET navigation works without JavaScript', async ({browser}) => {
  const context = await browser.newContext({javaScriptEnabled: false, viewport: {width: 375, height: 812}});
  const page = await context.newPage();
  await page.goto(base + '/catalog');
  await page.getByLabel('Source kind').selectOption('file');
  await page.getByRole('button', {name: 'Filter', exact: true}).click();
  await expect(page.locator('tbody tr')).toHaveCount(1);
  await page.getByRole('link', {name: 'File orders', exact: true}).click();
  await expect(page.locator('h1')).toHaveText('File orders');
  await page.locator('summary').click();
  await expect(page.locator('#sc-catalog-json')).toBeVisible();
  await context.close();
});
