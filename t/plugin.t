use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL ();
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::DateShortcut ();

my $t = Test::Mojo->new(TestSelectoComponents::app());

$t->get_ok('/explore/products')
    ->status_is(200)
    ->content_type_like(qr{text/html})
    ->element_exists('section#selecto-channel-products')
    ->element_exists('[data-sc-workspace]:not(.is-builder-collapsed)')
    ->element_exists('[data-sc-builder-shell="products"]:not(.is-collapsed)')
    ->element_exists('[data-sc-builder-toggle][aria-expanded="true"][aria-label="Collapse view menu"]')
    ->text_is('.sc-builder-tray-header > span' => 'View menu')
    ->element_exists('form#selecto-query-products')
    ->element_exists('form#selecto-query-products input[name="query_signature"][value]')
    ->element_exists('[role="tablist"][aria-label="Explorer sections"]')
    ->element_exists('[role="tab"][data-sc-builder-tab="view"][aria-selected="true"]')
    ->element_exists('[role="tab"][data-sc-builder-tab="filters"][aria-selected="false"]')
    ->element_exists('[role="tab"][data-sc-builder-tab="saved"][aria-selected="false"]')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="view"] [data-sc-query-library-view-controls] select[name="query_library_view"]')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="view"] .sc-view-tabs')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="filters"][hidden] [data-sc-query-library-filter-controls] input[name="query_library_segment"][value="low_stock"]')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="filters"][hidden] [data-sc-filter-root]')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="saved"][hidden][data-sc-saved-queries]')
    ->element_exists_not('[role="tab"][data-sc-builder-tab="library"]')
    ->element_exists_not('[role="tabpanel"][data-sc-builder-panel="library"]')
    ->content_like(qr/Capability metadata: products\.read/)
    ->element_exists('form[hx-trigger="submit"]')
    ->element_exists('[data-sc-result-view-panel="detail"]:not([disabled])')
    ->element_exists('[data-sc-result-view-panel="summary"][hidden][disabled]')
    ->element_exists('[data-sc-graph-options][hidden][disabled] select[name="chart_type"]')
    ->element_exists('[data-sc-builder-pending][hidden]')
    ->element_exists('[data-sc-picker-root]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="field"]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="group"]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="measure"]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-sc-picker-available] button[data-field="unit_price"][data-default-function="count"]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-sc-picker-available] button[data-field="category.category_name"]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="order"]')
    ->element_exists('[data-sc-picker-available] button[data-field="category_id"]')
    ->element_exists('[data-sc-picker-set-item][data-field="category.category_name"] input[name="field"]')
    ->element_exists('[data-sc-picker-set-item][draggable="true"]')
    ->element_exists('button[data-sc-picker-action="up"]')
    ->element_exists('button[data-sc-picker-action="down"]')
    ->element_exists('[data-sc-picker-kind="field"] .sc-column-config')
    ->element_exists('[data-sc-picker-kind="order"] [name="direction"]')
    ->element_exists('[data-sc-filter-root]')
    ->element_exists('input[data-sc-filter-search][aria-label="Filter available filters"]')
    ->element_exists('[data-sc-filter-available] button[data-field="unit_price"]')
    ->element_exists('[data-sc-filter-set][aria-label="Set filters"]')
    ->element_exists('input[type="hidden"][name="group"][value="category.category_name"]')
    ->text_is('.sc-picker-heading span' => 'Available')
    ->content_like(qr{<legend>Filters <small>up to 20</small></legend>})
    ->text_is('h1' => 'Product Explorer')
    ->element_exists('[data-sc-export-format="xlsx"][href*="format=xlsx"]')
    ->element_exists('[data-sc-export-format="csv"][href*="format=csv"]')
    ->element_exists('[data-sc-export-format="tsv"][href*="format=tsv"]')
    ->element_exists('[data-sc-export-format="json"][href*="format=json"]')
    ->text_is('.sc-export-options > span' => 'Export all')
    ->attr_is('.sc-export-options' => 'aria-label' => 'Export all matched rows')
    ->content_like(qr{>Excel</a>.*>CSV</a>.*>TSV</a>.*>JSON</a>}s)
    ->content_like(qr{hx-ws:connect="/explore/products/ws"})
    ->content_like(qr{hx-ws:send})
    ->content_like(qr{/selecto-components/htmx\.min\.js})
    ->content_like(qr{/selecto-components/hx-ws\.min\.js})
    ->content_like(qr{/selecto-components/chart\.umd\.min\.js\?v=20260821-9})
    ->content_like(qr{/selecto-components/selecto-components\.css\?v=20260821-9})
    ->content_like(qr{/selecto-components/selecto-components\.js\?v=20260821-9})
    ->element_exists_not('.sc-result-meta .sc-eyebrow')
    ->content_like(qr{<strong>42</strong> rows matched \x{b7} <strong>2</strong> pages \x{b7} <strong>\d+ ms</strong> query time})
    ->text_is('.sc-pagination > span' => 'Page 1 of 2')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available] button[data-field="action:add_product_note"][data-type="action"]')
    ->text_is('[data-sc-picker-kind="field"] button[data-field="action:add_product_note"] strong' => 'Action: Add Product Note')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available] button[data-field="action:build_shipments"][data-type="action"]')
    ->text_is('[data-sc-picker-kind="field"] button[data-field="action:build_shipments"] strong' => 'Action: Build Shipments')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available] button[data-field="action:mark_for_review"][data-type="action"]')
    ->element_exists_not('[data-sc-bulk-actions]')
    ->element_exists_not('input[data-sc-row-select]')
    ->element_exists_not('dialog[data-sc-action-dialog]')
    ->element_exists('a.sc-object-link[href="/products/view?id=101"]')
    ->text_is('a.sc-object-link[href="/products/view?id=101"]' => '=2+2')
    ->element_exists('details.sc-debug-panel[data-sc-debug-panel][open]')
    ->text_is('.sc-debug-panel > summary strong' => 'Query Debug')
    ->text_is('.sc-debug-stat:nth-child(5) span' => 'Rows returned')
    ->text_is('.sc-debug-stat:nth-child(5) strong' => '2')
    ->text_is('.sc-debug-stat:nth-child(6) strong' => '42')
    ->text_is('.sc-debug-query:nth-of-type(1) h4' => 'Generated data query')
    ->element_exists('.sc-debug-query button[data-sc-debug-copy="selecto-debug-data-products"]')
    ->element_exists('.sc-debug-query:nth-of-type(1) code.sc-sql .sc-sql-keyword')
    ->text_is('.sc-debug-query:nth-of-type(1) .sc-debug-no-params' => 'No bound parameters.');

