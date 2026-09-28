import {expect, test} from '@playwright/test';
import path from 'node:path';

const bundle = path.resolve('public/selecto-components/selecto-components.js');
const spec = {
  inputs: [{id: 'complete', type: 'boolean', trim: 1}, {id: 'note', type: 'string'}],
  variants: [
    {id: 'ready', label: 'Ready', when: {complete: true}, fields: ['note', 'reviewer']},
    {id: 'follow_up', label: 'Follow up', when: {complete: false}, fields: ['reason', 'documents']},
  ],
};
function markup(metadata = spec) {
  return `<form data-sc-action-form>
    <div data-sc-action-variants='${JSON.stringify(metadata)}'>
      <div data-sc-action-base>
        <label data-sc-action-input-id="complete">Complete<select name="action_input_complete" aria-label="Complete" required>
          <option value="">Choose</option><option value="true">Yes</option><option value="false" selected>No</option>
        </select></label>
        <label data-sc-action-input-id="note">Base note<input name="action_input_note" required></label>
      </div>
      <p data-sc-action-variant-status role="status"></p>
      <fieldset data-sc-action-variant="ready" disabled hidden><legend>Ready</legend>
        <label>Optional note<input name="action_input_note" value="Ready to go"></label>
        <div data-sc-action-lookup>
          <input type="hidden" name="action_input_reviewer" data-sc-lookup-value>
          <input type="search" data-sc-lookup-query data-sc-lookup-url="https://example.test/lookup" data-sc-lookup-input="reviewer" data-sc-lookup-minimum-length="2" aria-label="Reviewer">
          <div data-sc-lookup-results id="lookup-results" role="listbox" hidden></div>
        </div>
      </fieldset>
      <fieldset data-sc-action-variant="follow_up" disabled hidden><legend>Follow up</legend>
        <label>Reason<input name="action_input_reason" required></label>
        <label>Documents<textarea name="action_input_documents"></textarea></label>
      </fieldset>
    </div><button type="reset">Reset</button><button type="submit">Apply</button>
  </form>`;
}
async function load(page, metadata) {
  await page.setContent(markup(metadata));
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event('htmx:after:swap')));
}
async function data(page) {
  return page.locator('form').evaluate(form => [...new FormData(form).entries()]);
}

test('boolean variants switch required fields and overrides without losing drafts', async ({page}) => {
  await load(page);
  await expect(page.locator('[data-sc-action-variant="follow_up"]')).toBeVisible();
  await expect(page.locator('[data-sc-action-variant="ready"]')).toBeHidden();
  await page.getByLabel('Base note').fill('Base draft');
  await page.getByLabel('Reason', {exact: true}).fill('Missing invoice');
  await page.getByLabel('Documents', {exact: true}).fill('[{"name":"Invoice"}]');
  await page.getByLabel('Complete', {exact: true}).selectOption('true');
  await expect(page.getByLabel('Base note')).toBeHidden();
  await expect(page.getByLabel('Base note')).toBeDisabled();
  await expect(page.getByLabel('Reason', {exact: true})).toBeDisabled();
  expect(await data(page)).toEqual([
    ['action_input_complete', 'true'], ['action_input_note', 'Ready to go'], ['action_input_reviewer', ''],
  ]);
  expect(await page.locator('form').evaluate(form => form.checkValidity())).toBe(true);
  await page.getByLabel('Optional note').fill('Ready draft');
  await page.getByLabel('Complete', {exact: true}).selectOption('false');
  await expect(page.getByLabel('Base note')).toHaveValue('Base draft');
  await expect(page.getByLabel('Reason', {exact: true})).toHaveValue('Missing invoice');
  await expect(page.getByLabel('Documents', {exact: true})).toHaveValue('[{"name":"Invoice"}]');
  await page.getByLabel('Complete', {exact: true}).selectOption('true');
  await expect(page.getByLabel('Optional note')).toHaveValue('Ready draft');
  await page.getByRole('button', {name: 'Reset', exact: true}).click();
  await expect(page.locator('[data-sc-action-variant="follow_up"]')).toBeVisible();
  await expect(page.getByLabel('Base note')).toBeEnabled();
});

test('no match and ambiguous variants block submission and explain the choices', async ({page}) => {
  await load(page);
  await page.getByLabel('Complete', {exact: true}).selectOption('');
  await expect(page.locator('[data-sc-action-variant-status]')).toContainText('Choose values');
  expect(await page.locator('form').evaluate(form => form.checkValidity())).toBe(false);
  const ambiguous = structuredClone(spec);
  ambiguous.variants[0].when = {complete: false};
  await page.locator('[data-sc-action-variants]').evaluate((root, value) => {
    root.dataset.scActionVariants = JSON.stringify(value);
  }, ambiguous);
  await page.getByLabel('Complete', {exact: true}).selectOption('false');
  await expect(page.locator('[data-sc-action-variant-status]')).toContainText('more than one');
  await expect(page.locator('[data-sc-action-variant="follow_up"]')).toHaveAttribute('disabled', '');
  await expect(page.getByLabel('Reason', {exact: true})).toBeDisabled();
  expect(await page.locator('form').evaluate(form => form.checkValidity())).toBe(false);
});

