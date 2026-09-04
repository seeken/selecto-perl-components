use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::DateShortcut ();
use Selecto::Components::Explorer ();
use Selecto::Components::QueryBuilder;
use Selecto::Components::Renderer ();
use Selecto::Components::State;
use Selecto::PostgreSQL;

my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'products'
);
my $domain = TestSelectoComponents::domain();
my $dbh = bless {}, 'TestSelectoComponents::CompileDBH';
my $postgresql = Selecto::PostgreSQL->new(dbh => $dbh);

my $unsafe_link_contract = $domain->contract;
$unsafe_link_contract->{source}{columns}{product_name}{link}{url_template}
    = 'javascript:alert(1)?id={{id}}';
my $unsafe_link_domain = Selecto::Domain->parse($unsafe_link_contract, strict => 1);
eval { $config->field_catalog($unsafe_link_domain) };
like $@, qr/safe application path/, 'external or executable object-link templates are rejected';

my $unknown_link_id_contract = $domain->contract;
$unknown_link_id_contract->{source}{columns}{product_name}{link}{id_field} = 'missing_id';
my $unknown_link_id_domain = Selecto::Domain->parse($unknown_link_id_contract, strict => 1);
eval { $config->field_catalog($unknown_link_id_domain) };
like $@, qr/is not queryable/, 'object links cannot select an id outside the governed domain';

my $vin_format_contract = $domain->contract;
$vin_format_contract->{source}{columns}{product_name}{html_format} = 'vin_last_six';
my $vin_format_domain = Selecto::Domain->parse($vin_format_contract, strict => 1);
is $config->field_map($vin_format_domain)->{product_name}{html_format}, 'vin_last_six',
    'canonical column HTML formatting enters the governed field catalog';
my $vin_format_state = Selecto::Components::State->from_input(
    $config, $vin_format_domain,
    {q => 1, view => 'detail', field => ['product_name'], limit => 25, page => 1},
);
my $vin_format_result = Selecto::Components::QueryBuilder->build(
    $config, $vin_format_domain, $vin_format_state,
);
is $vin_format_result->{columns}[0]{html_format}, 'vin_last_six',
    'detail query columns retain their HTML-only formatter';
is Selecto::Components::Renderer::_html_display(
    $vin_format_result->{columns}[0], '1HGCM82633A004352',
), '1HGCM82633A<strong class="sc-vin-suffix">004352</strong>',
    'a 17-character VIN renders with its final six characters bold';
is Selecto::Components::Renderer::_html_display(
    $vin_format_result->{columns}[0], 'VIN-TOO-SHORT',
), 'VIN-TOO-SHORT', 'a non-17-character VIN is left intact';

my $unknown_html_format_contract = $domain->contract;
$unknown_html_format_contract->{source}{columns}{product_name}{html_format} = 'raw_html';
my $unknown_html_format_domain = Selecto::Domain->parse(
    $unknown_html_format_contract, strict => 1,
);
eval { $config->field_catalog($unknown_html_format_domain) };
like $@, qr/must be vin_last_six/,
    'unrecognized domain HTML formatters are rejected instead of rendering raw HTML';

my $curated_contract = $domain->contract;
$curated_contract->{source}{columns}{id}{internal} = 1;
$curated_contract->{source}{columns}{product_name}{label} = 'Product';
$curated_contract->{schemas}{categories}{columns}{id}{internal} = 1;
my $curated_domain = Selecto::Domain->parse($curated_contract, strict => 1);
ok !$config->field_map($curated_domain)->{id},
    'internal root fields are omitted from the public field catalog';
ok !$config->field_map($curated_domain)->{'category.id'},
    'internal association fields are omitted from the public field catalog';
is $config->field_map($curated_domain)->{product_name}{label}, 'Product',
    'canonical labels replace generated picker labels';
is $config->query_field_map($curated_domain)->{id}{type}, 'integer',
    'internal fields remain available for governed query dependencies';