is $t->tx->res->dom
    ->at('[data-sc-saved-queries] .sc-saved-query-list li:nth-child(1) a')->all_text,
    'alpha inventory', 'saved queries are sorted case-insensitively';
is $t->tx->res->dom
    ->at('[data-sc-saved-queries] .sc-saved-query-list li:nth-child(2) a')->all_text,
    'Zulu inventory', 'second saved query follows in alphabetical order';
ok !$t->tx->res->dom->at('[data-sc-saved-queries] a[href^="/explore/elsewhere"]'),
    'saved query list rejects URLs for another explorer';
my $saved_query_form = $t->tx->res->dom->at(
    'form[action="/explore/products/saved-queries"]',
);
ok $saved_query_form, 'saved query form is rendered outside the query builder form';
ok !$t->tx->res->dom->at(
    'form#selecto-query-products form[action="/explore/products/saved-queries"]',
), 'saved query tab does not create nested forms';
is $saved_query_form->at('input[name="saved_query_name"]')->attr('maxlength'), 30,
    'saved query names honor the legacy table limit';
my $saved_csrf_token = $saved_query_form->at('input[name="csrf_token"]')->attr('value');
my $saved_url = Mojo::URL->new(
    $saved_query_form->at('input[name="saved_query_url"]')->attr('value'),
);
$saved_url->query->param(page => 4);
$t->post_ok('/explore/products/saved-queries' => {Accept => 'application/json'} => form => {
    csrf_token => $saved_csrf_token,
    saved_query_name => '  My inventory  ',
    saved_query_url => $saved_url->to_string,
    return_to => '/explore/products',
})->status_is(200)->json_is('/ok' => 1)->json_is('/name' => 'My inventory')
    ->json_like('/url' => qr{\bpage=1\z});
is_deeply $TestSelectoComponents::SAVED_QUERY_REQUESTS[-1], {
    operation => 'save',
    name => 'My inventory',
    url => $t->tx->res->json->{url},
}, 'saved query store receives a canonical page-one URL';

$t->post_ok('/explore/products/saved-queries' => {Accept => 'application/json'} => form => {
    saved_query_name => 'No token',
    saved_query_url => '/explore/products?q=1',
})->status_is(403)->json_is('/ok' => 0);
$t->post_ok('/explore/products/saved-queries' => {Accept => 'application/json'} => form => {
    csrf_token => $saved_csrf_token,
    saved_query_name => 'x' x 31,
    saved_query_url => '/explore/products?q=1',
})->status_is(422)->json_like('/message' => qr/30 characters/);

$t->post_ok('/explore/products/saved-queries/delete' => {Accept => 'application/json'} => form => {
    csrf_token => $saved_csrf_token,
    saved_query_name => 'My inventory',
    return_to => '/explore/products?q=1',
})->status_is(200)->json_is('/ok' => 1)->json_is('/name' => 'My inventory');
is_deeply $TestSelectoComponents::SAVED_QUERY_REQUESTS[-1], {
    operation => 'delete', name => 'My inventory',
}, 'saved query delete is delegated by name';

$t->get_ok('/explore/private-products')->status_is(200)
    ->element_exists_not('[data-sc-saved-queries]')
    ->element_exists_not('form[action="/explore/private-products/saved-queries"]');

my $library_url = '/explore/products?q=1&query_library_view=low_stock_products' .
    '&query_library_segment=low_stock' .
    '&query_library_param_name=threshold&query_library_param_value=8' .
    '&filter_field=unit_price&filter_op=gte&filter_value=10' .
    '&view=detail&limit=25&page=1';
$t->get_ok($library_url)
    ->status_is(200)
    ->element_exists('[data-sc-workspace].is-builder-collapsed')
    ->element_exists('[data-sc-builder-shell="products"].is-collapsed')
    ->element_exists('[data-sc-builder-toggle][aria-expanded="false"][aria-label="Expand view menu"]')
    ->element_exists('[data-sc-query-library-view-controls] option[value="low_stock_products"][selected]')
    ->attr_is('[data-sc-query-library-view-controls] option[value="low_stock_products"]' =>
        'data-sc-view-segments' => '["low_stock"]')
    ->element_exists('[data-sc-query-library-filter-controls] input[name="query_library_param_name"][value="threshold"]')
    ->element_exists('[data-sc-query-library-filter-controls] input[name="query_library_param_value"][value="8"][type="number"]')
    ->text_is('[data-sc-query-summary] [data-sc-query-library-segment-summary="low_stock"]' => 'Segment: Low stock')
    ->text_is('[data-sc-query-summary] [data-sc-filter-summary]' => 'Unit Price >= 10')
    ->text_is('[data-sc-query-summary] .sc-query-summary-heading > span' => '2 applied filters')
    ->text_is('[data-sc-builder-tab="filters"] [data-sc-filter-badge]' => '2');