test('dynamic fragments initialize independently and preserve outer disabled controls', async ({page}) => {
  await load(page);
  await page.evaluate(html => {
    const container = document.createElement('div');
    container.id = 'inserted';
    container.innerHTML = html;
    document.body.append(container);
    document.dispatchEvent(new Event('htmx:after:swap'));
  }, markup());
  const inserted = page.locator('#inserted');
  await inserted.getByLabel('Complete', {exact: true}).selectOption('true');
  await expect(inserted.locator('[data-sc-action-variant="ready"]')).toBeVisible();
  await expect(page.locator('body > form [data-sc-action-variant="follow_up"]')).toBeVisible();
  await inserted.locator('form').evaluate(form => {
    const guard = document.createElement('fieldset');
    guard.disabled = true;
    form.before(guard);
    guard.append(form);
    document.dispatchEvent(new Event('htmx:after:swap'));
  });
  await expect(inserted.getByLabel('Optional note')).toBeDisabled();
});

test('lookups include selector values and cancel stale requests when the variant changes', async ({page}) => {
  await load(page);
  await page.evaluate(() => {
    window.lookups = [];
    window.fetch = (url, options) => {
      window.lookups.push({url, signal: options.signal});
      return new Promise(() => {});
    };
  });
  await page.getByLabel('Complete', {exact: true}).selectOption('true');
  await page.getByLabel('Reviewer', {exact: true}).fill('Review');
  await expect.poll(() => page.evaluate(() => window.lookups.length)).toBe(1);
  expect(await page.evaluate(() => new URL(window.lookups[0].url).searchParams.get('action_input_complete'))).toBe('true');
  await page.getByLabel('Complete', {exact: true}).selectOption('false');
  expect(await page.evaluate(() => window.lookups[0].signal.aborted)).toBe(true);
});

test('operation select switches hold and release forms without submitting inactive fields', async ({page}) => {
  const metadata = {
    inputs: [{id: 'operation', type: 'select'}],
    variants: [
      {id: 'hold', label: 'Place on hold', when: {operation: 'hold'}, fields: ['code', 'reason']},
      {id: 'release', label: 'Release hold', when: {operation: 'release'}, fields: ['comment']},
    ],
  };
  await page.setContent(`<form data-sc-action-form>
    <div data-sc-action-variants='${JSON.stringify(metadata)}'>
      <div data-sc-action-base><label data-sc-action-input-id="operation">Operation
        <select name="action_input_operation" aria-label="Operation" required><option value="">Choose</option>
          <option value="hold">Place on hold</option><option value="release">Release hold</option>
        </select></label></div>
      <p data-sc-action-variant-status role="status"></p>
      <fieldset data-sc-action-variant="hold" hidden disabled>
        <label>Code<select name="action_input_code" aria-label="Code" required><option value="">Choose</option>
          <option value="DOC">Missing documents</option></select></label>
        <label>Reason<textarea name="action_input_reason" required></textarea></label>
      </fieldset>
      <fieldset data-sc-action-variant="release" hidden disabled>
        <label>Comment<textarea name="action_input_comment"></textarea></label>
      </fieldset>
    </div><button type="submit">Apply</button></form>`);
  await page.addScriptTag({path: bundle});
  await page.evaluate(() => document.dispatchEvent(new Event('htmx:after:swap')));
  expect(await page.locator('form').evaluate(form => form.checkValidity())).toBe(false);
  await page.getByLabel('Operation', {exact: true}).selectOption('hold');
  await expect(page.getByLabel('Code', {exact: true})).toBeVisible();
  await expect(page.getByLabel('Comment', {exact: true})).toBeHidden();
  await page.getByLabel('Code', {exact: true}).selectOption('DOC');
  await page.getByLabel('Reason', {exact: true}).fill('Waiting for signature');
  await page.getByLabel('Operation', {exact: true}).selectOption('release');
  await expect(page.getByLabel('Code', {exact: true})).toBeHidden();
  await expect(page.getByLabel('Code', {exact: true})).toBeDisabled();
  await expect(page.getByLabel('Comment', {exact: true})).toBeVisible();
  expect(await page.locator('form').evaluate(form => form.checkValidity())).toBe(true);
  expect(await data(page)).toEqual([['action_input_operation', 'release'], ['action_input_comment', '']]);
  await page.getByLabel('Operation', {exact: true}).selectOption('hold');
  await expect(page.getByLabel('Reason', {exact: true})).toHaveValue('Waiting for signature');
  await expect(page.getByLabel('Code', {exact: true})).toHaveValue('DOC');
});