my $semantic_order_contract = $domain->contract;
$semantic_order_contract->{source}{columns}{product_name}{label} = 'Zulu semantic label';
$semantic_order_contract->{source}{columns}{unit_price}{label} = 'Alpha semantic label';
my $semantic_order_domain = Selecto::Domain->parse($semantic_order_contract, strict => 1);
my $semantic_order_catalog = $config->field_catalog($semantic_order_domain);
my %semantic_position;
@semantic_position{map { $_->{path} } @$semantic_order_catalog} = (0 .. $#$semantic_order_catalog);
cmp_ok $semantic_position{unit_price}, '<', $semantic_position{product_name},
    'field catalogs sort by semantic label instead of underlying field name';

my $curated_state = Selecto::Components::State->from_input(
    $config, $curated_domain,
    {
        q => 1, view => 'detail',
        field => ['action:add_product_note', 'product_name'],
        limit => 25, page => 1,
    },
);
my $curated_result = Selecto::Components::QueryBuilder->build(
    $config, $curated_domain, $curated_state,
);
is $curated_result->{action_key}, '__selecto_action_target',
    'an internal primary key still backs selected-row actions';
is $curated_result->{columns}[1]{link_key}, '__selecto_action_target',
    'an internal primary key still backs governed object links';

my $detail_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => [
        'action:add_product_note', 'product_name', 'category.category_name',
        'unit_price', 'action:mark_for_review',
    ],
    group => ['category.category_name'],
    measure => 'count',
    filter_field => ['unit_price', 'category.category_name'],
    filter_op => ['gte', 'in'],
    filter_value => ['12.50', 'Tools,Produce'],
    order => 'unit_price',
    direction => 'desc',
    limit => 25,
    page => 2,
});
my $detail = Selecto::Components::QueryBuilder->build($config, $domain, $detail_state);
my $detail_statement = $postgresql->compile($domain, $detail->{query});
like $detail_statement->sql, qr/INNER JOIN "categories"/, 'relationship field produces configured join';
like $detail_statement->sql, qr/"s0"\."unit_price" >= \$1/, 'filter value uses a placeholder';
like $detail_statement->sql, qr/IN \(\$2, \$3\)/, 'membership values use separate placeholders';
like $detail_statement->sql, qr/ORDER BY "s0"\."unit_price" DESC/, 'sort field and direction are governed';
like $detail_statement->sql, qr/LIMIT 25 OFFSET 25\z/, 'page compiles to bounded limit and offset';
is_deeply $detail_statement->params, ['12.50', 'Tools', 'Produce'], 'values remain out of SQL';
is_deeply $detail_statement->columns,
    [qw(product_name category__category_name unit_price __selecto_action_target)],
    'detail aliases are stable and include the hidden selected-row action target';
is $detail->{columns}[1]{link_key}, '__selecto_action_target',
    'a linked display column reuses an already selected hidden object id';
is $detail->{columns}[1]{link}{url_template}, '/products/view?id={{id}}',
    'the query result retains the governed object link template';
is_deeply [map { $_->{key} } @{$detail->{columns}}],
    [qw(
        __selecto_action_column_add_product_note product_name
        category__category_name unit_price __selecto_action_column_mark_for_review
    )],
    'selected action pseudo-columns retain their requested display order';
is $detail->{action_key}, '__selecto_action_target',
    'the detail result identifies its hidden action target';
is_deeply $detail->{action_ids}, [qw(add_product_note mark_for_review)],
    'the detail result identifies each independent selected action column';

my $export_detail = Selecto::Components::QueryBuilder->build(
    $config, $domain, $detail_state, {paginate => 0},
);
my $export_detail_statement = $postgresql->compile($domain, $export_detail->{query});
unlike $export_detail_statement->sql, qr/\b(?:LIMIT|OFFSET)\b/,
    'an all-row detail export preserves the query without pagination';
is_deeply $export_detail_statement->params, ['12.50', 'Tools', 'Produce'],
    'an all-row detail export preserves governed filter bindings';

my $action_only_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'action:add_product_note', measure => 'count',
    limit => 25, page => 1,
});
my $action_only = Selecto::Components::QueryBuilder->build(
    $config, $domain, $action_only_state,
);
my $action_only_statement = $postgresql->compile($domain, $action_only->{query});
is_deeply $action_only_statement->columns, ['__selecto_action_target'],
    'an action-only detail view queries only its hidden governed target key';
like $action_only_statement->sql, qr/ORDER BY "s0"\."id" ASC/,
    'an action-only detail view remains deterministically ordered';

my $grouped_action_only_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'action:build_shipments', measure => 'count',
    limit => 25, page => 1,
});
my $grouped_action_only = Selecto::Components::QueryBuilder->build(
    $config, $domain, $grouped_action_only_state,
);
my $grouped_action_only_statement = $postgresql->compile(
    $domain, $grouped_action_only->{query},
);
is_deeply $grouped_action_only_statement->columns, [
    qw(
        __selecto_action_target
        build_shipments_eligible
        __selecto_action_build_shipments_stock
    ),
], 'a grouped action fetches its SQL eligibility and declared hidden row detail';
is $grouped_action_only->{action_eligibility_fields}{build_shipments},
    'build_shipments_eligible',
    'grouped action eligibility retains its renderer mapping';
is_deeply $grouped_action_only->{action_row_details}{build_shipments}, [{
    id => 'stock', label => 'Stock', key => '__selecto_action_build_shipments_stock',
}], 'grouped action row details retain their renderer mapping';

my $linked_detail_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'product_name', measure => 'count',
    order => 'product_name', limit => 25, page => 1,
});
my $linked_detail = Selecto::Components::QueryBuilder->build(
    $config, $domain, $linked_detail_state,
);
my $linked_detail_statement = $postgresql->compile($domain, $linked_detail->{query});
is_deeply $linked_detail_statement->columns, [qw(product_name __selecto_link_id)],
    'a linked name automatically fetches its object id as a hidden query column';
is $linked_detail->{columns}[0]{link_key}, '__selecto_link_id',
    'the visible linked name references its hidden object id';