my $action_columns_url = '/explore/products?q=1&view=detail' .
    '&field=action%3Aadd_product_note&field_alias=&field_format=' .
    '&field=product_name&field_alias=&field_format=' .
    '&field=action%3Amark_for_review&field_alias=&field_format=' .
    '&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=1';
$t->get_ok($action_columns_url)
    ->status_is(200)
    ->element_exists('[data-sc-bulk-actions]')
    ->text_is('[data-sc-bulk-action][data-sc-action-id="add_product_note"] [data-sc-selection-count]' => '0')
    ->text_is('[data-sc-bulk-action][data-sc-action-id="mark_for_review"] [data-sc-selection-count]' => '0')
    ->element_exists('[data-sc-action-open="selecto-action-products-add_product_note"][disabled]')
    ->element_exists('[data-sc-action-open="selecto-action-products-mark_for_review"][disabled]')
    ->element_exists('th[data-sc-action-column="add_product_note"] input[data-sc-select-page][data-sc-action-id="add_product_note"]')
    ->element_exists('th[data-sc-action-column="mark_for_review"] input[data-sc-select-page][data-sc-action-id="mark_for_review"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="add_product_note"][value="101"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="add_product_note"][value="102"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="mark_for_review"][value="101"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="mark_for_review"][value="102"]')
    ->element_exists('dialog#selecto-action-products-add_product_note')
    ->element_exists('dialog#selecto-action-products-mark_for_review')
    ->element_exists('form[action="/explore/products/actions/add_product_note"]')
    ->element_exists('form[action="/explore/products/actions/mark_for_review"]')
    ->element_exists('select[name="action_input_note_type"] option[value="internal"]')
    ->element_exists('textarea[name="action_input_comment"][maxlength="255"]')
    ->element_exists('textarea[name="action_input_reason"][maxlength="120"]')
    ->content_like(qr{Action: Add Product Note.*Product Name.*Action: Mark for Review}s)
    ->content_unlike(qr{<th[^>]*>__selecto_action_target</th>});

my $csrf_token = $t->tx->res->dom
    ->at('form[action="/explore/products/actions/add_product_note"] input[name="csrf_token"]')
    ->attr('value');

$t->post_ok('/explore/products/actions/add_product_note' => {Accept => 'application/json'} => form => {
    csrf_token => $csrf_token,
    action_input_note_type => 'internal',
    action_input_comment => 'Check packaging',
})->status_is(422)->json_is('/ok' => 0)
    ->json_like('/message' => qr/Select at least one row/);

$t->post_ok('/explore/products/actions/add_product_note' => {Accept => 'application/json'} => form => {
    csrf_token => $csrf_token,
    selected_id => [101, 102],
    action_input_note_type => 'not-allowed',
    action_input_comment => 'Check packaging',
})->status_is(422)->json_is('/ok' => 0)
    ->json_like('/message' => qr/not an available choice/);

$t->post_ok('/explore/products/actions/add_product_note' => {Accept => 'application/json'} => form => {
    csrf_token => $csrf_token,
    selected_id => [101, 102, 101],
    action_input_note_type => 'internal',
    action_input_comment => '  Check packaging  ',
})->status_is(200)->json_is('/ok' => 1)
    ->json_is('/applied_count' => 2)
    ->json_is('/message' => 'Product note added.');
is_deeply $TestSelectoComponents::ACTION_REQUESTS[-1]{selected_ids}, ['101', '102'],
    'action request deduplicates selected row ids';
is $TestSelectoComponents::ACTION_REQUESTS[-1]{inputs}{comment}, 'Check packaging',
    'action request trims normalized text inputs';

$t->post_ok('/explore/products/actions/mark_for_review' => {Accept => 'application/json'} => form => {
    csrf_token => $csrf_token,
    selected_id => [202],
    action_input_reason => 'Verify dimensions',
})->status_is(200)->json_is('/ok' => 1)
    ->json_is('/applied_count' => 1)
    ->json_is('/message' => 'Products marked for review.');
is $TestSelectoComponents::ACTION_REQUESTS[-1]{action}{id}, 'mark_for_review',
    'each selected action column dispatches to its own action handler';
is_deeply $TestSelectoComponents::ACTION_REQUESTS[-1]{selected_ids}, ['202'],
    'the second action receives its own selected rows';

my $grouped_action_url = '/explore/products?q=1&view=detail' .
    '&field=action%3Abuild_shipments&field_alias=&field_format=' .
    '&field=product_name&field_alias=&field_format=' .
    '&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=1';
$t->get_ok($grouped_action_url)
    ->status_is(200)
    ->element_exists('[data-sc-bulk-action][data-sc-action-id="build_shipments"][data-sc-action-mode="groups"]')
    ->element_exists('th.sc-group-select-column[data-sc-action-column="build_shipments"]')
    ->element_exists_not('th[data-sc-action-column="build_shipments"] input[data-sc-select-page]')
    ->element_exists('[data-sc-group-markers][data-sc-action-id="build_shipments"][data-sc-row-id="101"]')
    ->element_exists('[data-sc-group-markers][data-sc-action-id="build_shipments"][data-sc-row-id="102"]')
    ->attr_like('[data-sc-group-markers][data-sc-action-id="build_shipments"][data-sc-row-id="101"]' =>
        'data-sc-row-details' => qr/Stock.*21/)
    ->element_exists('input[name="action_groups"][data-sc-action-groups]')
    ->element_exists('[data-sc-group-action-groups]')
    ->content_like(qr{pink_heart})
    ->content_like(qr{orange_star})
    ->content_like(qr{yellow_moon})
    ->content_like(qr{green_clover})
    ->content_like(qr{blue_diamond})
    ->content_like(qr{purple_horseshoe})
    ->content_like(qr{carrier_id});

