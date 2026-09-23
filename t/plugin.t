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
use Selecto::Components::AssetManifest qw(asset_revision);
use Selecto::Components::RecordEditor ();
use Selecto::Error ();

my $legacy_choice_domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Legacy choices',
    source => {
        source_table => 'legacy_choices', primary_key => 'id',
        fields => [qw(id status)],
        columns => {
            id => {type => 'integer'},
            status => {type => 'string', text_case => 'lowercase'},
        },
        associations => {
            status_value => {
                queryable => 'status_values',
                owner_key => 'status', related_key => 'id',
            },
        },
    },
    schemas => {
        status_values => {
            values => [
                {id => 'active', descr => 'Active'},
                {id => 'inactive', descr => 'Inactive'},
            ],
            primary_key => 'id', fields => [qw(id descr)],
            columns => {
                id => {type => 'string'},
                descr => {type => 'string'},
            },
            associations => {},
        },
    },
    joins => {
        status_value => {
            type => 'star_dimension', name => 'Status',
            display_field => 'descr', dimension_key => 'status',
        },
    },
    writes => {
        operations => {update => {enabled => 1}},
        fields => {status => {updatable => 1}},
    },
    editors => {
        profile => {
            label => 'Edit legacy choice',
            fields => [{field => 'status'}],
        },
    },
}, strict => 1);
my $legacy_editor = $legacy_choice_domain->editors->{profile};
my $kept_legacy_choice = Selecto::Components::RecordEditor->normalize(
    $legacy_choice_domain, $legacy_editor,
    {status => 'retired'}, {status => 'retired'},
);
ok $kept_legacy_choice->{valid},
    'record editors allow an unchanged current value outside the current choices';
my $new_invalid_choice = Selecto::Components::RecordEditor->normalize(
    $legacy_choice_domain, $legacy_editor,
    {status => 'unknown'}, {status => 'retired'},
);
is $new_invalid_choice->{errors}{status}, 'Choose an available value.',
    'record editors reject changing a values foreign key to another unknown value';
my $new_valid_choice = Selecto::Components::RecordEditor->normalize(
    $legacy_choice_domain, $legacy_editor,
    {status => 'active'}, {status => 'retired'},
);
ok $new_valid_choice->{valid},
    'record editors allow replacing a legacy value with a current choice';
my $wrong_case_current_choice = Selecto::Components::RecordEditor->normalize(
    $legacy_choice_domain, $legacy_editor,
    {status => 'ACTIVE'}, {status => 'ACTIVE'},
);
ok $wrong_case_current_choice->{valid},
    'record editors recognize a current choice written in noncanonical case';
is $wrong_case_current_choice->{values}{status}, 'active',
    'record editors canonicalize the case of a recognized current choice';
is_deeply(
    Selecto::Components::RecordEditor->changed(
        $legacy_editor, {status => 'ACTIVE'}, $wrong_case_current_choice->{values},
    ),
    {status => 'active'},
    'saving another edit also repairs a recognized wrong-case value',
);
my $required_empty_option =
    Selecto::Components::Controller::RecordEditor::_select_empty_option(
        {required => 1}, 0,
    );
like $required_empty_option, qr/value="" selected disabled/,
    'an empty required select keeps an explicit disabled placeholder selected';
like $required_empty_option, qr/Select/,
    'the empty required select asks the operator to make a selection';
is Selecto::Components::Controller::RecordEditor::_select_empty_option(
        {required => 1}, 1,
    ), '', 'a populated required select does not render an empty placeholder';
my $nullable_empty_option =
    Selecto::Components::Controller::RecordEditor::_select_empty_option(
        {nullable => 1}, 0,
    );
like $nullable_empty_option, qr/value="" selected/,
    'an empty nullable select explicitly selects its none option';
unlike $nullable_empty_option, qr/disabled/,
    'a nullable select keeps its none option available';

is Selecto::Components::normalize_export_format('Excel'), 'xlsx',
    'Excel aliases normalize case-insensitively to the governed xlsx format';
is Selecto::Components::normalize_export_format('JSON'), 'json',
    'canonical export formats normalize case-insensitively';
is Selecto::Components::normalize_export_format('html'), '',
    'non-export formats do not normalize into an export';

my $t = Test::Mojo->new(TestSelectoComponents::app());

$t->get_ok('/explore/products')
    ->status_is(200)
    ->content_type_like(qr{text/html})
    ->element_exists('section#selecto-channel-products')
    ->attr_is('section#selecto-channel-products' => 'hx-ext' => 'ws')
    ->element_exists('[data-selecto-connection][role="status"][aria-live="polite"][aria-atomic="true"]')
    ->element_exists('[data-sc-workspace]:not(.is-builder-collapsed)')
    ->element_exists('[data-sc-builder-shell="products"]:not(.is-collapsed)')
    ->element_exists('.sc-hero-heading > [data-sc-builder-toggle][aria-expanded="true"][aria-label="Collapse view menu"]')
    ->element_exists('.sc-hero-heading > [data-sc-builder-toggle] + h1 + [data-selecto-connection]')
    ->element_exists_not('.sc-masthead')
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
    ->element_exists('.sc-row-click-control select[name="row_click_action"] option[value="open_product"][selected]')
    ->element_exists('.sc-row-click-control select[name="row_click_action"] option[value="open_product_page"]')
    ->element_exists('[data-sc-result-view-panel="summary"][hidden][disabled]')
    ->element_exists('[data-sc-graph-options][hidden][disabled] select[name="chart_type"]')
    ->element_exists('[data-sc-aggregate-options][hidden][disabled] input[name="aggregate_grid"]')
    ->element_exists('[data-sc-builder-pending][role="status"][aria-live="polite"][aria-atomic="true"]')
    ->element_exists('[data-sc-picker-root]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="field"]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="group"]')
    ->element_exists('[data-sc-picker-root][data-sc-picker-kind="measure"]')
    ->element_exists('[data-sc-picker-kind="measure"] input[name="measure_stack"]')
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
    ->content_like(qr{/selecto-components/htmx\.min\.js\?v=\Q@{[asset_revision()]}\E})
    ->content_like(qr{/selecto-components/hx-ws\.min\.js\?v=\Q@{[asset_revision()]}\E})
    ->content_like(qr{/selecto-components/chart\.umd\.min\.js\?v=\Q@{[asset_revision()]}\E})
    ->element_exists('[data-sc-chart-src]')
    ->element_exists_not('script[src^="/selecto-components/chart.umd.min.js"]')
    ->content_like(qr{/selecto-components/selecto-components\.css\?v=\Q@{[asset_revision()]}\E})
    ->content_like(qr{/selecto-components/selecto-components\.js\?v=\Q@{[asset_revision()]}\E})
    ->element_exists_not('.sc-result-meta .sc-eyebrow')
    ->content_like(qr{<strong>42</strong> rows matched \x{b7} <strong>2</strong> pages \x{b7} <strong>\d+ ms</strong> query time})
    ->element_count_is('.sc-pagination', 2)
    ->text_is('.sc-pagination-top > span' => 'Page 1 of 2')
    ->element_exists('.sc-pagination-top [aria-current="page"]')
    ->element_exists('.sc-pagination-top button[name="page"][value="2"].sc-page-number')
    ->element_exists('.sc-pagination-top button[name="page"][value="2"].sc-page-direction')
    ->text_is('.sc-table-wrap > table > caption' => 'Query results')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available] button[data-field="action:add_product_note"][data-type="action"]')
    ->text_is('[data-sc-picker-kind="field"] button[data-field="action:add_product_note"] strong' => 'Action: Add Product Note')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available] button[data-field="action:build_shipments"][data-type="action"]')
    ->text_is('[data-sc-picker-kind="field"] button[data-field="action:build_shipments"] strong' => 'Action: Build Shipments')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available] button[data-field="action:mark_for_review"][data-type="action"]')
    ->element_exists_not('[data-sc-bulk-actions]')
    ->element_exists_not('input[data-sc-row-select]')
    ->element_exists_not('dialog[data-sc-action-dialog]')
    ->element_exists('a.sc-object-link[href="/products/view?id=101"]')
    ->element_exists('tbody tr.sc-clickable-row[data-sc-row-click][tabindex="0"]' .
        '[data-sc-row-click-type="iframe_modal"]' .
        '[data-sc-row-click-url="/products/maint?id=101&name=%3D2%2B2"]' .
        '[data-sc-row-click-title="Product =2+2"]' .
        '[data-sc-row-dialog-id="selecto-row-dialog-products"]')
    ->element_exists('dialog#selecto-row-dialog-products[data-sc-row-dialog]' .
        '[data-sc-row-dialog-navigation="1"].sc-row-dialog-fullscreen')
    ->element_exists('dialog#selecto-row-dialog-products [data-sc-row-dialog-nav="previous"]')
    ->element_exists('dialog#selecto-row-dialog-products [data-sc-row-dialog-nav="next"]')
    ->element_exists('dialog#selecto-row-dialog-products iframe[data-sc-row-dialog-frame]' .
        '[referrerpolicy="same-origin"]:not([src])')
    ->element_exists('dialog#selecto-row-dialog-products a[data-sc-row-dialog-open][target="_blank"]')
    ->text_is('dialog#selecto-row-dialog-products [data-sc-row-dialog-position]' =>
        'Row 1 of 2 on this page')
    ->text_is('a.sc-object-link[href="/products/view?id=101"]' => '=2+2')
    ->element_exists('details.sc-debug-panel[data-sc-debug-panel]:not([open])')
    ->text_is('.sc-debug-panel > summary strong' => 'Query Debug')
    ->text_is('.sc-debug-stat:nth-child(10) span' => 'Rows returned')
    ->text_is('.sc-debug-stat:nth-child(10) strong' => '2')
    ->text_is('.sc-debug-stat:nth-child(11) strong' => '42')
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
my $alpha_saved_query_link = $t->tx->res->dom
    ->at('[data-sc-saved-queries] .sc-saved-query-list li:nth-child(1) a')
    ->attr('href');