my $row_click_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'unit_price', measure => 'count',
    row_click_action => 'open_product', order => 'unit_price', limit => 25, page => 1,
});
my $row_click_detail = Selecto::Components::QueryBuilder->build(
    $config, $domain, $row_click_state,
);
my $row_click_statement = $postgresql->compile($domain, $row_click_detail->{query});
is_deeply $row_click_statement->columns, [
    qw(unit_price __selecto_row_click_id __selecto_row_click_product_name),
], 'row actions automatically fetch their missing required fields as hidden columns';
is_deeply $row_click_detail->{row_click_fields}, [
    {field => 'id', key => '__selecto_row_click_id'},
    {field => 'product_name', key => '__selecto_row_click_product_name'},
], 'row actions retain the governed field-to-result mapping used by the renderer';
is $row_click_detail->{row_click_action}{id}, 'open_product',
    'the selected validated row action reaches result metadata';

my $library_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_library_view => 'low_stock_products',
    query_library_segment => 'premium',
    query_library_param_name => ['threshold', 'minimum_price'],
    query_library_param_value => ['8', '25.50'],
    view => 'detail',
    limit => 25,
    page => 1,
});
my $library_result = Selecto::Components::QueryBuilder->build(
    $config, $domain, $library_state,
);
my $library_statement = $postgresql->compile($domain, $library_result->{query});
like $library_statement->sql, qr/"s0"\."units_in_stock" < \$1/,
    'a named view segment compiles as a governed query constraint';
like $library_statement->sql, qr/"s0"\."unit_price" >= \$2/,
    'additional named segments compose with the named view';
is_deeply $library_statement->params, [8, '25.50'],
    'query-library values remain bound and typed';
is_deeply $library_result->{query}->applied_query_library->{segments},
    [qw(low_stock premium)], 'component-built queries retain named-segment provenance';

my $aggregate_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'graph',
    field => ['product_name'],
    group => ['category.category_name'],
    measure => 'total_price',
    filter_field => 'unit_price',
    filter_op => 'gte',
    filter_value => '12.50',
    order => 'product_name',
    direction => 'asc',
    limit => 10,
    page => 1,
});
my $aggregate = Selecto::Components::QueryBuilder->build($config, $domain, $aggregate_state);
my $aggregate_statement = $postgresql->compile($domain, $aggregate->{query});
like $aggregate_statement->sql, qr/SUM\("s0"\."unit_price"\) AS "total_price"/, 'configured aggregate compiles';
like $aggregate_statement->sql, qr/GROUP BY "j_category"\."category_name"/, 'configured group compiles';
like $aggregate_statement->sql, qr/WHERE "s0"\."unit_price" >= \$1/,
    'aggregate queries apply the configured filters before grouping';
is_deeply $aggregate_statement->params, ['12.50'],
    'aggregate filter values remain bound parameters';
ok $aggregate->{graph}, 'graph uses aggregate query with graph rendering metadata';

my $star_contract = $domain->contract;
$star_contract->{joins}{category} = {
    type => 'star_dimension',
    name => 'Category',
    display_field => 'category_name',
    dimension_key => 'category_id',
};
my $star_domain = Selecto::Domain->parse($star_contract, strict => 1);
my $star_map = $config->field_map($star_domain);
is $star_map->{category_id}{label}, 'Category ID',
    'a star dimension clearly labels its raw key as an ID';
is $star_map->{'category.category_name'}{label}, 'Category',
    'a star dimension keeps its display value semantic label concise';
is $star_map->{category_id}{dimension}{display_field}, 'category.category_name',
    'a star join decorates its fact key with the dimension display field';
is $star_map->{'category.category_name'}{dimension}{key_field}, 'category_id',
    'the dimension display field points back to its stable fact key';

my $star_state = Selecto::Components::State->from_input($config, $star_domain, {
    q => 1,
    view => 'aggregate',
    field => 'product_name',
    group => 'category_id',
    measure => 'count',
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
});
ok $star_state->valid, 'a fact key backed by a star dimension is a valid group';
my $star_aggregate = Selecto::Components::QueryBuilder->build(
    $config, $star_domain, $star_state,
);
my $star_statement = $postgresql->compile($star_domain, $star_aggregate->{query});
like $star_statement->sql,
    qr/LEFT JOIN "categories" AS "j_category"/,
    'a star aggregate preserves facts that have no matching dimension row';
like $star_statement->sql,
    qr/CASE WHEN GROUPING\("s0"\."category_id"\) = 1 THEN NULL ELSE MIN\("j_category"\."category_name"\) END AS "category_id"/,
    'a star aggregate selects the descriptive name for display';
like $star_statement->sql, qr/GROUP BY ROLLUP \("s0"\."category_id"\)/,
    'a star aggregate groups by the stable dimension ID';
like $star_statement->sql,
    qr/"s0"\."category_id" AS "__selecto_dimension_key_category_id"/,
    'a star aggregate carries its hidden drill-down key';
