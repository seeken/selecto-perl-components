import {expect, test} from '@playwright/test';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../public/selecto-components/selecto-components.js');

async function privatePage(page) {
  await page.route('http://selecto.test/**', route => route.fulfill({contentType: 'text/html', body: '<section id="selecto-surface-private" data-sc-query-params="disabled"><input value="secret-filter"><p>secret-result</p></section>'}));
  await page.goto('http://selecto.test/explore/private');
  await page.evaluate(() => {
    sessionStorage.setItem('selecto-history:legacy', '<section>secret-old</section>');
    history.replaceState({selectoSnapshot: 'legacy'}, '');
  });
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event('DOMContentLoaded')));
}
test('private surfaces purge legacy history and never snapshot on initialization or pagehide', async ({page}) => {
  await privatePage(page);
  expect(await page.evaluate(() => Object.keys(sessionStorage).filter(k => k.startsWith('selecto-history:')))).toEqual([]);
  expect(await page.evaluate(() => history.state.selectoSnapshot)).toBeUndefined();
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pagehide', {persisted: true})));
  await expect(page.locator('#selecto-surface-private')).toBeEmpty();
  expect(await page.evaluate(() => Object.keys(sessionStorage).filter(k => k.startsWith('selecto-history:')))).toEqual([]);
});
for (const event of ['popstate', 'pageshow', 'selecto:context-changed']) {
  test(`private ${event} returns through the server`, async ({page}) => {
    await privatePage(page);
    let reloads = 0;
    await page.route('http://selecto.test/**', route => { reloads++; return route.fulfill({contentType: 'text/html', body: '<p>Reauthorized</p>'}); });
    await page.evaluate(name => window.dispatchEvent(name === 'pageshow' ? new PageTransitionEvent(name, {persisted: true}) : new Event(name)), event);
    await expect(page.locator('p')).toHaveText('Reauthorized');
    expect(reloads).toBe(1);
    expect(await page.evaluate(() => Object.keys(sessionStorage).filter(k => k.startsWith('selecto-history:')))).toEqual([]);
  });
}

test('a public page refuses an unversioned legacy private snapshot', async ({page}) => {
  await page.route('http://selecto.test/**', route => route.fulfill({contentType:'text/html',body:'<section id="selecto-surface-public" data-sc-query-params="enabled"><p>Public</p></section>'}));
  await page.goto('http://selecto.test/public');
  await page.addScriptTag({path:bundle});
  await page.evaluate(() => document.dispatchEvent(new Event('DOMContentLoaded')));
  let reloads=0;
  await page.route('http://selecto.test/**', route => {reloads++; return route.fulfill({contentType:'text/html',body:'<p>Reauthorized</p>'});});
  await page.evaluate(() => {
    sessionStorage.setItem('selecto-history:old-private','<section id="selecto-surface-private"><p>secret-old</p></section>');
    window.dispatchEvent(new PopStateEvent('popstate',{state:{selectoSnapshot:'old-private'}}));
    if (document.body.textContent.includes('secret-old')) throw new Error('private snapshot became visible');
    if (document.querySelector('[id^="selecto-surface-"]')?.textContent) throw new Error('surface was not cleared before reload');
  });
  await expect(page.locator('p')).toHaveText('Reauthorized');
  expect(reloads).toBe(1);
});