like $alpha_saved_query_link, qr/[?&]saved_query_name=alpha(?:%20|\+)inventory(?:&|\z)/,
    'saved query links carry the selected view name';
$t->get_ok($alpha_saved_query_link)
    ->status_is(200)
    ->text_is('title' => 'alpha inventory')
    ->text_is('h1' => 'alpha inventory');
$t->get_ok('/explore/products?expand_saved=alpha+inventory&expand_saved_type=user')
    ->status_is(302);
my $expanded_user = Mojo::URL->new($t->tx->res->headers->location);
is $expanded_user->path->to_string, '/explore/products',
    'legacy user links redirect to the saved Explorer path';
is $expanded_user->query->param('saved_query_name'), 'alpha inventory',
    'legacy user links retain the saved view title';
is $expanded_user->query->param('field'), 'product_name',
    'legacy user links load the saved fields rather than default state';
$t->get_ok($expanded_user)->status_is(200)
    ->text_is('h1' => 'alpha inventory');
{
    local @TestSelectoComponents::SAVED_QUERIES = (
        @TestSelectoComponents::SAVED_QUERIES,
        {name => 'Team report', readonly => 1,
            url => '/explore/products?q=1&view=detail&field=unit_price&limit=25&page=1'},
        {name => 'Loop', url => '/explore/products?expand_saved=Loop&expand_saved_type=user'},
    );
    $t->get_ok('/explore/products?expand_saved=Team+report&expand_saved_type=client')
        ->status_is(302);
    my $expanded_client = Mojo::URL->new($t->tx->res->headers->location);
    is $expanded_client->query->param('field'), 'unit_price',
        'legacy client links resolve a shared saved view';
    $t->get_ok('/explore/products?expand_saved=Team+report&expand_saved_type=user')
        ->status_is(404);
    $t->get_ok('/explore/products?expand_saved=alpha+inventory&expand_saved_type=client')
        ->status_is(404);
    $t->get_ok('/explore/products?expand_saved=Wrong+explorer&expand_saved_type=user')
        ->status_is(404);
    $t->get_ok('/explore/products?expand_saved=Loop&expand_saved_type=user')
        ->status_is(404);
    $t->get_ok('/explore/products?expand_saved=alpha+inventory&expand_saved_type=priv')
        ->status_is(400);
}
my $changed_saved_query_url = Mojo::URL->new($alpha_saved_query_link);
$changed_saved_query_url->query->param(field => 'unit_price');
$t->get_ok($changed_saved_query_url)
    ->status_is(200)
    ->text_is('title' => 'Product Explorer')
    ->text_is('h1' => 'Product Explorer');

my $record_editor_url = '/explore/products/records/101/edit?editor=product_profile' .
    '&return_to=%2Fexplore%2Fproducts';
$t->get_ok($record_editor_url)
    ->status_is(200)
    ->element_exists('form[data-sc-record-editor-form]')
    ->text_is('.sc-record-editor-section:nth-child(1) h4' => 'Identity')
    ->text_is('[data-sc-record-editor-field="id"] output' => '101')
    ->element_exists_not('[name="editor_field_id"]')
    ->text_is('.sc-record-editor-section:nth-child(2) h4' => 'Profile')
    ->element_exists('input[name="editor_field_product_name"][value="Test Widget"][required]')
    ->element_exists('input[name="editor_field_unit_price"][type="number"]')
    ->text_is('[data-sc-record-editor-field="unit_price"] .sc-record-editor-help' =>
        'Selling price per unit.')
    ->element_exists('input[name="editor_field_created_on"][type="date"]')
    ->element_exists('input[name="editor_field_discontinued"][type="checkbox"]' .
        ':not([required]):not([aria-required])')
    ->text_is('form[data-sc-record-editor-form] button[type="submit"]' => 'Save product')
    ->element_exists('[data-sc-record-editor-action-open="sc-record-editor-action-edit_one_product"]' .
        '[aria-expanded="false"]')
    ->text_is('[data-sc-record-editor-action-open]' => 'Edit One Product')
    ->element_exists('form#sc-record-editor-action-edit_one_product' .
        '[data-sc-record-editor-action-panel][hidden]')
    ->text_is('form#sc-record-editor-action-edit_one_product button[type="submit"]' =>
        'Edit One Product')
    ->content_unlike(qr/Apply to selected rows/);
my $record_editor_form = $t->tx->res->dom->at('form[data-sc-record-editor-form]');
my %record_editor_hidden = map {
    $_->attr('name') => $_->attr('value')
} @{$record_editor_form->find('input[type="hidden"]')->to_array};
is $TestSelectoComponents::ELIGIBILITY_REQUESTS[-1]{phase}, 'display',
    'record editor checks host row eligibility before offering an action';
my $unicode_record_name = "Test \x{2014} Widget";
$TestSelectoComponents::Adapter::RECORD_PRODUCT_NAME = $unicode_record_name;
$t->get_ok($record_editor_url => {'Accept-Encoding' => 'gzip'})
    ->status_is(200)
    ->attr_is('input[name="editor_field_product_name"]' => value => $unicode_record_name);
$TestSelectoComponents::Adapter::RECORD_PRODUCT_NAME = 'Test Widget';
$t->get_ok('/explore/products/records/102/edit?editor=product_profile')
    ->status_is(200)
    ->element_exists_not('[data-sc-record-editor-action-open]');

$t->post_ok('/explore/products/records/101/edit?editor=product_profile' =>
    {Accept => 'application/json'} => form => {
        %record_editor_hidden,
        editor_field_product_name => 'Updated Widget',
        editor_field_unit_price => '12.5',
        editor_field_created_on => '2026-09-15',
    })
    ->status_is(200)
    ->json_is('/ok' => 1)
    ->json_is('/row_id' => '101')
    ->json_is('/authorized' => 1)
    ->json_is('/changed_fields/0' => 'product_name')
    ->json_is('/close_dialog' => 0);
is_deeply $TestSelectoComponents::Adapter::LAST_WRITE->assignments,
    {product_name => 'Updated Widget'},
    'record editor sends only changed governed assignments';

$t->post_ok('/explore/products/records/101/edit?editor=product_profile' =>
    {Accept => 'application/json'} => form => {
        %record_editor_hidden,
        editor_field_product_name => 'Test Widget',
        editor_field_unit_price => '12345678901234567890.123456789',
        editor_field_created_on => '2026-09-15',
    })
    ->status_is(200)
    ->json_is('/ok' => 1);
is_deeply $TestSelectoComponents::Adapter::LAST_WRITE->assignments,
    {unit_price => '12345678901234567890.123456789'},
    'record editor preserves exact numeric strings through the governed write';

$TestSelectoComponents::Adapter::WRITE_ERROR = Selecto::Error->new(
    code => 'cardinality_mismatch', message => 'stale editor snapshot',
);
$t->post_ok('/explore/products/records/101/edit?editor=product_profile' =>
    {Accept => 'application/json'} => form => {
        %record_editor_hidden,
        editor_field_product_name => 'Conflicting Widget',
        editor_field_unit_price => '12.5',
        editor_field_created_on => '2026-09-15',
    })
    ->status_is(409)
    ->json_is('/ok' => 0)
    ->json_is('/code' => 'record_changed')
    ->json_like('/message' => qr/changed after you opened it/);