like $star_statement->sql, qr/ORDER BY 4 DESC, 1 ASC NULLS LAST/,
    'star dimension names sort alphabetically below the grand total';
is $star_aggregate->{columns}[0]{label}, 'Category',
    'the configured dimension name labels the visible group';
is $star_aggregate->{columns}[0]{type}, 'string',
    'the visible star group uses the display field type';

my $star_records = [{
    category_id => 'Tools',
    __selecto_dimension_key_category_id => 7,
    __selecto_rollup_grouping => 0,
    __selecto_rollup_level => 1,
    count => 3,
}];
my $star_drilldowns = Selecto::Components::Explorer::_drilldowns(
    $star_state, $star_aggregate, $star_records,
);
my %star_drilldown = @{$star_drilldowns->[0][0]};
is $star_drilldown{filter_field}, 'category_id',
    'clicking a displayed dimension name filters its fact key';
is $star_drilldown{filter_value}, 7,
    'the star drill-down submits the hidden ID rather than the displayed name';
is $star_drilldown{filter_group}, 0,
    'the ID drill-down is a direct field predicate, not a formatted-label predicate';
is $star_drilldown{filter_promote_field}, 'category_id',
    'star-dimension drill-down filters are automatically promoted';

my $star_grid_state = Selecto::Components::State->from_input($config, $star_domain, {
    q => 1,
    view => 'aggregate',
    aggregate_grid => 1,
    field => 'product_name',
    group => ['category_id', 'units_in_stock'],
    measure => 'count',
    order => 'product_name',
});
my $star_grid_built = Selecto::Components::QueryBuilder->build(
    $config, $star_domain, $star_grid_state,
);
my $star_grid_records = [{
    category_id => 'Tools',
    __selecto_dimension_key_category_id => 7,
    units_in_stock => 1,
    count => 3,
    __selecto_rollup_level => 2,
}];
my $star_grid_data = Selecto::Components::Explorer::_aggregate_grid_data(
    $star_grid_state,
    $star_grid_built,
    $star_grid_records,
    Selecto::Components::Explorer::_drilldowns(
        $star_grid_state, $star_grid_built, $star_grid_records,
    ),
);
my ($star_grid_cell) = values %{$star_grid_data->{cells}{$star_grid_data->{rows}[0]{key}}};
is_deeply $star_grid_cell->{selection_values}, [7, 1],
    'grid selection carries a star dimension key instead of its display label';
my $star_grid_detail = Selecto::Components::State->from_input($config, $star_domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category_id', 'units_in_stock'],
    measure => 'count',
    grid_cell => '[7,1]',
    order => 'product_name',
});
ok $star_grid_detail->valid,
    'a selected star-dimension grid cell becomes valid detail state';
is_deeply [map { $_->{field} } @{$star_grid_detail->filters}],
    ['category_id', 'units_in_stock'],
    'star-dimension grid filters target the stable fact key and second axis';

my $duplicate_star_state = Selecto::Components::State->from_input(
    $config, $star_domain, {
        q => 1, view => 'aggregate', field => 'product_name',
        group => ['category_id', 'category.category_name'],
        measure => 'count', limit => 25, page => 1,
    },
);
ok !$duplicate_star_state->valid,
    'the key and display sides of one star dimension cannot be grouped twice';
like join(' ', @{$duplicate_star_state->errors}), qr/star dimension only once/,
    'duplicate star groups fail with an actionable validation message';

my $export_aggregate = Selecto::Components::QueryBuilder->build(
    $config, $domain, $aggregate_state, {paginate => 0},
);
my $export_aggregate_statement = $postgresql->compile(
    $domain, $export_aggregate->{query},
);
unlike $export_aggregate_statement->sql, qr/\b(?:LIMIT|OFFSET)\b/,
    'an all-row aggregate export preserves grouping without pagination';
like $export_aggregate_statement->sql, qr/WHERE "s0"\."unit_price" >= \$1/,
    'an all-row aggregate export retains the configured filters';

my $grid_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    aggregate_grid => 1,
    aggregate_grid_colorize => 1,
    aggregate_grid_color_scale => 'linear',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    order => 'product_name',
    limit => 25,
    page => 3,
});
my $grid_result = Selecto::Components::QueryBuilder->build(
    $config, $domain, $grid_state,
);
my $grid_statement = $postgresql->compile($domain, $grid_result->{query});
ok $grid_result->{aggregate_grid},
    'two groups and one resulting measure enable aggregate grid rendering';
like $grid_statement->sql, qr/\bLIMIT 10001\z/,
    'aggregate grid queries include one sentinel row beyond the display ceiling';
unlike $grid_statement->sql, qr/\bOFFSET\b/,
    'aggregate grids are bounded independently of the requested result page';

my $incompatible_grid_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    aggregate_grid => 1,
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    limit => 25,
    page => 2,
});
my $incompatible_grid_result = Selecto::Components::QueryBuilder->build(
    $config, $domain, $incompatible_grid_state,
);
my $incompatible_grid_statement = $postgresql->compile(
    $domain, $incompatible_grid_result->{query},
);
ok !$incompatible_grid_result->{aggregate_grid},
    'an incompatible aggregate shape falls back to the rollup table';