my $grouped_csrf = $t->tx->res->dom
    ->at('form[action="/explore/products/actions/build_shipments"] input[name="csrf_token"]')
    ->attr('value');
my $group_payload = encode_json([
    {
        index => 0,
        marker => {id => 'forged', color => '#000000'},
        selected_ids => [101, 102],
        inputs => {carrier_id => 501},
    },
    {index => 1, selected_ids => [103], inputs => {carrier_id => 777}},
]);
$t->post_ok('/explore/products/actions/build_shipments' => {Accept => 'application/json'} => form => {
    csrf_token => $grouped_csrf,
    selected_id => [101, 102, 103],
    action_groups => $group_payload,
})->status_is(200)->json_is('/ok' => 1)->json_is('/built_count' => 2);
is_deeply [map { $_->{marker}{id} } @{$TestSelectoComponents::ACTION_REQUESTS[-1]{groups}}],
    [qw(pink_heart orange_star)],
    'grouped action markers are reconstructed from the governed palette';
is_deeply $TestSelectoComponents::ACTION_REQUESTS[-1]{groups}[0]{selected_ids},
    ['101', '102'], 'grouped actions preserve each marker row assignment';
is $TestSelectoComponents::ACTION_REQUESTS[-1]{groups}[1]{inputs}{carrier_id}, '777',
    'grouped actions normalize the per-group carrier input';

$t->post_ok('/explore/products/actions/build_shipments' => {Accept => 'application/json'} => form => {
    csrf_token => $grouped_csrf,
    selected_id => [101],
    action_groups => encode_json([
        {index => 0, selected_ids => [101], inputs => {carrier_id => 0}},
    ]),
})->status_is(422)->json_is('/ok' => 0)
    ->json_like('/message' => qr/Pink heart: Carrier ID is below its minimum/);

$t->post_ok('/explore/products/actions/build_shipments' => {Accept => 'application/json'} => form => {
    csrf_token => $grouped_csrf,
    selected_id => [101],
    action_groups => encode_json([
        {index => 99, selected_ids => [101], inputs => {carrier_id => 501}},
    ]),
})->status_is(422)->json_is('/ok' => 0)
    ->json_like('/message' => qr/group marker is invalid/);

$t->post_ok('/explore/products/actions/add_product_note' => {Accept => 'application/json'} => form => {
    selected_id => 101,
    action_input_note_type => 'internal',
    action_input_comment => 'No token',
})->status_is(403)->json_is('/ok' => 0);