$TestSelectoComponents::Adapter::WRITE_ERROR = undef;

$t->post_ok('/explore/products/records/101/edit?editor=product_profile' =>
    {Accept => 'application/json'} => form => {
        %record_editor_hidden,
        editor_field_product_name => '',
        editor_field_unit_price => 'not-a-number',
        editor_field_created_on => '09/15/2026',
    })
    ->status_is(422)
    ->json_is('/ok' => 0)
    ->json_is('/field_errors/product_name' => 'This field is required.')
    ->json_is('/field_errors/unit_price' => 'Enter a number.')
    ->json_is('/field_errors/created_on' => 'Enter a date as YYYY-MM-DD.');
$t->post_ok('/explore/products/records/101/edit?editor=product_profile' =>
    {Accept => 'application/json'} => form => {
        %record_editor_hidden,
        editor_field_product_name => 'Test Widget',
        editor_field_unit_price => '12.5',
        editor_field_created_on => '2026-09-15',
        editor_field_category_id => 99,
    })
    ->status_is(422)
    ->json_is('/ok' => 0)
    ->json_like('/message' => qr/not available in this editor/);
my $record_editor_results_url = '/explore/products?q=1&view=detail' .
    '&row_click_action=edit_product&field=product_name&field_alias=&field_format=' .
    '&group=category.category_name&measure=count&order=product_name&direction=asc' .
    '&limit=25&page=1';
$t->get_ok($record_editor_results_url)
    ->status_is(200)
    ->element_exists('tbody tr[data-sc-record-id="101"][data-sc-row-click-type="record_editor"]')
    ->element_exists('dialog[data-sc-row-dialog-kind="record_editor"].sc-row-editor-dialog')
    ->element_exists('dialog[data-sc-row-dialog-kind="record_editor"] [data-sc-row-editor-body]')
    ->element_exists_not('dialog[data-sc-row-dialog-kind="record_editor"] iframe');
$t->get_ok('/explore/products')->status_is(200);
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
    ->element_exists('[data-sc-bulk-action][data-sc-action-id="add_product_note"] > div[role="status"][aria-live="polite"][aria-atomic="true"]')
    ->element_exists('[data-sc-action-open="selecto-action-products-add_product_note"][disabled]')
    ->element_exists('[data-sc-action-open="selecto-action-products-mark_for_review"][disabled]')
    ->element_exists('th[data-sc-action-column="add_product_note"] input[data-sc-select-page][data-sc-action-id="add_product_note"]')
    ->element_exists('th[data-sc-action-column="mark_for_review"] input[data-sc-select-page][data-sc-action-id="mark_for_review"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="add_product_note"][value="101"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="add_product_note"][value="102"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="mark_for_review"][value="101"]')
    ->element_exists('input[data-sc-row-select][data-sc-action-id="mark_for_review"][value="102"]')
    ->element_exists('dialog#selecto-action-products-add_product_note[aria-labelledby="selecto-action-products-add_product_note-title"]')
    ->element_exists('#selecto-action-products-add_product_note-title')
    ->element_exists('dialog#selecto-action-products-mark_for_review[aria-labelledby="selecto-action-products-mark_for_review-title"]')
    ->element_exists('#selecto-action-products-mark_for_review-title')
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

my $row_action_columns_url = '/explore/products?q=1&view=detail' .
    '&field=action%3Aedit_one_product&field_alias=&field_format=' .
    '&field=product_name&field_alias=&field_format=' .
    '&field=action%3Aset_reorder_level&field_alias=&field_format=' .
    '&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=1';
$t->get_ok($row_action_columns_url)
    ->status_is(200)
    ->element_exists_not('[data-sc-bulk-actions]')
    ->element_exists_not('th[data-sc-action-column="edit_one_product"] input[data-sc-select-page]')
    ->element_exists_not('input[data-sc-row-select][data-sc-action-id="edit_one_product"]')
    ->element_exists('[data-sc-bulk-action][data-sc-action-id="edit_one_product"]' .
        '[data-sc-action-mode="row-dialog"][data-sc-action-max-rows="1"]')
    ->element_exists('button[data-sc-action-id="edit_one_product"]' .
        '[data-sc-row-action-target="101"]')
    ->element_exists('button[data-sc-action-id="edit_one_product"]' .
        '[data-sc-row-action-target="102"]')
    ->element_exists('dialog#selecto-action-products-edit_one_product form' .
        '[action="/explore/products/actions/edit_one_product"]')
    ->element_count_is('[data-sc-bulk-action][data-sc-action-id="set_reorder_level"]' .
        '[data-sc-action-mode="row-inline"]', 2)
    ->element_exists('[data-sc-bulk-action][data-sc-action-id="set_reorder_level"]' .
        '[data-sc-row-id="101"] input[name="action_input_level"][type="number"]')
    ->element_exists('[data-sc-bulk-action][data-sc-action-id="set_reorder_level"]' .
        '[data-sc-row-id="101"] button[type="submit"]');

my $row_action_csrf = $t->tx->res->dom
    ->at('form[action="/explore/products/actions/edit_one_product"] input[name="csrf_token"]')
    ->attr('value');
$t->post_ok('/explore/products/actions/edit_one_product' => {Accept => 'application/json'} => form => {
    csrf_token => $row_action_csrf,
    selected_id => [101, 102],
    action_input_note => 'One row only',
})->status_is(422)->json_is('/ok' => 0)
    ->json_like('/message' => qr/Select exactly one row/);
$t->post_ok('/explore/products/actions/edit_one_product' => {Accept => 'application/json'} => form => {
    csrf_token => $row_action_csrf,
    selected_id => [102],
    action_input_note => 'Not eligible',
})->status_is(403)->json_is('/ok' => 0)
    ->json_is('/message' => 'That action is not available for this row.');
is $TestSelectoComponents::ELIGIBILITY_REQUESTS[-1]{phase}, 'execute',
    'action execution rechecks host row eligibility';
$t->post_ok('/explore/products/actions/edit_one_product' => {Accept => 'application/json'} => form => {
    csrf_token => $row_action_csrf,
    selected_id => [101],
    action_input_note => 'Eligible row',
})->status_is(200)->json_is('/ok' => 1)
    ->json_is('/message' => 'Product edited.');

$t->post_ok('/explore/products/actions/set_reorder_level' => {Accept => 'application/json'} => form => {
    csrf_token => $row_action_csrf,
    selected_id => [101],
    action_input_level => 12,
})->status_is(200)->json_is('/ok' => 1)
    ->json_is('/applied_count' => 1);
is_deeply $TestSelectoComponents::ACTION_REQUESTS[-1]{selected_ids}, ['101'],
    'an inline row action submits exactly its own row target';

my $grouped_action_url = '/explore/products?q=1&view=detail' .
    '&field=action%3Abuild_shipments&field_alias=&field_format=' .
    '&field=product_name&field_alias=&field_format=' .
    '&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=1';
@TestSelectoComponents::ELIGIBILITY_REQUESTS = ();
$t->get_ok($grouped_action_url)
    ->status_is(200)
    ->element_exists('[data-sc-bulk-action][data-sc-action-id="build_shipments"][data-sc-action-mode="groups"]')
    ->element_exists('th.sc-group-select-column[data-sc-action-column="build_shipments"]')
    ->element_exists_not('th[data-sc-action-column="build_shipments"] input[data-sc-select-page]')
    ->element_exists('[data-sc-group-markers][data-sc-action-id="build_shipments"][data-sc-row-id="101"]')
    ->element_exists_not('[data-sc-group-markers][data-sc-action-id="build_shipments"][data-sc-row-id="102"]')
    ->element_exists('td[data-sc-action-column="build_shipments"][data-sc-action-eligible="0"]')
    ->attr_like('[data-sc-group-markers][data-sc-action-id="build_shipments"][data-sc-row-id="101"]' =>
        'data-sc-row-details' => qr/Stock.*21/)
    ->element_exists('input[name="action_groups"][data-sc-action-groups]')
    ->element_exists('[data-sc-group-action-groups]')
    ->element_exists('dialog#selecto-action-products-build_shipments[aria-labelledby="selecto-action-products-build_shipments-title"]')
    ->element_exists('#selecto-action-products-build_shipments-title')
    ->content_like(qr{pink_heart})
    ->content_like(qr{orange_star})
    ->content_like(qr{yellow_moon})
    ->content_like(qr{green_clover})
    ->content_like(qr{blue_diamond})
    ->content_like(qr{purple_horseshoe})
    ->content_like(qr{carrier_id})
    ->content_like(qr{&quot;type&quot;:&quot;lookup&quot;})
    ->content_like(qr{\\/explore\\/products\\/actions\\/build_shipments\\/lookups\\/carrier_id});