like $incompatible_grid_statement->sql, qr/LIMIT 25 OFFSET 25\z/,
    'an incompatible grid request retains ordinary aggregate pagination';

my $multi_measure_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    field => 'product_name',
    group => 'unit_price',
    group_alias => 'Price band',
    group_format => 'buckets',
    group_bucket_ranges => '0-10, 11+',
    measure => ['count', 'total_price'],
    measure_alias => ['Products', 'Price counts'],
    measure_function => ['count', 'buckets'],
    measure_bucket_ranges => ['', '0-10, 11+'],
    measure_ignore_nulls => [0, 0],
    order => 'product_name',
    limit => 25,
    page => 1,
});
my $multi_measure = Selecto::Components::QueryBuilder->build(
    $config, $domain, $multi_measure_state
);
my $multi_measure_statement = $postgresql->compile($domain, $multi_measure->{query});
like $multi_measure_statement->sql, qr/COUNT\(\*\) AS "count"/,
    'the first selected measure compiles independently';
like $multi_measure_statement->sql,
    qr/COUNT\(CASE WHEN "s0"\."unit_price" >= \$7 AND "s0"\."unit_price" <= \$8 THEN 1 END\) AS "total_price__bucket_1"/,
    'a numeric measure bucket expands to a governed conditional count column';
like $multi_measure_statement->sql, qr/GROUP BY ROLLUP \(CASE WHEN "s0"\."unit_price" >=/,
    'numeric group buckets compile as governed rollup expressions';
like $multi_measure_statement->sql, qr/GROUPING\(CASE WHEN .*?\) AS "__selecto_rollup_grouping"/,
    'aggregate rollup carries governed grouping metadata for hierarchy rendering';
like $multi_measure_statement->sql,
    qr/\ASELECT \* FROM \(SELECT .*\) AS rollupfix ORDER BY 5 DESC, 1 ASC NULLS LAST LIMIT 25 OFFSET 0\z/s,
    'one-level bucket rollups sort the grand total separately from data NULL buckets';
unlike $multi_measure_statement->sql, qr/ORDER BY CASE/,
    'the rollup outer sort does not rebuild the parameterized bucket expression';
is scalar(@{$multi_measure_statement->params}), 9,
    'ordered bucket rollups do not duplicate their bound bucket parameters';
is_deeply [map { $_->{label} } @{$multi_measure->{columns}}],
    ['Price band', 'Products', 'Price counts: 0-10', '11+'],
    'multiple measures and expanded bucket columns preserve configured display order';

my $column_measure_config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'column_products', measures => []
);
my $column_measure_state = Selecto::Components::State->from_input(
    $column_measure_config, $domain, {
        q => 1,
        view => 'aggregate',
        field => 'product_name',
        group => 'category.category_name',
        measure => ['unit_price', 'category.category_name'],
        measure_alias => ['', 'Named categories'],
        measure_function => ['sum', 'count_distinct'],
        order => 'product_name',
        limit => 25,
        page => 1,
    }
);
my $column_measure_result = Selecto::Components::QueryBuilder->build(
    $column_measure_config, $domain, $column_measure_state
);
my $column_measure_statement = $postgresql->compile(
    $domain, $column_measure_result->{query}
);
like $column_measure_statement->sql, qr/SUM\("s0"\."unit_price"\) AS "unit_price"/,
    'a numeric domain column compiles with its selected aggregate function';
like $column_measure_statement->sql,
    qr/COUNT\(DISTINCT "j_category"\."category_name"\) AS "measure__category__category_name"/,
    'a relationship column compiles as a governed aggregate with a safe result alias';
is_deeply [map { $_->{label} } @{$column_measure_result->{columns}}],
    [
        $column_measure_config->field_map($domain)->{'category.category_name'}{label},
        'Unit Price Sum', 'Named categories'
    ],
    'column-derived aggregates use function-aware labels and configured aliases';

my $formatted_detail_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['created_on', 'product_name'],
    field_alias => ['Created month', ''],
    field_format => ['month', ''],
    group => 'created_on',
    group_alias => '',
    group_format => 'month',
    measure => 'count',
    order => ['created_on', 'product_name'],
    direction => ['desc', 'asc'],
    limit => 25,
    page => 1,
});
my $formatted_detail = Selecto::Components::QueryBuilder->build(
    $config, $domain, $formatted_detail_state
);
my $formatted_detail_statement = $postgresql->compile($domain, $formatted_detail->{query});
like $formatted_detail_statement->sql,
    qr/TO_CHAR\("s0"\."created_on", 'YYYY-MM'\) AS "created_on"/,
    'detail date format compiles through governed expression intent';
like $formatted_detail_statement->sql,
    qr/ORDER BY "s0"\."created_on" DESC, "s0"\."product_name" ASC/,
    'detail query compiles multiple ordered sort fields';