async function targetDialog(page) {
  await page.setContent(`<div class="sc-results">
    <button data-sc-action-open="target-dialog" data-sc-action-id="hold" data-sc-row-action-target="101">Row 101</button>
    <button data-sc-action-open="target-dialog" data-sc-action-id="hold" data-sc-row-action-target="102">Row 102</button>
    <div data-sc-bulk-action data-sc-action-id="hold" data-sc-action-mode="row-dialog" data-sc-action-submit-label="Apply">
      <dialog id="target-dialog" data-sc-action-dialog><form data-sc-action-form
        data-sc-action-form-url="https://example.test/explorer/actions/hold/form" data-sc-action-form-ready="0">
        <div data-sc-action-targets></div><div data-sc-action-fields></div>
        <div data-sc-action-result role="status" hidden></div>
        <footer><button type="button" data-sc-action-close>Cancel</button><button type="submit">Apply</button></footer>
      </form></dialog>
    </div></div>`);
  await page.evaluate(() => {
    window.pendingForms = [];
    window.fetch = (url, options) => new Promise(resolve => {
      window.pendingForms.push({url: String(url), options, resolve});
    });
  });
  await page.addScriptTag({path: bundle});
}
function fixedForm(operation) {
  const metadata = {
    inputs: [{id: 'operation', type: 'select'}], variants: [
      {id: 'hold', label: 'Place on hold', when: {operation: 'hold'}, fields: ['reason']},
      {id: 'release', label: 'Release hold', when: {operation: 'release'}, fields: ['comment']},
    ],
  };
  return `<div data-sc-action-variants='${JSON.stringify(metadata)}'>
    <div data-sc-action-base><div data-sc-action-input-id="operation">Operation
      <strong>${operation === 'hold' ? 'Place on hold' : 'Release hold'}</strong>
      <input type="hidden" name="action_input_operation" value="${operation}"></div></div>
    <p data-sc-action-variant-status role="status"></p>
    <fieldset data-sc-action-variant="hold" hidden disabled><label>Reason<textarea name="action_input_reason" required></textarea></label></fieldset>
    <fieldset data-sc-action-variant="release" hidden disabled><label>Comment<textarea name="action_input_comment"></textarea></label></fieldset>
  </div>`;
}
async function reply(page, index, body, ok = true) {
  await page.evaluate(({index, body, ok}) => {
    window.pendingForms[index].resolve({ok, json: async () => body});
  }, {index, body, ok});
}

test('row dialog fetches the authorized fixed operation before allowing submission', async ({page}) => {
  await targetDialog(page);
  await page.getByRole('button', {name: 'Row 101', exact: true}).click();
  await expect(page.getByRole('button', {name: 'Apply', exact: true})).toBeDisabled();
  await expect.poll(() => page.evaluate(() => window.pendingForms.length)).toBe(1);
  expect(await page.evaluate(() => new URL(window.pendingForms[0].url).searchParams.get('selected_id'))).toBe('101');
  await page.locator('form').evaluate(form => form.dispatchEvent(new Event('submit', {bubbles: true, cancelable: true})));
  expect(await page.evaluate(() => window.pendingForms.length)).toBe(1);
  await reply(page, 0, {ok: true, html: fixedForm('hold')});
  await expect(page.getByLabel('Reason', {exact: true})).toBeVisible();
  await expect(page.getByLabel('Comment', {exact: true})).toBeHidden();
  await expect(page.locator('select[name="action_input_operation"]')).toHaveCount(0);
  await expect(page.getByRole('button', {name: 'Apply', exact: true})).toBeEnabled();
  await page.getByRole('button', {name: 'Cancel', exact: true}).click();
  await page.getByRole('button', {name: 'Row 102', exact: true}).click();
  await reply(page, 1, {ok: true, html: fixedForm('release')});
  await expect(page.getByLabel('Comment', {exact: true})).toBeVisible();
  await expect(page.getByLabel('Reason', {exact: true})).toBeHidden();
  expect(await data(page)).toEqual([['selected_id', '102'], ['action_input_operation', 'release'], ['action_input_comment', '']]);
});

test('failed and superseded row form requests cannot enable the wrong operation', async ({page}) => {
  await targetDialog(page);
  await page.getByRole('button', {name: 'Row 101', exact: true}).click();
  await reply(page, 0, {ok: false, message: 'That order is not available.'}, false);
  await expect(page.locator('[data-sc-action-result]')).toHaveText('That order is not available.');
  await expect(page.getByRole('button', {name: 'Apply', exact: true})).toBeDisabled();
  await page.getByRole('button', {name: 'Cancel', exact: true}).click();
  await page.getByRole('button', {name: 'Row 101', exact: true}).click();
  await page.getByRole('button', {name: 'Cancel', exact: true}).click();
  await page.getByRole('button', {name: 'Row 102', exact: true}).click();
  await reply(page, 2, {ok: true, html: fixedForm('release')});
  await expect(page.getByLabel('Comment', {exact: true})).toBeVisible();
  await reply(page, 1, {ok: true, html: fixedForm('hold')});
  await expect(page.locator('[name="action_input_operation"]')).toHaveValue('release');
  await expect(page.getByLabel('Reason', {exact: true})).toBeHidden();
});