ok((grep {
        defined($_->alias_name)
            && $_->alias_name eq 'build_shipments_eligible'
    } @{$TestSelectoComponents::Adapter::LAST_DATA_QUERY->selections}),
    'grouped action eligibility is selected as part of the governed data query');
is scalar(@TestSelectoComponents::ELIGIBILITY_REQUESTS), 0,
    'SQL-backed action eligibility does not invoke a per-row host resolver';

my $grouped_csrf = $t->tx->res->dom
    ->at('form[action="/explore/products/actions/build_shipments"] input[name="csrf_token"]')
    ->attr('value');

@TestSelectoComponents::LOOKUP_REQUESTS = ();
$t->get_ok('/explore/products/actions/build_shipments/lookups/carrier_id' .
        '?q=acme&selected_id=101&selected_id=102' => {Accept => 'application/json'})
    ->status_is(200)
    ->header_is('Cache-Control' => 'no-store')
    ->json_is('/results/0/value' => '501')
    ->json_is('/results/0/label' => 'Acme Transport')
    ->json_like('/results/0/description' => qr/Detroit.*MI/);
is $TestSelectoComponents::LOOKUP_REQUESTS[-1]{query}, 'acme',
    'co-domain scope receives the normalized action lookup query';
is_deeply $TestSelectoComponents::LOOKUP_REQUESTS[-1]{selected_ids}, ['101', '102'],
    'co-domain scope receives active group rows for host authorization and scoping';

$t->get_ok('/explore/products/actions/build_shipments/lookups/carrier_id?q=a')
    ->status_is(200)->json_is('/results' => []);
is scalar(@TestSelectoComponents::LOOKUP_REQUESTS), 1,
    'queries below the configured minimum do not call the host lookup source';