is $formatted_detail->{columns}[0]{label}, 'Created month',
    'configured detail label is presentation metadata';

my $repeated_detail_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['created_on', 'created_on'],
    field_alias => ['Created date', 'Created time'],
    field_format => ['day', 'time'],
    filter_field => ['created_on', 'created_on'],
    filter_op => ['gte', 'lt'],
    filter_value => ['2026-08-01', '2026-09-01'],
    order => 'created_on',
    limit => 25,
    page => 1,
});
ok $repeated_detail_state->valid,
    'repeated detail columns and repeated field predicates form valid state';
my $repeated_detail = Selecto::Components::QueryBuilder->build(
    $config, $domain, $repeated_detail_state,
);
my $repeated_detail_statement = $postgresql->compile($domain, $repeated_detail->{query});
like $repeated_detail_statement->sql,
    qr/TO_CHAR\("s0"\."created_on", 'YYYY-MM-DD'\) AS "created_on".*TO_CHAR\("s0"\."created_on", 'HH24:MI:SS'\) AS "created_on__2"/s,
    'repeated formatted columns compile with unique result aliases';
like $repeated_detail_statement->sql,
    qr/\("s0"\."created_on" >= \$1\) AND \("s0"\."created_on" < \$2\)/,
    'repeated filters compile as independent AND predicates';
is_deeply $repeated_detail_statement->params, ['2026-08-01', '2026-09-01'],
    'repeated filters preserve their independently bound values';
is_deeply [map { $_->{label} } @{$repeated_detail->{columns}}],
    ['Created date', 'Created time'],
    'repeated columns retain independent labels';

my $formatted_aggregate_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    field => ['created_on', 'product_name'],
    field_alias => ['', ''],
    field_format => ['', ''],
    group => 'created_on',
    group_alias => 'Month',
    group_format => 'month',
    measure => 'count',
    order => 'created_on',
    direction => 'asc',
    limit => 25,
    page => 1,
});
my $formatted_aggregate = Selecto::Components::QueryBuilder->build(
    $config, $domain, $formatted_aggregate_state
);
my $formatted_aggregate_statement = $postgresql->compile($domain, $formatted_aggregate->{query});
like $formatted_aggregate_statement->sql,
    qr/GROUP BY ROLLUP \(TO_CHAR\("s0"\."created_on", 'YYYY-MM'\)\)/,
    'aggregate date configuration defines the SQL rollup bucket';
is $formatted_aggregate->{columns}[0]{label}, 'Month',
    'aggregate group label uses its independent configuration';
my $formatted_drilldowns = Selecto::Components::Explorer::_drilldowns(
    $formatted_aggregate_state,
    $formatted_aggregate,
    [{created_on => '2026-08', __selecto_rollup_level => 1}],
);
my %formatted_drilldown = @{$formatted_drilldowns->[0][0]};
is $formatted_drilldown{filter_group}, 1,
    'formatted aggregate drill-downs retain their governed grouping expression';
is $formatted_drilldown{filter_promote_field}, 'created_on',
    'formatted aggregate drill-down filters are automatically promoted';

my $drilldown_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['created_on', 'product_name'],
    group => 'created_on',
    group_format => 'month',
    measure => 'count',
    filter_field => ['unit_price', 'created_on'],
    filter_op => ['gte', 'eq'],
    filter_value => ['10', '2026-08'],
    filter_group => [0, 1],
    order => 'created_on',
    limit => 25,
    page => 1,
});
my $drilldown_statement = $postgresql->compile(
    $domain,
    Selecto::Components::QueryBuilder->build($config, $domain, $drilldown_state)->{query},
);
like $drilldown_statement->sql, qr/"s0"\."unit_price" >= \$1/,
    'aggregate drilldown retains the original detail filter';
like $drilldown_statement->sql,
    qr/TO_CHAR\("s0"\."created_on", 'YYYY-MM'\) = \$2/,
    'aggregate drilldown filters by the exact governed grouping expression';
is_deeply $drilldown_statement->params, ['10', '2026-08'],
    'original and grouped drilldown values remain aligned bound parameters';

my $grid_selection_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    filter_field => [qw(unit_price category.category_name units_in_stock category.category_name units_in_stock)],
    filter_op => [qw(gte eq eq eq eq)],
    filter_value => ['10', 'East', '1', 'West', '2'],
    filter_value_end => ['', '', '', '', ''],
    filter_group => [0, 0, 0, 0, 0],
    filter_clause => ['', 1, 1, 2, 2],
    order => 'product_name',
});
ok $grid_selection_state->valid,
    'canonical multi-cell grid filters pass governed state validation';
my $grid_selection_statement = $postgresql->compile(
    $domain,
    Selecto::Components::QueryBuilder->build(
        $config, $domain, $grid_selection_state,
    )->{query},
);
like $grid_selection_statement->sql,
    qr/\("s0"\."unit_price" >= \$1\) AND \(\(\("j_category"\."category_name" = \$2\) AND \("s0"\."units_in_stock" = \$3\)\) OR \(\("j_category"\."category_name" = \$4\) AND \("s0"\."units_in_stock" = \$5\)\)\)/,
    'ordinary filters are ANDed with an OR of independently paired grid cells';