$t->get_ok('/selecto-components/selecto-components.js')->status_is(200)
    ->content_like(qr/htmx:after:ws:message/)
    ->content_like(qr/data-sc-picker-set-item/)
    ->content_like(qr/data-sc-filter-available-item/)
    ->content_like(qr/data-sc-filter-set-item/)
    ->content_like(qr/activeBuilderTabs/)
    ->content_like(qr/data-sc-builder-shell/)
    ->content_like(qr/name === "saved"/)
    ->content_like(qr/function setBuilderTrayCollapsed/)
    ->content_like(qr/function restoreBuilderTrays/)
    ->content_like(qr/closest\("\[data-sc-workspace\]"\)/)
    ->content_like(qr/data-sc-builder-panel/)
    ->content_like(qr/htmx:after:swap/)
    ->content_like(qr/markBuilderDirty/)
    ->content_like(qr/stageResultView/)
    ->content_like(qr/hiddenFilterValue\("filter_group", "0"\)/)
    ->content_like(qr/dateFormats/)
    ->content_like(qr/dateShortcuts/)
    ->content_like(qr/rebuildFilterValues/)
    ->content_like(qr/scPickerKind/)
    ->content_like(qr/window\.addEventListener\("submit"/)
    ->content_like(qr/data-sc-row-select/)
    ->content_like(qr/function actionControls/)
    ->content_like(qr/function initializeChart/)
    ->content_like(qr/function copyDebugSql/)
    ->content_like(qr/data-sc-debug-copy/)
    ->content_like(qr/data-sc-graph-drilldown/)
    ->content_like(qr/populateActionTargets/)
    ->content_like(qr/function renderGroupedActionRows/)
    ->content_like(qr/function reorderGroupedActionRows/)
    ->content_like(qr/function groupedRowDetails/)
    ->content_like(qr/prefers-reduced-motion: reduce/)
    ->content_like(qr/cubic-bezier\(\.2,\.8,\.2,1\)/)
    ->content_like(qr/function renderGroupedActionDialog/)
    ->content_like(qr/function serializeGroupedAction/)
    ->content_like(qr/function markerSvgPart/)
    ->content_like(qr/createElementNS\("http:\/\/www\.w3\.org\/2000\/svg"/)
    ->content_like(qr/window\.fetch/)
    ->content_like(qr/HTMLFormElement\.prototype\.submit\.call\(form\)/)
    ->content_like(qr/requestSubmit/);
$t->get_ok('/selecto-components/chart.umd.min.js')->status_is(200)
    ->content_type_like(qr{javascript})
    ->content_like(qr/Chart\.js v4\.5\.1/);
$t->get_ok('/selecto-components/selecto-components.css')->status_is(200)
    ->content_like(qr/\.sc-workspace/)
    ->content_like(qr/\.sc-list-picker/)
    ->content_like(qr/\.sc-picker-choice\[hidden\]\s*\{\s*display:\s*none/)
    ->content_like(qr/\.sc-filter-values/)
    ->content_like(qr/\.sc-bulk-actions/)
    ->content_like(qr/\.sc-chart-canvas/)
    ->content_like(qr/\.sc-bulk-action/)
    ->content_like(qr/\.sc-action-dialog/)
    ->content_like(qr/\.sc-group-marker/)
    ->content_like(qr/\.sc-group-action-card/)
    ->content_like(qr/\.sc-group-action-orders/)
    ->content_like(qr/width:\s*max-content/)
    ->content_unlike(qr/\.sc-nested-table th[^}]*text-overflow/s)
    ->content_like(qr/\.sc-table-wrap\s*>\s*table\s*>\s*thead\s*>\s*tr\s*>\s*th:first-child/)
    ->content_like(qr/\.sc-table-wrap\s*>\s*table\s*>\s*tbody\s*>\s*tr\s*>\s*td:first-child/)
    ->content_like(qr/\.sc-results\s*\{[^}]*overflow:\s*visible/s)
    ->content_like(qr/\.sc-table-wrap\s*\{[^}]*overflow:\s*visible/s)
    ->content_like(qr/\.sc-table-wrap\s*>\s*table\s*\{[^}]*width:\s*max-content/s)
    ->content_like(qr/\.sc-sql-keyword/)
    ->content_like(qr/\.sc-sql-parameter/)
    ->content_unlike(qr/\.sc-group-marker-glyph[^}]*font-family/s)
    ->content_like(qr/\.sc-workspace\.is-builder-collapsed/)
    ->content_like(qr/\.sc-builder\.is-collapsed/)
    ->content_like(qr/margin-left:\s*calc\(50%\s*-\s*50vw\)/)
    ->content_like(qr/border-left:\s*0/)
    ->content_like(qr/\.sc-builder\s*\{[^}]*padding:\s*8px\s+16px\s+16px\s+8px/)
    ->content_like(qr/\.sc-builder-toggle\s*\{[^}]*order:\s*-1/)
    ->content_like(qr/\.sc-builder-tray-header\s*\{[^}]*justify-content:\s*flex-start/)
    ->content_like(qr/cubic-bezier\(\.22,\s*1,\s*\.36,\s*1\)/)
    ->content_like(qr/\@property\s+--sc-tray-width/)
    ->content_unlike(qr/max-height:\s*calc\(100vh/);

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=unit_price&group=category.category_name&measure=count&order=unit_price&direction=desc&limit=10&page=1&filter_field=unit_price&filter_op=gte&filter_value=12.50')
    ->status_is(200)
    ->element_exists('.sc-debug-query:nth-of-type(1) code.sc-sql .sc-sql-keyword')
    ->content_like(qr/12\.50/)
    ->content_like(qr{<strong>42</strong> rows matched \x{b7} <strong>5</strong> pages \x{b7} <strong>\d+ ms</strong> query time})
    ->text_is('.sc-pagination > span' => 'Page 1 of 5')
    ->element_exists('table tbody tr');
is_deeply $TestSelectoComponents::Adapter::LAST_QUERY->limit_value, 10, 'GET runs the normalized query';
is_deeply $TestSelectoComponents::Adapter::LAST_COUNT_STATEMENT->params, ['12.50'],
    'total count uses the same bound filters as the result query';
is $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->limit_value, undef,
    'total count removes the page limit';
is $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->offset_value, undef,
    'total count removes the page offset';

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=unit_price&group=category.category_name&measure=count&order=unit_price&direction=desc&limit=10&page=1&filter_field=unit_price&filter_op=gte&filter_value=12.50&filter_promote_field=unit_price')
    ->status_is(200)
    ->element_exists('[data-sc-promoted-filters]')
    ->element_exists('[data-sc-promoted-filter][data-field="unit_price"] select[data-sc-promoted-filter-input="op"] option[value="gte"][selected]')
    ->element_exists('[data-sc-promoted-filter][data-field="unit_price"] input[data-sc-promoted-filter-input="value"][value="12.50"]')
    ->element_exists('[data-sc-filter-set-item][data-field="unit_price"] input[name="filter_promote_field"][value="unit_price"][checked]')
    ->element_exists('button[form="selecto-query-products"][type="submit"]');

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=unit_price&group=category.category_name&measure=count&order=unit_price&direction=desc&limit=10&page=1&filter_field=unit_price&filter_op=between&filter_value=12.50&filter_value_end=19.50&filter_promote_field=unit_price')
    ->status_is(200)
    ->element_exists('[data-sc-promoted-filter][data-field="unit_price"] input[data-sc-promoted-filter-input="value"][value="12.50"]')
    ->element_exists('[data-sc-promoted-filter][data-field="unit_price"] input[data-sc-promoted-filter-input="value_end"][value="19.50"]');

$t->get_ok('/explore/products?q=1&view=detail&field=created_on&field_alias=Created+month&field_format=month&field=product_name&field_alias=&field_format=&group=created_on&group_alias=Month&group_format=month&measure=count&order=created_on&direction=desc&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('[data-sc-picker-kind="field"] [data-field="created_on"] input[name="field_alias"][value="Created month"]')
    ->element_exists('[data-sc-picker-kind="field"] [data-field="created_on"] select[name="field_format"] option[value="month"][selected]')
    ->element_exists('[data-sc-picker-kind="order"] [data-field="created_on"] select[name="direction"] option[value="desc"][selected]')
    ->element_exists('[data-sc-picker-kind="order"] [data-field="product_name"] select[name="direction"] option[value="asc"][selected]')
    ->element_exists('table thead th');
is_deeply $TestSelectoComponents::Adapter::LAST_QUERY->orders->[0][1], 'desc',
    'first configured sort direction reaches query intent';
is_deeply $TestSelectoComponents::Adapter::LAST_QUERY->orders->[1][1], 'asc',
    'second configured sort direction reaches query intent';

$t->get_ok('/explore/products?q=1&view=detail&field=created_on&filter_field=created_on&filter_op=eq&filter_value=2026-08-15&filter_value_end=&order=created_on')
    ->status_is(200)
    ->element_exists('[data-field="created_on"] select[name="filter_op"] option[value="eq"][selected]')
    ->element_exists('[data-field="created_on"] input[type="date"][name="filter_value"][value="2026-08-15"]')
    ->element_exists('[data-field="created_on"] input[type="hidden"][name="filter_value_end"]');

$t->get_ok('/explore/products?q=1&view=detail&field=created_on&filter_field=created_on&filter_op=between&filter_value=2026-01-01&filter_value_end=2026-03-31&order=created_on')
    ->status_is(200)
    ->element_exists('[data-field="created_on"] select[name="filter_op"] option[value="between"][selected]')
    ->element_exists('[data-field="created_on"] input[type="date"][name="filter_value"][value="2026-01-01"]')
    ->element_exists('[data-field="created_on"] input[type="date"][name="filter_value_end"][value="2026-03-31"]');
is_deeply TestSelectoComponents::Adapter::_predicate_values(
    $TestSelectoComponents::Adapter::LAST_QUERY->predicate,
), ['2026-01-01', '2026-03-31'], 'date BETWEEN submits and binds both controls';

$t->get_ok('/explore/products?q=1&view=detail&field=created_on&filter_field=created_on&filter_op=date_shortcut&filter_value=this_year&filter_value_end=&order=created_on')
    ->status_is(200)
    ->element_exists('[data-field="created_on"] select[name="filter_op"] option[value="date_shortcut"][selected]')
    ->element_exists('[data-field="created_on"] select[name="filter_value"] option[value="this_year"][selected]')
    ->text_is('[data-field="created_on"] select[name="filter_value"] option[value="this_year"]' => 'This Year');
my @this_year = Selecto::Components::DateShortcut->bounds('this_year');
is_deeply TestSelectoComponents::Adapter::_predicate_values(
    $TestSelectoComponents::Adapter::LAST_QUERY->predicate,
), \@this_year, 'This Year shortcut binds its half-open date range';

$t->get_ok('/explore/products?q=1&view=aggregate&field=created_on&field_alias=&field_format=&group=created_on&group_alias=Month&group_format=month&measure=count&order=created_on&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('[data-sc-result-view-panel="summary"]:not([disabled])')
    ->element_exists('[data-sc-picker-kind="group"] [data-field="created_on"] input[name="group_alias"][value="Month"]')
    ->element_exists('[data-sc-picker-kind="group"] [data-field="created_on"] select[name="group_format"] option[value="month"][selected]')
    ->content_like(qr/Aggregate results/);

$t->get_ok('/explore/products?q=1&view=aggregate&field=product_name&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=3&filter_field=unit_price&filter_op=gte&filter_value=12.50&filter_value_end=&filter_group=0')
    ->status_is(200)
    ->element_exists('form.sc-drilldown-form[method="get"]')
    ->element_exists('form.sc-drilldown-form input[name="view"][value="detail"]')
    ->element_exists('form.sc-drilldown-form input[name="page"][value="1"]')
    ->element_exists('form.sc-drilldown-form input[name="filter_field"][value="unit_price"]')
    ->element_exists('form.sc-drilldown-form input[name="filter_field"][value="category.category_name"]')
    ->element_exists('form.sc-drilldown-form input[name="filter_group"][value="1"]')
    ->text_is('form.sc-drilldown-form button.sc-drilldown-value' => 'Value 1')
    ->element_exists('tr.sc-rollup-total[data-rollup-level="0"]')
    ->content_like(qr{<tr class="sc-rollup-row sc-rollup-total"[^>]*>.*?sc-rollup-total-label">Total</span>}s)
    ->content_unlike(qr{<th[^>]*>Details</th>})
    ->content_unlike(qr/View details/i)
    ->content_like(qr{class="sc-drilldown-value"[^>]*>\[NULL\]</button>})
    ->element_exists('form.sc-drilldown-form input[name="filter_op"][value="is_null"]')
    ->content_like(qr{filter_field" value="unit_price".*?filter_group" value="0".*?filter_field" value="category\.category_name".*?filter_group" value="1"}s);

$t->get_ok('/explore/products?q=1&view=aggregate&field=product_name&group=category.category_name&group=units_in_stock&measure=count&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('tr.sc-rollup-subtotal[data-rollup-level="1"] form.sc-drilldown-form')
    ->element_exists('tr.sc-rollup-subtotal[data-rollup-level="1"] input[name="filter_field"][value="category.category_name"]')
    ->element_exists_not('tr.sc-rollup-subtotal[data-rollup-level="1"] input[name="filter_field"][value="units_in_stock"]')
    ->element_exists('tr.sc-rollup-detail[data-rollup-level="2"] input[name="filter_field"][value="category.category_name"]')
    ->element_exists('tr.sc-rollup-detail[data-rollup-level="2"] input[name="filter_field"][value="units_in_stock"]')
    ->element_exists('button.sc-drilldown-value[style="--sc-rollup-level:2"]')
    ->content_unlike(qr/View details/i);

$t->get_ok('/explore/products?q=1&view=aggregate&field=product_name&field_alias=&field_format=&group=unit_price&group_alias=Price+band&group_format=buckets&group_bucket_ranges=0-10%2C+11%2B&group_prefix_length=2&group_exclude_articles=1&measure=count&measure_alias=Products&measure_function=count&measure_bucket_ranges=&measure_ignore_nulls=0&measure=total_price&measure_alias=Price+counts&measure_function=buckets&measure_bucket_ranges=0-10%2C+11%2B&measure_ignore_nulls=0&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="count"] input[name="measure_alias"][value="Products"]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] select[name="measure_function"] option[value="buckets"][selected]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] input[name="measure_bucket_ranges"][value="0-10, 11+"]')
    ->element_exists('[data-sc-picker-kind="group"] [data-field="unit_price"] input[name="group_bucket_ranges"][value="0-10, 11+"]')
    ->content_like(qr/Price counts: 0-10/);

$t->get_ok('/explore/products?q=1&view=graph&chart_type=area&field=product_name&group=category.category_name&measure=count&measure_function=count&measure=total_price&measure_function=sum&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('.sc-chart[aria-label="Selected measures by selected groups"]')
    ->element_exists('[data-sc-graph-options]:not([disabled]) select[name="chart_type"] option[value="area"][selected]')
    ->element_exists('[data-sc-chart][data-chart-type="area"][data-chart-data] canvas[role="img"]')
    ->element_exists('form[data-sc-graph-drilldown="0"] input[name="view"][value="detail"]')
    ->element_exists('form[data-sc-graph-drilldown="0"] input[name="page"][value="1"]')
    ->content_like(qr/Product count/)
    ->content_like(qr/Total price/);

my $chart_data = decode_json(
    $t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data')
);
is_deeply $chart_data->{labels}, ['Value 1', 'Value 2'],
    'chart labels come from the selected group values';
is_deeply [map { $_->{label} } @{$chart_data->{datasets}}],
    ['Product count', 'Total price'], 'every selected measure becomes a chart dataset';
is_deeply $chart_data->{datasets}[0]{data}, [2, 4],
    'chart dataset carries numeric measure values';

for my $chart_type (qw(bar horizontal_bar stacked_bar line pie doughnut scatter)) {
    $t->get_ok('/explore/products?q=1&view=graph&chart_type=' . $chart_type .
        '&field=product_name&group=category.category_name&measure=count' .
        '&order=product_name&direction=asc&limit=25&page=1')
        ->status_is(200)
        ->element_exists('[data-sc-chart][data-chart-type="' . $chart_type . '"]')
        ->element_exists('select[name="chart_type"] option[value="' . $chart_type . '"][selected]');
}

$t->get_ok('/explore/products?q=1&view=detail&field=drop_table&order=drop_table&limit=25&page=1')
    ->status_is(422)
    ->content_like(qr/A selected detail column is not available|Choose at least one detail column/)
    ->content_unlike(qr/<script>alert/);

my $export_url = '/explore/products?q=1&view=detail&field=action%3Aadd_product_note' .
    '&field=product_name&field=unit_price&group=category.category_name&measure=count' .
    '&order=product_name&direction=asc&limit=10&page=2';

my $count_executions_before_export =
    $TestSelectoComponents::Adapter::COUNT_EXECUTIONS // 0;

$t->get_ok($export_url . '&format=csv')
    ->status_is(200)
    ->content_type_like(qr{text/csv})
    ->header_like('Content-Disposition' => qr/products-export\.csv/)
    ->content_like(qr/"Product Name","Unit Price"\r?\n/)
    ->content_unlike(qr/Action: Add Product Note/)
    ->content_like(qr/"'=2\+2"/);
is $TestSelectoComponents::Adapter::LAST_DATA_QUERY->limit_value, undef,
    'CSV export executes the active query without a row limit';
is $TestSelectoComponents::Adapter::LAST_DATA_QUERY->offset_value, undef,
    'CSV export ignores the requested result page';
is $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, $count_executions_before_export,
    'all-row export does not issue a redundant count query';
is scalar(split /\r?\n/, $t->tx->res->body), 43,
    'CSV export contains its header and all 42 matched rows';

$t->get_ok($export_url . '&format=tsv')
    ->status_is(200)
    ->content_type_like(qr{text/tab-separated-values})
    ->header_like('Content-Disposition' => qr/products-export\.tsv/)
    ->content_like(qr/"Product Name"\t"Unit Price"\r?\n/)
    ->content_unlike(qr/Action: Add Product Note/)
    ->content_like(qr/"'=2\+2"/);

$t->get_ok($export_url . '&format=json')
    ->status_is(200)
    ->content_type_like(qr{application/json})
    ->header_like('Content-Disposition' => qr/products-export\.json/)
    ->json_is('/scope' => 'all')
    ->json_is('/page' => 1)
    ->json_is('/total_pages' => 1)
    ->json_is('/total_count' => 42)
    ->json_is('/row_count' => 42)
    ->json_is('/columns' => ['Product Name', 'Unit Price'])
    ->json_is('/rows/0/Product Name' => '=2+2')
    ->json_is('/rows/0/Unit Price' => 10);

$t->get_ok($export_url . '&format=xlsx')
    ->status_is(200)
    ->content_type_like(qr{application/vnd\.openxmlformats-officedocument\.spreadsheetml\.sheet})
    ->header_like('Content-Disposition' => qr/products-export\.xlsx/)
    ->content_like(qr{\APK});

$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({
    headers => {'HX-Request-ID' => 'request-123'},
    body => {
        q => 1,
        view => 'graph',
        field => ['product_name', 'unit_price'],
        group => ['category.category_name'],
        measure => 'total_price',
        order => 'product_name',
        direction => 'asc',
        limit => 25,
        page => 1,
    },
})})->message_ok;
my $message = decode_json($t->message->[1]);
is $message->{'HX-Request-ID'}, 'request-123', 'WebSocket response correlates with htmx sender';
is $message->{target}, '#selecto-surface-products', 'WebSocket response targets the explorer surface';
is $message->{swap}, 'outerHTML', 'WebSocket response replaces the surface without replacing the connection';
like $message->{content}, qr/Graph results/, 'WebSocket returns server-rendered graph content';
like $message->{selecto}{url}, qr{\A/explore/products\?}, 'WebSocket response supplies the canonical URL';
like $message->{selecto}{url}, qr/(?:\?|&)view=graph(?:&|\z)/, 'canonical URL records the graph view';
like $message->{selecto}{url}, qr/(?:\?|&)chart_type=bar(?:&|\z)/,
    'canonical URL records the selected chart type';
$t->finish_ok;

$t->get_ok($message->{selecto}{url})
    ->status_is(200)
    ->content_like(qr/Graph results/);

$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({
    headers => {'HX-Request-ID' => 'reorder-456'},
    body => {
        q => 1,
        view => 'detail',
        field => ['unit_price', 'product_name', 'category.category_name'],
        group => ['category.category_name'],
        measure => 'count',
        order => 'product_name',
        direction => 'asc',
        limit => 25,
        page => 1,
    },
})})->message_ok;
my $reordered = decode_json($t->message->[1]);
is $reordered->{'HX-Request-ID'}, 'reorder-456', 'column reorder response correlates with htmx sender';
like $reordered->{content}, qr{<th scope="col">Unit Price</th><th scope="col">Product Name</th>}s,
    'server-rendered table follows the submitted Set order';
cmp_ok index($reordered->{selecto}{url}, 'field=unit_price'), '<',
    index($reordered->{selecto}{url}, 'field=product_name'),
    'canonical URL preserves selected column order';
$t->finish_ok;

$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({
    headers => {'HX-Request-ID' => 'filters-789'},
    body => {
        q => 1,
        view => 'detail',
        field => ['product_name', 'unit_price'],
        filter_field => ['unit_price', 'category.category_name'],
        filter_op => ['gte', 'eq'],
        filter_value => ['', 'Camp Pantry'],
        group => ['category.category_name'],
        measure => 'count',
        order => 'product_name',
        direction => 'asc',
        limit => 25,
        page => 1,
    },
})})->message_ok;
my $filtered = decode_json($t->message->[1]);
is $filtered->{'HX-Request-ID'}, 'filters-789', 'filter response correlates with htmx sender';
like $filtered->{content}, qr/data-sc-filter-set-item data-field="unit_price"/,
    'draft filter remains visible in Set';
like $filtered->{content}, qr/data-sc-filter-set-item data-field="category\.category_name"/,
    'second filter remains visible in Set';
like $filtered->{content}, qr/Enter a value to apply this filter/,
    'draft filter explains when it becomes active';
cmp_ok index($filtered->{selecto}{url}, 'filter_field=unit_price'), '<',
    index($filtered->{selecto}{url}, 'filter_field=category.category_name'),
    'canonical URL preserves aligned multiple-filter order';
is_deeply TestSelectoComponents::Adapter::_predicate_values(
    $TestSelectoComponents::Adapter::LAST_QUERY->predicate,
), ['Camp Pantry'], 'WebSocket query skips the draft and binds the complete filter';
$t->finish_ok;

$t->get_ok('/explore/private-products?view=detail&filter_value=secret-medical-value')
    ->status_is(302)
    ->header_is(Location => '/explore/private-products');

$t->get_ok('/explore/private-products')
    ->status_is(200)
    ->header_is('Cache-Control' => 'no-store')
    ->element_exists('[data-sc-query-params="disabled"]')
    ->element_exists('form#selecto-query-private_products[method="post"]')
    ->text_is('.sc-private-mode' => 'Private URL mode')
    ->element_exists_not('a[href*="format="]')
    ->content_unlike(qr/>Permalink</);

$t->post_ok('/explore/private-products' => form => {
    q => 1,
    view => 'detail',
    field => ['product_name', 'unit_price'],
    filter_field => 'product_name',
    filter_op => 'eq',
    filter_value => 'secret-medical-value',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
})->status_is(200)
    ->header_is('Cache-Control' => 'no-store')
    ->element_exists('input[name="filter_value"][value="secret-medical-value"]')
    ->element_exists('[data-selecto-url="/explore/private-products"]');
is_deeply TestSelectoComponents::Adapter::_predicate_values(
    $TestSelectoComponents::Adapter::LAST_QUERY->predicate,
), ['secret-medical-value'], 'private no-JavaScript POST keeps the filter value in the request body';

$t->websocket_ok('/explore/private-products/ws')->send_ok({text => encode_json({
    headers => {'HX-Request-ID' => 'private-101'},
    body => {
        q => 1,
        view => 'detail',
        field => ['product_name', 'unit_price'],
        filter_field => 'product_name',
        filter_op => 'eq',
        filter_value => 'secret-medical-value',
        group => ['category.category_name'],
        measure => 'count',
        order => 'product_name',
        direction => 'asc',
        limit => 25,
        page => 1,
    },
})})->message_ok;
my $private_message = decode_json($t->message->[1]);
is $private_message->{selecto}{url}, '/explore/private-products',
    'private WebSocket response supplies only the path';
unlike $private_message->{selecto}{url}, qr/secret-medical-value|[?&]/,
    'private canonical URL cannot contain query state or sensitive filter values';
like $private_message->{content}, qr/value="secret-medical-value"/,
    'private query state remains editable in the server-rendered surface';
$t->finish_ok;

done_testing;