$t->get_ok('/explore/products/actions/build_shipments/lookups/not_an_input?q=acme')
    ->status_is(404)->json_is('/results' => []);

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
    ->json_like('/message' => qr/Pink heart: Carrier is below its minimum/);

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
    ->content_like(qr/htmx:ws:after:message:incoming/)
    ->content_like(qr/pending\.textContent\s*=\s*"Pending changes"/)
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
    ->content_like(qr/function showResultsLoading/)
    ->content_like(qr/showResultsLoading\(form\)/)
    ->content_like(qr/showResultsLoading\(form\);\s*setBuilderTrayCollapsed/s)
    ->content_like(qr/results\.replaceChildren\(loading\)/)
    ->content_like(qr/Running query/)
    ->content_like(qr/stageResultView/)
    ->content_like(qr/hiddenFilterValue\("filter_group", "0"\)/)
    ->content_like(qr/hiddenFilterValue\("filter_clause", ""\)/)
    ->content_like(qr/function updateGridSelection/)
    ->content_like(qr/function gridSelectionPlan/)
    ->content_like(qr/function showGridAxisHover/)
    ->content_like(qr/\.sc-aggregate-grid td\[data-sc-grid-row\]\[data-sc-grid-column\]/)
    ->content_like(qr/is-grid-axis-hover/)
    ->content_like(qr/plan\.clauseCount > maximum/)
    ->content_like(qr/That selection would create/)
    ->content_like(qr/data-sc-grid-compact-input/)
    ->content_like(qr/data-sc-grid-row-toggle/)
    ->content_like(qr/data-sc-grid-column-toggle/)
    ->content_like(qr/setBuilderTrayCollapsed\(shell, true\)/)
    ->content_like(qr/data-sc-filter-clause-remove/)
    ->content_like(qr/dateFormats/)
    ->content_like(qr/dateShortcuts/)
    ->content_like(qr/rebuildFilterValues/)
    ->content_like(qr/scPickerKind/)
    ->content_like(qr/window\.addEventListener\("submit"/)
    ->content_like(qr/data-sc-row-select/)
    ->content_like(qr/function actionControls/)
    ->content_like(qr/function initializeChart/)
    ->content_like(qr/function copyDebugSql/)
    ->content_like(qr/function openRowDialog/)
    ->content_like(qr/function setRowDialogIndex/)
    ->content_like(qr/function moveRowDialog/)
    ->content_like(qr/data-sc-row-dialog-frame/)
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
    ->content_like(qr/function renderActionResult/)
    ->content_like(qr/function renderBuiltLoadCard/)
    ->content_like(qr/data-sc-group-action-card/)
    ->content_like(qr/sc-action-built-load-link/)
    ->content_like(qr/loadLink\.target\s*=\s*"_blank"/)
    ->content_like(qr/loadLink\.rel\s*=\s*"noopener noreferrer"/)
    ->content_like(qr/function markerSvgPart/)
    ->content_like(qr/createElementNS\("http:\/\/www\.w3\.org\/2000\/svg"/)
    ->content_like(qr/window\.fetch/)
    ->content_like(qr/HTMLFormElement\.prototype\.submit\.call\(form\)/)
    ->content_like(qr/requestSubmit/);
$t->get_ok('/selecto-components/htmx.min.js')->status_is(200)
    ->content_type_like(qr{javascript})
    ->content_like(qr/version="4\.0\.0"/)
    ->content_unlike(qr/4\.0\.0-beta/);
$t->get_ok('/selecto-components/hx-ws.min.js')->status_is(200)
    ->content_type_like(qr{javascript})
    ->content_like(qr/htmx:ws:after:message:incoming/)
    ->content_unlike(qr/htmx:after:ws:message/);
$t->get_ok('/selecto-components/chart.umd.min.js')->status_is(200)
    ->content_type_like(qr{javascript})
    ->content_like(qr/Chart\.js v4\.5\.1/);
$t->get_ok('/selecto-api-console/selecto-api-console.js')->status_is(200)
    ->content_type_like(qr{javascript})
    ->content_like(qr/global\.SelectoAPIConsole/)
    ->content_like(qr/function collectFields/)
    ->content_like(qr/function compareSemanticFields/)
    ->content_like(qr/data-selecto-api-console/)
    ->content_like(qr/data-sac-response-format/)
    ->content_like(qr/data-sac-response-filename/)
    ->content_like(qr/credentials:\s*"same-origin"/)
    ->content_unlike(qr/innerHTML\s*=\s*.*domain\.name/);
$t->get_ok('/selecto-api-console/selecto-api-console.css')->status_is(200)
    ->content_type_like(qr{text/css})
    ->content_like(qr/\.sac-query-layout/)
    ->content_like(qr/\.sac-request-editor/)
    ->content_like(qr/\.sac-table-wrap/)
    ->content_like(qr/prefers-reduced-motion/);
$t->get_ok('/selecto-api-console/index.html')->status_is(200)
    ->content_type_like(qr{text/html})
    ->content_like(qr/data-selecto-api-console/);
$t->get_ok('/selecto-api-console/manifest.json')->status_is(200)
    ->content_type_like(qr{application/json})
    ->json_is('/format', 'selecto.api-console.assets.v1')
    ->json_is('/version', '0.5.0');
$t->get_ok('/selecto-api-console/compatibility.json')->status_is(200)
    ->content_type_like(qr{application/json})
    ->json_is('/format', 'selecto.api-console.compatibility.v1')
    ->json_is('/targets/3/id', 'typescript_postgresql');
$t->get_ok('/selecto-components/selecto-components.css')->status_is(200)
    ->content_like(qr/--sc-control-border:\s*#5d7176/)
    ->content_like(qr/\.sc-numeric-measure\s*\{[^}]*text-align:\s*right/)
    ->content_like(qr/\.sc-builder select[^}]*border:\s*1px solid var\(--sc-control-border\)/s)
    ->content_like(qr/\.sc-workspace/)
    ->content_like(qr/\.sc-list-picker/)
    ->content_like(qr/\.sc-picker-choice\[hidden\]\s*\{\s*display:\s*none/)
    ->content_like(qr/\.sc-filter-values/)
    ->content_like(qr/\.sc-bulk-actions/)
    ->content_like(qr/\.sc-chart-canvas/)
    ->content_like(qr/\.sc-bulk-action/)
    ->content_like(qr/\.sc-action-dialog/)
    ->content_like(qr/\.sc-row-dialog/)
    ->content_like(qr/\.sc-row-dialog-fullscreen/)
    ->content_like(qr/\.sc-visually-hidden/)
    ->content_like(qr/\.sc-view-tab input:focus-visible \+ span/)
    ->content_like(qr/\.sc-group-marker/)
    ->content_like(qr/\.sc-group-action-card/)
    ->content_like(qr/\.sc-group-action-card\.is-built/)
    ->content_like(qr/\.sc-group-action-orders/)
    ->content_like(qr/\.sc-action-lookup-results/)
    ->content_like(qr/\.sc-action-built-loads/)
    ->content_like(qr/width:\s*max-content/)
    ->content_unlike(qr/\.sc-nested-table th[^}]*text-overflow/s)
    ->content_like(qr/\.sc-table-wrap\s*>\s*table\s*>\s*thead\s*>\s*tr\s*>\s*th:first-child/)
    ->content_like(qr/\.sc-table-wrap\s*>\s*table\s*>\s*tbody\s*>\s*tr\s*>\s*td:first-child/)
    ->content_like(qr/\.sc-results\s*\{[^}]*min-width:\s*0;[^}]*overflow:\s*hidden/s)
    ->content_like(qr/\.sc-results-loading/)
    ->content_like(qr/\.sc-results-spinner/)
    ->content_like(qr/animation:\s*sc-results-spin/)
    ->content_like(qr/\.sc-table-wrap\s*\{[^}]*max-width:\s*100%;[^}]*overflow-x:\s*auto/s)
    ->content_like(qr/\.sc-table-wrap\s*>\s*table\s*\{[^}]*width:\s*max-content/s)
    ->content_like(qr/\.sc-sql-keyword/)
    ->content_like(qr/\.sc-sql-parameter/)
    ->content_unlike(qr/\.sc-group-marker-glyph[^}]*font-family/s)
    ->content_like(qr/\.sc-workspace\.is-builder-collapsed/)
    ->content_like(qr/\.sc-builder\.is-collapsed/)
    ->content_like(qr/\.sc-workspace\s*\{[^}]*max-width:\s*100%;[^}]*min-width:\s*0;[^}]*width:\s*100%/s)
    ->content_unlike(qr/margin-left:\s*calc\(50%\s*-\s*50vw\)/)
    ->content_unlike(qr/\.sc-workspace\s*\{[^}]*width:\s*100vw/s)
    ->content_like(qr/\.sc-workspace\s*>\s*\*\s*\{[^}]*min-width:\s*0/s)
    ->content_like(qr/\@container\s*\(max-width:\s*880px\)/)
    ->content_like(qr/\.sc-builder form\s*\{[^}]*max-width:\s*100%;[^}]*min-width:\s*0/s)
    ->content_like(qr/\.sc-query-summary-chips span\s*\{[^}]*flex:\s*0\s+1\s+auto;[^}]*min-width:\s*0/s)
    ->content_like(qr/\.sc-list-picker\s*\{[^}]*max-width:\s*100%;[^}]*min-width:\s*0/s)
    ->content_like(qr/border-left:\s*0/)
    ->content_like(qr/\.sc-builder\s*\{[^}]*padding:\s*8px\s+16px\s+16px\s+8px/)
    ->content_like(qr/\.sc-hero-heading\s*\{[^}]*display:\s*flex/)
    ->content_like(qr/\.sc-workspace\.is-builder-collapsed\s*\{[^}]*--sc-tray-width:\s*0px;[^}]*gap:\s*0/s)
    ->content_like(qr/\.sc-builder\.is-collapsed\s*\{[^}]*height:\s*0;[^}]*padding:\s*0/s)
    ->content_like(qr/cubic-bezier\(\.22,\s*1,\s*\.36,\s*1\)/)
    ->content_like(qr/\@property\s+--sc-tray-width/)
    ->content_unlike(qr/\.sc-builder\s*\{[^}]*max-height:\s*calc\(100vh/s);

my $formatted_membership_sql = Selecto::Components::Renderer::_format_sql(
    'SELECT "s0"."id", "s0"."parent_id" FROM "client_profile" AS "s0" ' .
    'WHERE "s0"."parent_id" IN ($1, $2, $3) ORDER BY "s0"."id", "s0"."parent_id"',
);
like $formatted_membership_sql, qr/"id",\n  "s0"\."parent_id"/,
    'debug SQL still separates top-level selected fields';
like $formatted_membership_sql, qr/IN \(\$1, \$2, \$3\)/,
    'debug SQL keeps an IN parameter list compact';
unlike $formatted_membership_sql, qr/IN \(\$1,\n/,
    'debug SQL does not put every membership parameter on its own line';

my $formatted_subquery_sql = Selecto::Components::Renderer::_format_sql(
    'SELECT s0.id FROM load AS s0 WHERE EXISTS (SELECT e1.id FROM load_event AS e1 ' .
    'WHERE e1.load_id = s0.id AND e1.status = $1) ORDER BY s0.id',
);
like $formatted_subquery_sql,
    qr/WHERE EXISTS \(\n  SELECT e1\.id\n  FROM load_event AS e1\n  WHERE e1\.load_id = s0\.id\n    AND e1\.status = \$1\n\)\nORDER BY s0\.id/,
    'debug SQL indents subqueries and their clauses beneath the parent query';
my $colored_subquery_sql = Selecto::Components::Renderer::Debug::_highlight_sql(
    $formatted_subquery_sql,
);
like $colored_subquery_sql,
    qr/sc-sql-relation-1">load<\/span>.*sc-sql-relation-1">s0<\/span>/s,
    'a table and its alias share one stable debug color';
like $colored_subquery_sql,
    qr/sc-sql-relation-2">load_event<\/span>.*sc-sql-relation-2">e1<\/span>/s,
    'a nested table receives a distinct debug color';
like $colored_subquery_sql,
    qr/sc-sql-relation-2">e1\.load_id<\/span>.*sc-sql-relation-1">s0\.id<\/span>/s,
    'qualified column references retain their table alias color';
my $repeated_table_sql = Selecto::Components::Renderer::Debug::_highlight_sql(
    'SELECT c1.id, c2.id FROM client_profile AS c1 ' .
    'LEFT JOIN client_profile AS c2 ON c1.parent_id = c2.id',
);
like $repeated_table_sql,
    qr/sc-sql-relation-1">client_profile<\/span>.*sc-sql-relation-1">c1<\/span>.*sc-sql-relation-2">client_profile<\/span>.*sc-sql-relation-2">c2<\/span>/s,
    'repeated joins color each table occurrence with its specific alias';

my $readable_membership_sql = Selecto::Components::Renderer::Debug::_readable_sql(
    'SELECT "s0"."id", "s0"."order" FROM "load" AS "s0" WHERE "s0"."id" = $1',
    'postgresql',
);
is $readable_membership_sql,
    'SELECT s0.id, s0."order" FROM load AS s0 WHERE s0.id = $1',
    'debug SQL removes only unnecessary PostgreSQL identifier quotes';
my $standalone_sql = Selecto::Components::Renderer::Debug::_interpolate_sql(
    q{SELECT "s0"."name" FROM "load" AS "s0" WHERE "s0"."name" = $1 AND "s0"."id" = $2 AND "s0"."note" = $3},
    ["x'; DROP TABLE load; --\\haul\nnext", '12.50', undef],
    'postgresql',
);
is $standalone_sql,
    q{SELECT "s0"."name" FROM "load" AS "s0" WHERE "s0"."name" = E'x''; DROP TABLE load; --\\\\haul\nnext' AND "s0"."id" = E'12.50' AND "s0"."note" = NULL},
    'standalone PostgreSQL debug SQL safely quotes and interpolates every parameter';

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=unit_price&group=category.category_name&measure=count&order=unit_price&direction=desc&limit=10&page=1&filter_field=unit_price&filter_op=gte&filter_value=12.50')
    ->status_is(200)
    ->element_exists('.sc-debug-query:nth-of-type(1) code.sc-sql .sc-sql-keyword')
    ->element_exists('.sc-debug-query:nth-of-type(1) button[data-sc-debug-copy-source]')
    ->element_exists('.sc-debug-query:nth-of-type(1) pre[hidden][aria-hidden="true"]')
    ->content_like(qr/12\.50/)
    ->content_like(qr{<strong>42</strong> rows matched \x{b7} <strong>5</strong> pages \x{b7} <strong>\d+ ms</strong> query time})
    ->element_count_is('.sc-pagination', 2)
    ->text_is('.sc-pagination-top > span' => 'Page 1 of 5')
    ->element_count_is('.sc-pagination-top .sc-page-number', 4)
    ->element_exists('table tbody tr');
is_deeply $TestSelectoComponents::Adapter::LAST_QUERY->limit_value, 10, 'GET runs the normalized query';
is_deeply $TestSelectoComponents::Adapter::LAST_COUNT_STATEMENT->params, ['12.50'],
    'total count uses the same bound filters as the result query';
is $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->limit_value, undef,
    'total count removes the page limit';
is $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->offset_value, undef,
    'total count removes the page offset';
is_deeply $TestSelectoComponents::Adapter::LAST_COUNT_QUERY->orders, [],
    'total count drops ordering';

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=unit_price&group=category.category_name&measure=count&order=unit_price&direction=desc&limit=10&page=1&filter_field=unit_price&filter_op=gte&filter_value=12.50&filter_promote_field=unit_price')
    ->status_is(200)
    ->element_exists('[data-sc-promoted-filters]')
    ->element_exists('[data-sc-promoted-filter][data-field="unit_price"] select[data-sc-promoted-filter-input="op"] option[value="gte"][selected]')
    ->element_exists('[data-sc-promoted-filter][data-field="unit_price"] input[data-sc-promoted-filter-input="value"][value="12.50"]')
    ->element_exists('[data-sc-filter-set-item][data-field="unit_price"] input[name="filter_promote_index"][value="1"][checked]')
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

$t->get_ok('/explore/products?q=1&view=detail&field=created_on&field_alias=Created+date&field_format=day&field=created_on&field_alias=Created+time&field_format=time&filter_field=created_on&filter_op=gte&filter_value=2026-08-01&filter_field=created_on&filter_op=lt&filter_value=2026-09-01&order=created_on')
    ->status_is(200)
    ->element_count_is('[data-sc-picker-kind="field"] [data-sc-picker-set-item][data-field="created_on"]', 2)
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-set-item]:nth-child(1) input[name="field_alias"][value="Created date"]')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-set-item]:nth-child(1) select[name="field_format"] option[value="day"][selected]')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-set-item]:nth-child(2) input[name="field_alias"][value="Created time"]')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-set-item]:nth-child(2) select[name="field_format"] option[value="time"][selected]')
    ->element_exists('[data-sc-picker-kind="field"] [data-sc-picker-available-item][data-field="created_on"][data-sc-picker-repeatable]')
    ->element_count_is('[data-sc-filter-set-item][data-field="created_on"]', 2)
    ->element_exists('[data-sc-filter-available-item][data-field="created_on"]');

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
    ->element_exists('form[data-sc-date-shortcuts]')
    ->content_like(qr/mtd_all_years/)
    ->content_like(qr/qtd_all_years/)
    ->content_like(qr/ytd_all_years/)
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
    ->element_exists('form.sc-drilldown-form input[name="filter_group"][value="0"]')
    ->element_exists('form.sc-drilldown-form input[name="filter_promote_field"]' .
        '[value="category.category_name"]')
    ->text_is('form.sc-drilldown-form button.sc-drilldown-value' => 'Value 1')
    ->element_exists('tr.sc-rollup-total[data-rollup-level="0"]')
    ->content_like(qr{<tr class="sc-rollup-row sc-rollup-total"[^>]*>.*?sc-rollup-total-label">Total</span>}s)
    ->content_unlike(qr{<th[^>]*>Details</th>})
    ->content_unlike(qr/View details/i)
    ->content_like(qr{class="sc-drilldown-value"[^>]*>\[NULL\]</button>})
    ->element_exists('form.sc-drilldown-form input[name="filter_op"][value="is_null"]')
    ->content_like(qr{filter_field" value="unit_price".*?filter_group" value="0".*?filter_field" value="category\.category_name".*?filter_group" value="0".*?filter_promote_field" value="category\.category_name"}s);

$t->get_ok('/explore/products?q=1&view=detail&field=product_name&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=1&filter_field=category.category_name&filter_op=eq&filter_value=Value+1&filter_value_end=&filter_group=0&filter_promote_field=category.category_name')
    ->status_is(200)
    ->element_exists('[data-sc-promoted-filter][data-field="category.category_name"]')
    ->element_exists('[data-sc-promoted-filter][data-field="category.category_name"] ' .
        'select[data-sc-promoted-filter-input="op"] option[value="eq"][selected]')
    ->element_exists('[data-sc-promoted-filter][data-field="category.category_name"] ' .
        'input[data-sc-promoted-filter-input="value"][value="Value 1"]')
    ->element_exists('[data-sc-filter-set-item][data-field="category.category_name"] ' .
        'input[name="filter_promote_index"][value="1"][checked]')
    ->content_unlike(qr/Aggregate value:/);

$t->get_ok('/explore/products?q=1&view=detail&field=created_on&group=created_on&group_format=month&measure=count&order=created_on&direction=asc&limit=25&page=1&filter_field=created_on&filter_op=eq&filter_value=2026-08&filter_value_end=&filter_group=1&filter_promote_field=created_on')
    ->status_is(200)
    ->element_exists('[data-sc-promoted-filter][data-field="created_on"] ' .
        'select[data-sc-promoted-filter-input="op"] option[value="eq"][selected]')
    ->element_exists('[data-sc-promoted-filter][data-field="created_on"] ' .
        'select[data-sc-promoted-filter-input="op"] option[value="is_null"]')
    ->element_exists('[data-sc-promoted-filter][data-field="created_on"] ' .
        'input[type="text"][data-sc-promoted-filter-input="value"][value="2026-08"]')
    ->element_exists('[data-sc-grouped-filter][data-field="created_on"] select[name="filter_op"]')
    ->element_exists('[data-sc-grouped-filter][data-field="created_on"] input[name="filter_value"]' .
        '[value="2026-08"]')
    ->content_unlike(qr/Aggregate value:/);

$t->get_ok('/explore/products?q=1&view=aggregate&field=product_name&group=category.category_name&group=units_in_stock&measure=count&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('tr.sc-rollup-subtotal[data-rollup-level="1"] form.sc-drilldown-form')
    ->element_exists('tr.sc-rollup-subtotal[data-rollup-level="1"] input[name="filter_field"][value="category.category_name"]')
    ->element_exists_not('tr.sc-rollup-subtotal[data-rollup-level="1"] input[name="filter_field"][value="units_in_stock"]')
    ->element_exists('tr.sc-rollup-detail[data-rollup-level="2"] input[name="filter_field"][value="category.category_name"]')
    ->element_exists('tr.sc-rollup-detail[data-rollup-level="2"] input[name="filter_field"][value="units_in_stock"]')
    ->element_exists('button.sc-drilldown-value[style="--sc-rollup-level:2"]')
    ->content_unlike(qr/View details/i);

$t->get_ok('/explore/products?q=1&view=aggregate&field=product_name&group=category.category_name&group=units_in_stock&measure=count&order=product_name&direction=asc&limit=25&page=2')
    ->status_is(200)
    ->element_exists('tbody tr:first-child.sc-rollup-continued[data-rollup-level="1"][data-rollup-continued="1"]')
    ->content_like(qr{<span class="sc-rollup-continued-label">Value 1 <span>\(continued\)</span></span>})
    ->text_is('tbody tr:first-child .sc-rollup-continued-label > span' => '(continued)')
    ->text_is('tbody tr:first-child .sc-rollup-continued-measure' => '-')
    ->element_exists('tr.sc-rollup-continued form.sc-drilldown-form')
    ->element_exists('tr.sc-rollup-continued button.sc-drilldown-value')
    ->element_exists('tr.sc-rollup-continued input[name="filter_field"][value="category.category_name"]');

my $count_executions_before_grid =
    $TestSelectoComponents::Adapter::COUNT_EXECUTIONS // 0;
$t->get_ok('/explore/products?q=1&view=aggregate&aggregate_grid=1&aggregate_grid_colorize=1&aggregate_grid_color_scale=log&field=product_name&group=category.category_name&group=units_in_stock&measure=count&order=product_name&direction=asc&limit=25&page=2')
    ->status_is(200)
    ->element_exists('[data-sc-aggregate-options]:not([disabled]) input[name="aggregate_grid"][checked]')
    ->element_exists('[data-sc-aggregate-options] input[name="aggregate_grid_colorize"][checked]')
    ->element_exists('[data-sc-aggregate-options] select[name="aggregate_grid_color_scale"] option[value="log"][selected]')
    ->text_is('.sc-grid-heading strong' => 'Aggregate Grid')
    ->text_is('.sc-grid-heading span' => 'Log heat scale')
    ->element_exists('.sc-aggregate-grid-wrap .sc-aggregate-grid')
    ->element_exists('form[data-sc-grid-selection][data-sc-grid-max="50"]')
    ->element_exists('.sc-aggregate-grid input[data-sc-grid-toggle-all]')
    ->element_exists('.sc-aggregate-grid input[data-sc-grid-row-toggle="0"]')
    ->element_exists('.sc-aggregate-grid input[data-sc-grid-column-toggle="0"]')
    ->element_exists('.sc-aggregate-grid td[data-sc-grid-heat] input[name="grid_cell"][data-sc-grid-cell]')
    ->element_exists('.sc-aggregate-grid td.sc-grid-empty-cell input[name="grid_cell"][data-sc-grid-cell]')
    ->element_exists('button[data-sc-grid-apply]')
    ->element_exists_not('.sc-pagination');
is $TestSelectoComponents::Adapter::LAST_DATA_QUERY->limit_value, 10_001,
    'a valid aggregate grid fetches the matrix within the server safety ceiling';
is $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, $count_executions_before_grid,
    'a full aggregate grid avoids a redundant count query';

my $grid_selection_url = Mojo::URL->new('/explore/products');
$grid_selection_url->query([
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => 'category.category_name',
    group => 'units_in_stock',
    measure => 'count',
    grid_cell => encode_json(['Value 1', 'Value 1']),
    grid_cell => encode_json(['Value 2', 'Value 2']),
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
]);
$t->get_ok($grid_selection_url)->status_is(200)
    ->text_is('[data-sc-filter-clause-summary]' => 'Grid selection: 2 areas')
    ->element_exists('[data-sc-filter-clauses]')
    ->element_exists('[data-sc-filter-clause="1"]')
    ->element_exists('[data-sc-filter-clause="2"]')
    ->element_exists('[data-sc-promoted-filter-clause="1"]')
    ->element_exists('[data-sc-promoted-filter-clause="2"]')
    ->element_exists('[data-sc-promoted-filter-clause="1"] [data-sc-promoted-clause-remove][data-filter-clause="1"]')
    ->element_exists('[data-sc-promoted-filter-clause="1"] [data-sc-promoted-filter-condition][data-field="category.category_name"]')
    ->element_exists_not('[data-sc-promoted-filter-clause="1"] [data-sc-promoted-filter-input]')
    ->text_is('[data-sc-promoted-filter-clause="1"] [data-field="category.category_name"] .sc-promoted-filter-pair-value' => '= Value 1')
    ->element_exists('[data-sc-filter-clause="1"] [name="filter_field"][value="category.category_name"]')
    ->element_exists('[data-sc-filter-clause="1"] [name="filter_field"][value="units_in_stock"]')
    ->element_exists('[data-sc-filter-clause="1"] [name="filter_clause"][value="1"]')
    ->element_exists('[data-sc-filter-clause="2"] [name="filter_clause"][value="2"]')
    ->element_exists('[data-sc-filter-clause] input[type="hidden"][name="filter_op"][value="eq"]')
    ->element_exists('[data-sc-filter-condition][data-field="category.category_name"] input[type="hidden"][name="filter_value"][value="Value 1"]')
    ->element_exists_not('[data-sc-filter-clause] select')
    ->content_like(qr/Full rows and columns use one condition/)
    ->content_like(qr/selections use OR/);
is $t->tx->res->dom->find('[data-sc-filter-clause]')->size, 2,
    'two selected grid cells render as two compact alternative cards';
is $t->tx->res->dom->find('[data-sc-filter-condition]')->size, 4,
    'each selected cell displays its governed row and column condition';
is $t->tx->res->dom->find('[data-sc-promoted-filter-clause="1"] [data-sc-promoted-clause-remove]')->size, 1,
    'each compact promoted pair has one remove control for the complete cell';
is $t->tx->res->dom->find('[data-sc-promoted-filter-clause="1"] [data-sc-promoted-filter-condition]')->size, 2,
    'each compact promoted pair keeps both read-only conditions together';

my $grid_axis_selection_url = $t->ua->server->url->clone->path('/explore/products')->query([
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    grid_axis => encode_json({axis => 0, value => 'Value 1'}),
    grid_cell => encode_json(['Value 1', 'Value 1']),
    grid_cell => encode_json(['Value 2', 'Value 2']),
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
]);
$t->get_ok($grid_axis_selection_url)->status_is(200)
    ->element_exists('[data-sc-filter-clause="1"] [name="filter_field"][value="category.category_name"]')
    ->element_exists_not('[data-sc-filter-clause="1"] [name="filter_field"][value="units_in_stock"]')
    ->element_exists('[data-sc-filter-clause="2"] [name="filter_field"][value="units_in_stock"]')
    ->element_exists('[data-sc-promoted-filter-clause="1"] [data-sc-promoted-filter-condition][data-field="category.category_name"]');
is $t->tx->res->dom->find('[data-sc-filter-clause="1"] [data-sc-filter-condition]')->size, 1,
    'a selected full row renders as one compact read-only condition';

$t->get_ok('/explore/products?q=1&view=aggregate&aggregate_grid=1&field=product_name&group=category.category_name&measure=count&order=product_name&direction=asc&limit=25&page=2')
    ->status_is(200)
    ->text_is('.sc-grid-warning' =>
        'Grid view requires exactly two Group By fields and one Aggregate.')
    ->element_exists('.sc-table-wrap:not(.sc-aggregate-grid-wrap)')
    ->element_exists('.sc-pagination');
is $TestSelectoComponents::Adapter::LAST_DATA_QUERY->limit_value, 25,
    'an incompatible grid shape retains normal aggregate pagination';

$t->get_ok('/explore/products?q=1&view=aggregate&field=product_name&field_alias=&field_format=&group=unit_price&group_alias=Price+band&group_format=buckets&group_bucket_ranges=0-10%2C+11%2B&group_prefix_length=2&group_exclude_articles=1&measure=count&measure_alias=Products&measure_function=count&measure_bucket_ranges=&measure_ignore_nulls=0&measure=total_price&measure_alias=Price+counts&measure_function=buckets&measure_bucket_ranges=0-10%2C+11%2B&measure_ignore_nulls=0&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="count"] input[name="measure_alias"][value="Products"]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] select[name="measure_function"] option[value="buckets"][selected]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] input[name="measure_bucket_ranges"][value="0-10, 11+"]')
    ->element_exists('[data-sc-picker-kind="group"] [data-field="unit_price"] input[name="group_bucket_ranges"][value="0-10, 11+"]')
    ->content_like(qr/Price counts: 0-10/);

$t->get_ok('/explore/products?q=1&view=graph&chart_type=area&graph_show_table=1&field=product_name&group=category.category_name&measure=count&measure_alias=&measure_function=count&measure_series_id=volume&measure_chart_type=bar&measure_axis=auto&measure_stack=&measure_color=&measure_transform=&measure_transform_window=&measure=total_price&measure_alias=Smoothed+price&measure_function=sum&measure_series_id=revenue&measure_chart_type=line&measure_axis=auto&measure_stack=&measure_color=%23112233&measure_transform=moving_average&measure_transform_window=2&order=product_name&direction=asc&limit=25&page=3')
    ->status_is(200)
    ->element_exists('.sc-chart[aria-label="Selected measures by selected groups"][aria-busy="true"]')
    ->element_exists('[data-sc-graph-options]:not([disabled]) select[name="chart_type"] option[value="area"][selected]')
    ->element_exists('[data-sc-graph-options] input[name="graph_show_table"][checked]')
    ->text_is('[data-sc-limit-label]' => 'Points')
    ->element_exists('[data-sc-page-control][hidden] input[name="page"][value="1"][disabled]')
    ->element_exists('[data-sc-chart][data-chart-type="area"][data-chart-data] canvas[role="img"]')
    ->element_exists('head > noscript')
    ->element_exists_not('[data-sc-chart] noscript')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] select[name="measure_transform"] option[value="moving_average"][selected]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] input[name="measure_transform_window"][value="2"]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] select[name="measure_ignore_nulls"] option[value="auto"][selected]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] input[name="measure_color"][value="#112233"]')
    ->element_exists('[data-sc-picker-kind="measure"] [data-field="total_price"] input[type="color"][value="#112233"]:not([disabled])')
    ->element_exists('form[data-sc-graph-drilldown="0"] input[name="view"][value="detail"]')
    ->element_exists('form[data-sc-graph-drilldown="0"] input[name="page"][value="1"]')
    ->element_exists_not('.sc-pagination')
    ->content_like(qr/Product count/)
    ->content_like(qr/Total price/);

my $chart_data = decode_json(
    $t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data')
);
is_deeply $chart_data->{labels}, ['Value 1', 'Value 2'],
    'chart labels come from the selected group values';
is_deeply [map { $_->{label} } @{$chart_data->{datasets}}],
    ['Product count', 'Smoothed price'], 'transformed series retains its configured chart label';
is_deeply $chart_data->{datasets}[0]{data}, [2, 4],
    'chart dataset carries numeric measure values';
is_deeply $chart_data->{datasets}[1]{data}, [10, 15],
    'server-side moving average produces the displayed series values';
is_deeply $chart_data->{datasets}[1]{rawData}, [10, 20],
    'transformed chart datasets preserve their raw aggregate values';
is_deeply $chart_data->{datasets}[1]{transforms}, ['moving_average'],
    'graph payload describes the applied analytical transform';
is $chart_data->{datasets}[1]{borderColor}, '#112233',
    'configured series color is emitted without palette replacement';
is $chart_data->{datasets}[1]{colorAuto}, 0,
    'custom series color is marked as non-automatic';
is_deeply [map { $_->{seriesId} } @{$chart_data->{datasets}}],
    ['volume', 'revenue'], 'chart datasets retain stable series identifiers';
is_deeply [map { $_->{scType} } @{$chart_data->{datasets}}],
    ['bar', 'line'], 'a graph frame can mix configured bar and line series';
is_deeply [map { $_->{yAxisID} } @{$chart_data->{datasets}}],
    ['y', 'y1'], 'incompatible units are assigned to opposite Y axes';
is $chart_data->{axes}{y}{label}, 'Count', 'left axis describes its count unit';
is $chart_data->{axes}{y1}{label}, 'USD', 'right axis describes its currency unit';
is $t->tx->res->dom->at('.sc-chart + .sc-table-wrap thead th:last-child')->text,
    'Total price', 'raw graph table labels the aggregate value it actually presents';

$t->get_ok('/explore/products?q=1&view=graph&chart_type=line' .
    '&field=product_name&group=category.category_name&group=product_name' .
    '&graph_series_group=product_name&measure=count&measure_alias=Products' .
    '&measure_function=count&order=product_name&direction=asc&limit=25&page=1')
    ->status_is(200)
    ->element_exists('[data-sc-graph-options] select[name="graph_series_group"] ' .
        'option[value="product_name"][selected]')
    ->element_exists('form[data-sc-graph-drilldown="2"]')
    ->element_exists('form[data-sc-graph-drilldown="3"]');
my $breakout_chart_data = decode_json(
    $t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data')
);
is_deeply $breakout_chart_data->{labels}, ['Value 1', 'Value 2'],
    'a series breakout removes that group from the horizontal-axis labels';
is_deeply [map { $_->{label} } @{$breakout_chart_data->{datasets}}],
    ['=2+2', 'Value 2'],
    'each breakout group value becomes a separately labelled dataset';
is_deeply $breakout_chart_data->{datasets}[0]{data}, [2, undef],
    'the first breakout series aligns values to the shared horizontal axis';
is_deeply $breakout_chart_data->{datasets}[1]{data}, [undef, 4],
    'the second breakout series preserves gaps rather than inventing zero values';
is_deeply $breakout_chart_data->{datasets}[0]{drilldownIndices}, [0, undef],
    'breakout points retain their full row-specific drill-down target';
is_deeply $breakout_chart_data->{axisDrilldownIndices}, [2, 3],
    'horizontal-axis labels use drill-downs that exclude the breakout group';

for my $chart_type (qw(bar horizontal_bar stacked_bar line pie doughnut scatter)) {
    $t->get_ok('/explore/products?q=1&view=graph&chart_type=' . $chart_type .
        '&field=product_name&group=category.category_name&measure=count' .
        '&order=product_name&direction=asc&limit=25&page=1')
        ->status_is(200)
        ->element_exists('[data-sc-chart][data-chart-type="' . $chart_type . '"]')
        ->element_exists('select[name="chart_type"] option[value="' . $chart_type . '"][selected]')
        ->element_exists('[data-sc-graph-options] input[name="graph_show_table"]:not([checked])')
        ->element_exists_not('.sc-chart + .sc-table-wrap')
        ->element_exists_not('.sc-pagination');
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

$t->get_ok($export_url . '&format=Excel')
    ->status_is(200)
    ->content_type_like(qr{application/vnd\.openxmlformats-officedocument\.spreadsheetml\.sheet})
    ->header_like('Content-Disposition' => qr/products-export\.xlsx/);

$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({
    headers => {},
    selecto_request_id => 'selecto-test-1',
    q => 1,
    view => 'graph',
    field => ['product_name', 'unit_price'],
    group => ['category.category_name'],
    measure => 'total_price',
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
})})->message_ok;
is_deeply \@TestSelectoComponents::WEBSOCKET_MESSAGE_CLEANUPS, ['products'],
    'host resource cleanup runs after a WebSocket query completes';