is_deeply $grid_selection_statement->params, ['10', 'East', '1', 'West', '2'],
    'multi-cell grid values remain ordered bound parameters';

my $grid_axis_selection_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    filter_field => [qw(category.category_name category.category_name units_in_stock)],
    filter_op => [qw(eq eq eq)],
    filter_value => ['East', 'West', '2'],
    filter_value_end => ['', '', ''],
    filter_group => [0, 0, 0],
    filter_clause => [1, 2, 2],
    order => 'product_name',
});
ok $grid_axis_selection_state->valid,
    'a full grid axis can coexist with an independently paired cell';
my $grid_axis_selection_statement = $postgresql->compile(
    $domain,
    Selecto::Components::QueryBuilder->build(
        $config, $domain, $grid_axis_selection_state,
    )->{query},
);
like $grid_axis_selection_statement->sql,
    qr/\("j_category"\."category_name" = \$1\) OR \(\("j_category"\."category_name" = \$2\) AND \("s0"\."units_in_stock" = \$3\)\)/,
    'a full row remains one SQL condition while a remaining cell stays paired';
is_deeply $grid_axis_selection_statement->params, ['East', 'West', '2'],
    'compact grid-axis and cell parameters remain aligned';

my $between_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'between',
    filter_value => '2026-01-01',
    filter_value_end => '2026-03-31',
    order => 'created_on',
});
my $between_statement = $postgresql->compile(
    $domain,
    Selecto::Components::QueryBuilder->build($config, $domain, $between_state)->{query},
);
like $between_statement->sql, qr/"s0"\."created_on" BETWEEN \$1 AND \$2/,
    'date range compiles to a governed BETWEEN expression';
is_deeply $between_statement->params, ['2026-01-01', '2026-03-31'],
    'both date range values remain bound parameters';

my $epoch_contract = $domain->contract;
push @{$epoch_contract->{source}{fields}}, 'actual_pickup';
$epoch_contract->{source}{columns}{actual_pickup} = {type => 'epoch_datetime'};
my $epoch_domain = Selecto::Domain->parse($epoch_contract, strict => 1);
my $epoch_state = Selecto::Components::State->from_input($config, $epoch_domain, {
    q => 1,
    view => 'detail',
    field => 'actual_pickup',
    field_format => 'month',
    filter_field => 'actual_pickup',
    filter_op => 'between',
    filter_value => '2026-01-01T00:00',
    filter_value_end => '2026-03-31T23:59',
    order => 'actual_pickup',
});
ok $epoch_state->valid, 'epoch datetime fields accept date formatting and date filters';
my $epoch_component_statement = $postgresql->compile(
    $epoch_domain,
    Selecto::Components::QueryBuilder->build($config, $epoch_domain, $epoch_state)->{query},
);
like $epoch_component_statement->sql,
    qr/TO_CHAR\(TO_TIMESTAMP\("s0"\."actual_pickup"\), 'YYYY-MM'\) AS "actual_pickup"/,
    'epoch detail columns apply the selected date format';
like $epoch_component_statement->sql,
    qr/TO_TIMESTAMP\("s0"\."actual_pickup"\) BETWEEN \$1 AND \$2/,
    'epoch date range filters compare through a timestamp expression';
is_deeply $epoch_component_statement->params, ['2026-01-01T00:00', '2026-03-31T23:59'],
    'epoch date filter controls retain bound date-time values';

my $shortcut_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'date_shortcut',
    filter_value => 'this_year',
    order => 'created_on',
});
my $shortcut_statement = $postgresql->compile(
    $domain,
    Selecto::Components::QueryBuilder->build($config, $domain, $shortcut_state)->{query},
);
my @this_year = Selecto::Components::DateShortcut->bounds('this_year');
like $shortcut_statement->sql,
    qr/\("s0"\."created_on" >= \$1\) AND \("s0"\."created_on" < \$2\)/,
    'date shortcut compiles to a half-open governed range';
is_deeply $shortcut_statement->params, \@this_year,
    'date shortcut bounds remain bound parameters';

my $recurring_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'date_shortcut',
    filter_value => 'mtd_all_years',
    order => 'created_on',
});
my $recurring_statement = $postgresql->compile(
    $domain,
    Selecto::Components::QueryBuilder->build($config, $domain, $recurring_state)->{query},
);
my $recurring_plan = Selecto::Components::DateShortcut->plan('mtd_all_years');
like $recurring_statement->sql,
    qr/TO_CHAR\("s0"\."created_on", 'MM-DD'\) >= \$1\).*TO_CHAR\("s0"\."created_on", 'MM-DD'\) <= \$2/,
    'all-years date shortcut compiles as a recurring month/day range';
is_deeply $recurring_statement->params,
    [$recurring_plan->{start}, $recurring_plan->{end}],
    'recurring shortcut boundaries remain bound parameters';

