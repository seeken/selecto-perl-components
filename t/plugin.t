use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(decode_json encode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::DateShortcut ();

my $t = Test::Mojo->new(TestSelectoComponents::app());

$t->get_ok('/explore/products')
    ->status_is(200)
    ->content_type_like(qr{text/html})
    ->element_exists('section#selecto-channel-products')
    ->element_exists('form#selecto-query-products')
    ->element_exists('form#selecto-query-products input[name="query_signature"][value]')
    ->element_exists('[role="tablist"][aria-label="Explorer sections"]')
    ->element_exists('[role="tab"][data-sc-builder-tab="view"][aria-selected="true"]')
    ->element_exists('[role="tab"][data-sc-builder-tab="filters"][aria-selected="false"]')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="view"] .sc-view-tabs')
    ->element_exists('[role="tabpanel"][data-sc-builder-panel="filters"][hidden] [data-sc-filter-root]')
    ->element_exists('form[hx-trigger="submit"]')
    ->element_exists('[data-sc-result-view-panel="detail"]:not([disabled])')
    ->element_exists('[data-sc-result-view-panel="summary"][hidden][disabled]')
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
    ->content_like(qr{hx-ws:connect="/explore/products/ws"})
    ->content_like(qr{hx-ws:send})
    ->content_like(qr{/selecto-components/htmx\.min\.js})
    ->content_like(qr{/selecto-components/hx-ws\.min\.js})
    ->content_like(qr{/selecto-components/selecto-components\.css\?v=20260817-5})
    ->content_like(qr{/selecto-components/selecto-components\.js\?v=20260817-5})
    ->element_exists_not('.sc-result-meta .sc-eyebrow')
    ->content_like(qr{<strong>42</strong> rows matched \x{b7} <strong>2</strong> pages})
    ->text_is('.sc-pagination > span' => 'Page 1 of 2')
    ->element_exists('[data-sc-bulk-actions]')
    ->text_is('[data-sc-selection-count]' => '0')
    ->element_exists('[data-sc-action-open="selecto-action-products-add_product_note"][disabled]')
    ->element_exists('input[data-sc-select-page]')
    ->element_exists('input[data-sc-row-select][value="101"]')
    ->element_exists('input[data-sc-row-select][value="102"]')
    ->element_exists('dialog#selecto-action-products-add_product_note')
    ->element_exists('form[action="/explore/products/actions/add_product_note"]')
    ->element_exists('select[name="action_input_note_type"] option[value="internal"]')
    ->element_exists('textarea[name="action_input_comment"][maxlength="255"]')
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
    ->content_like(qr/populateActionTargets/)
    ->content_like(qr/window\.fetch/)
    ->content_like(qr/HTMLFormElement\.prototype\.submit\.call\(form\)/)
    ->content_unlike(qr/requestSubmit/);
$t->get_ok('/selecto-components/selecto-components.css')->status_is(200)
    ->content_like(qr/\.sc-workspace/)
    ->content_like(qr/\.sc-list-picker/)
    ->content_like(qr/\.sc-picker-choice\[hidden\]\s*\{\s*display:\s*none/)
    ->content_like(qr/\.sc-filter-values/)
    ->content_like(qr/\.sc-bulk-actions/)
    ->content_like(qr/\.sc-action-dialog/);

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=unit_price&group=category.category_name&measure=count&order=unit_price&direction=desc&limit=10&page=1&filter_field=unit_price&filter_op=gte&filter_value=12.50')
    ->status_is(200)
    ->content_like(qr/SELECT governed_test_query/)
    ->content_like(qr/12\.50/)
    ->content_like(qr{<strong>42</strong> rows matched \x{b7} <strong>5</strong> pages})
    ->text_is('.sc-pagination > span' => 'Page 1 of 5')
    ->element_exists('table tbody tr');
is_deeply $TestSelectoComponents::Adapter::LAST_QUERY->limit_value, 10, 'GET runs the normalized query';
is_deeply $TestSelectoComponents::Adapter::LAST_COUNT_STATEMENT->params, ['12.50'],
    'total count uses the same bound filters as the result query';
is $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->limit_value, undef,
    'total count removes the page limit';
is $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->offset_value, undef,
    'total count removes the page offset';

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

$t->get_ok('/explore/products?q=1&view=graph&field=product_name&group=category.category_name&measure=count&measure_function=count&measure=total_price&measure_function=sum&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('.sc-chart[aria-label="Selected measures by selected groups"]')
    ->content_like(qr/Product count/)
    ->content_like(qr/Total price/);

$t->get_ok('/explore/products?q=1&view=detail&field=drop_table&order=drop_table&limit=25&page=1')
    ->status_is(422)
    ->content_like(qr/A selected detail field is not available|Choose at least one detail field/)
    ->content_unlike(qr/<script>alert/);

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&group=category.category_name&measure=count&order=product_name&direction=asc&limit=10&page=1&format=csv')
    ->status_is(200)
    ->content_type_like(qr{text/csv})
    ->header_like('Content-Disposition' => qr/products-page-1\.csv/)
    ->content_like(qr/"Product Name"\r?\n/)
    ->content_like(qr/"'=2\+2"/);

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
    ->element_exists_not('a[href*="format=csv"]')
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