my $message = decode_json($t->message->[1]);
ok !exists($message->{'HX-Request-ID'}), 'WebSocket response uses the htmx 4 final message contract';
is $message->{target}, '#selecto-surface-products', 'WebSocket response targets the explorer surface';
is $message->{swap}, 'outerHTML', 'WebSocket response replaces the surface without replacing the connection';
like $message->{content}, qr/Graph results/, 'WebSocket returns server-rendered graph content';
like $message->{selecto}{url}, qr{\A/explore/products\?}, 'WebSocket response supplies the canonical URL';
like $message->{selecto}{url}, qr/(?:\?|&)view=graph(?:&|\z)/, 'canonical URL records the graph view';
like $message->{selecto}{url}, qr/(?:\?|&)chart_type=bar(?:&|\z)/,
    'canonical URL records the selected chart type';
is $message->{selecto}{request_id}, 'selecto-test-1',
    'WebSocket response echoes the validated client request identifier';
$t->finish_ok;

$t->get_ok($message->{selecto}{url})
    ->status_is(200)
    ->content_like(qr/Graph results/);

$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({
    headers => {},
    q => 1,
    view => 'detail',
    field => ['unit_price', 'product_name', 'category.category_name'],
    group => ['category.category_name'],
    measure => 'count',
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
})})->message_ok;
is_deeply \@TestSelectoComponents::WEBSOCKET_MESSAGE_CLEANUPS,
    [qw(products products)],
    'host resource cleanup runs independently for the next WebSocket query';