my $collection_contract = $domain->contract;
$collection_contract->{source}{associations}{variants} = {
    queryable => 'variants',
    owner_key => 'id',
    related_key => 'product_id',
};
$collection_contract->{schemas}{variants} = {
    source_table => 'product_variants',
    primary_key => 'id',
    fields => [qw(id product_id sku serial_number)],
    columns => {
        id => {type => 'integer'},
        product_id => {type => 'integer'},
        sku => {type => 'string'},
        serial_number => {type => 'string', html_format => 'vin_last_six'},
    },
    associations => {},
};
$collection_contract->{joins}{variants} = {type => 'left'};
my $collection_domain = Selecto::Domain->parse($collection_contract, strict => 1);
is $collection_domain->associations->{variants}->cardinality, 'many',
    'a relationship targeting a non-primary foreign key is inferred as to-many';
my $collection_state = Selecto::Components::State->from_input(
    $config, $collection_domain, {
        q => 1,
        view => 'detail',
        field => ['product_name', 'variants.sku', 'variants.serial_number'],
        order => 'product_name',
        direction => 'asc',
        limit => 25,
        page => 1,
    },
);
ok $collection_state->valid, 'to-many columns are valid in a root detail view';
my $collection_result = Selecto::Components::QueryBuilder->build(
    $config, $collection_domain, $collection_state,
);
my $collection_statement = $postgresql->compile(
    $collection_domain, $collection_result->{query},
);
like $collection_statement->sql,
    qr{JSON_AGG\(JSON_BUILD_OBJECT\('sku', "c_variants"\."sku", 'serial_number', "c_variants"\."serial_number"\) ORDER BY "c_variants"\."id"\)},
    'selected child fields compile into one ordered correlated JSON collection';
unlike $collection_statement->sql, qr{JOIN "product_variants"},
    'the root query does not join and multiply rows for a to-many selection';
is_deeply $collection_statement->columns,
    [qw(product_name __selecto_nested_variants __selecto_link_id)],
    'the child collection occupies one stable result column';
is_deeply [map { $_->{label} } @{$collection_result->{columns}[1]{nested_fields}}],
    ['Sku', 'Serial Number'], 'nested child fields preserve their requested order';
is $collection_result->{columns}[1]{nested_fields}[1]{html_format}, 'vin_last_six',
    'nested child fields retain domain-declared HTML formatting';
is_deeply [map { $_->arguments->[0] } @{$collection_result->{count_selections}}],
    ['id'], 'the pagination count selects only the root key';

my $nested_records = [{
    __selecto_nested_variants =>
        '[{"sku":"SKU-A","serial_number":"1HGCM82633A004352"},{"sku":"SKU-B","serial_number":"VIN-2"}]',
}];
Selecto::Components::Explorer::_prepare_nested_records(
    $collection_result, $nested_records,
);
is_deeply $nested_records->[0]{__selecto_nested_variants}, [
    {sku => 'SKU-A', serial_number => '1HGCM82633A004352'},
    {sku => 'SKU-B', serial_number => 'VIN-2'},
], 'JSON child collections are decoded into records for rendering';
my $nested_html = Selecto::Components::Renderer->_table(
    {
        %$collection_result,
        records => $nested_records,
        drilldowns => [],
    },
    {bulk_actions => []},
);
like $nested_html, qr{class="sc-nested-table"},
    'to-many data renders as an inline nested table';
my $nested_body = Selecto::Components::Renderer::_nested_table(
    $collection_result->{columns}[1], $nested_records->[0]{__selecto_nested_variants}, 2,
);
like $nested_body, qr{<caption class="sc-visually-hidden">Variants, result row 2</caption>},
    'each nested table identifies its parent result row';
like $nested_body, qr{<thead>},
    'subsequent nested tables retain their child headers';
like $nested_body, qr{<td>SKU-A</td>},
    'subsequent nested tables retain their full child values';
like $nested_html,
    qr{<th scope="col">Sku</th>.*<td>SKU-A</td>.*1HGCM82633A<strong class="sc-vin-suffix">004352</strong>.*<td>VIN-2</td>}s,
    'the nested table renders every child row and applies its VIN formatter';
is Selecto::Components::Explorer::_delimited_cell(
    $nested_records->[0]{__selecto_nested_variants}
), '"[{""serial_number"":""1HGCM82633A004352"",""sku"":""SKU-A""},{""serial_number"":""VIN-2"",""sku"":""SKU-B""}]"',
    'flat exports encode a nested collection as JSON instead of a Perl reference';

my $collection_sort_state = Selecto::Components::State->from_input(
    $config, $collection_domain, {
        q => 1, view => 'detail', field => ['product_name', 'variants.sku'],
        order => 'variants.sku', limit => 25, page => 1,
    },
);
ok !$collection_sort_state->valid,
    'a child value cannot sort root rows and accidentally restore denormalization';
like join(' ', @{$collection_sort_state->errors}), qr/to-many field cannot order/,
    'to-many sort validation explains the root-row restriction';

done_testing;