my $reordered = decode_json($t->message->[1]);
like $reordered->{content}, qr{<th scope="col">Unit Price</th><th scope="col">Product Name</th>}s,
    'server-rendered table follows the submitted Set order';
cmp_ok index($reordered->{selecto}{url}, 'field=unit_price'), '<',
    index($reordered->{selecto}{url}, 'field=product_name'),
    'canonical URL preserves selected column order';
my $count_executions_before_paging = $TestSelectoComponents::Adapter::COUNT_EXECUTIONS;
$t->send_ok({text => encode_json({
    headers => {},
    render_scope => 'results',
    reuse_count => 1,
    q => 1,
    view => 'detail',
    field => ['unit_price', 'product_name', 'category.category_name'],
    group => ['category.category_name'],
    measure => 'count',
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 2,
})})->message_ok;
my $paged = decode_json($t->message->[1]);
is $paged->{target}, '#selecto-results-products',
    'pagination replaces only the results fragment';
unlike $paged->{content}, qr/data-sc-builder-shell/,
    'results-only pagination does not retransmit the field builder';
is $paged->{selecto}{performance}{results_only}, 1,
    'WebSocket metadata identifies the smaller results update';
is $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, $count_executions_before_paging,
    'pagination reuses the governed exact count on the same connection';
$t->finish_ok;

$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({
    headers => {},
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
})})->message_ok;
my $filtered = decode_json($t->message->[1]);
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
    headers => {},
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
})})->message_ok;
my $private_message = decode_json($t->message->[1]);
is $private_message->{selecto}{url}, '/explore/private-products',
    'private WebSocket response supplies only the path';
unlike $private_message->{selecto}{url}, qr/secret-medical-value|[?&]/,
    'private canonical URL cannot contain query state or sensitive filter values';
like $private_message->{content}, qr/value="secret-medical-value"/,
    'private query state remains editable in the server-rendered surface';
$t->finish_ok;

is_deeply(
    Selecto::Components::Renderer::Results::_pagination_pages(20, 42),
    [1, 18, 19, 20, 21, 22, 42],
    'pagination keeps first, last, and neighboring pages for a large result set',
);

done_testing;
