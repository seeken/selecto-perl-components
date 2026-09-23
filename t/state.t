use 5.034;
use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::QueryBuilder;
use Selecto::Components::State;
use Selecto::PostgreSQL;

my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'products'
);
my $domain = TestSelectoComponents::domain();

my $initial = Selecto::Components::State->from_input($config, $domain, {});
ok $initial->valid, 'default state is valid';
is $initial->view, 'detail', 'detail is the default view';
is $initial->row_click_action, 'open_product',
    'the configured row action is selected for the initial detail view';
like join('&', @{$initial->query_pairs}), qr/row_click_action&open_product/,
    'row-action selection is retained in canonical query state';
is_deeply $initial->fields,
    [qw(product_name category.category_name unit_price)],
    'configured detail fields become initial state';
is_deeply $initial->groups, ['category.category_name'], 'configured group becomes initial state';

my $selected_row_action = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'product_name', measure => 'count',
    row_click_action => 'open_product',
});
is $selected_row_action->row_click_action, 'open_product',
    'a submitted governed row action survives state normalization';
my $stale_row_action = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'product_name', measure => 'count',
    row_click_action => 'removed_or_denied_action',
});
ok $stale_row_action->valid,
    'a stale or newly denied row action does not stop the underlying query';
is $stale_row_action->row_click_action, '',
    'a stale or newly denied row action falls back to no row navigation';
my $fallback_contract = dclone($domain->contract);
delete $fallback_contract->{detail_actions}{open_product};
my $fallback_domain = Selecto::Domain->parse($fallback_contract, strict => 1);
my $fallback_state = Selecto::Components::State->from_input(
    $config, $fallback_domain, {},
);
is $fallback_state->row_click_action, 'edit_product',
    'an unavailable configured default falls back to the first governed row action';

my $promoted_filter = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    filter_field => 'category_id',
    filter_op => 'eq',
    filter_value => '7',
    filter_promote_field => 'category_id',
    measure => 'count',
    order => 'product_name',
});
ok $promoted_filter->valid, 'a promoted filter produces valid explorer state';
ok $promoted_filter->filters->[0]{promoted}, 'the selected filter is retained as promoted state';
like join('&', @{$promoted_filter->query_pairs}), qr/filter_promote_field&category_id/,
    'canonical query state retains promoted filters';

my $api_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['product_name', 'created_on'],
    field_alias => ['product', 'created_month'],
    field_format => ['', 'month'],
    filter_field => ['category_id', 'product_name'],
    filter_op => ['gte', 'in'],
    filter_value => ['7', 'Widget, Gizmo'],
    order => ['created_on'],
    direction => ['desc'],
    limit => 25,
    page => 3,
});
is_deeply $api_state->api_query_payload($config, $domain), {
    select => [
        {field => 'product_name', alias => 'product'},
        {field => 'created_on', alias => 'created_month', format => 'month'},
    ],
    filters => [
        {field => 'category_id', op => 'gte', value => '7'},
        {field => 'product_name', op => 'in', value => ['Widget', 'Gizmo']},
    ],
    order_by => [{field => 'created_on', direction => 'desc'}],
    row_format => 'objects',
    limit => 25,
    offset => 50,
}, 'detail state becomes a canonical API request with columns, formats, filters, and paging';

my $unrepresentable_alias = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'product_name',
    field_alias => 'Product name', order => 'product_name',
});
is $unrepresentable_alias->api_query_payload($config, $domain), undef,
    'an Explorer-only presentation label is not silently changed into an API alias';

my $aggregate_api_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'aggregate', group => 'category.category_name', measure => 'count',
});
is $aggregate_api_state->api_query_payload($config, $domain), undef,
    'aggregate state is not silently translated into a different detail API query';

my $library_view = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_library_view => 'low_stock_products',
    query_library_param_name => 'threshold',
    query_library_param_value => '8',
    view => 'aggregate',
    group => 'category.category_name',
    measure => 'count',
});
ok $library_view->valid, 'a named query-library view produces valid explorer state';
is $library_view->view, 'detail', 'a named projection switches to the Detail explorer';
is_deeply $library_view->fields,
    [qw(id product_name unit_price units_in_stock category.category_name)],
    'the portable projection seeds editable flat detail columns';
is_deeply $library_view->orders, [
    {field => 'unit_price', direction => 'desc'},
    {field => 'id', direction => 'asc'},
], 'the portable ordering seeds detail sorting';
is_deeply $library_view->query_library_parameters, {threshold => 8},
    'typed query-library parameters are normalized in request state';
my $library_pairs = $library_view->query_pairs;
like join('&', @$library_pairs), qr/query_library_view&low_stock_products/,
    'canonical query state retains the named view';
like join('&', @$library_pairs), qr/query_library_materialized_view&low_stock_products/,
    'canonical query state records that the named preset was materialized';

my $edited_library_view = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_library_view => 'low_stock_products',
    query_library_materialized_view => 'low_stock_products',
    query_library_param_name => 'threshold',
    query_library_param_value => '8',
    field => ['product_name'],
    order => ['product_name'],
    direction => ['asc'],
});
is_deeply $edited_library_view->fields, ['product_name'],
    'materialized query-library projections remain editable';
is_deeply $edited_library_view->orders, [{field => 'product_name', direction => 'asc'}],
    'materialized query-library ordering remains editable';

my $invalid_library_parameter = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_library_view => 'low_stock_products',
    query_library_param_name => 'threshold',
    query_library_param_value => 'many',
});
ok !$invalid_library_parameter->valid, 'invalid typed query-library parameters stop the query';
like join(' ', @{$invalid_library_parameter->errors}), qr/query-library parameters/,
    'invalid query-library parameters return an actionable state error';

my $detail_catalog = $config->detail_column_catalog($domain);
my %detail_by_path = map { $_->{path} => $_ } @$detail_catalog;
is $detail_by_path{'action:add_product_note'}{label}, 'Action: Add Product Note',
    'bulk actions are available as named detail columns';
is $detail_by_path{'action:mark_for_review'}{type}, 'action',
    'each configured bulk action has its own action-column type';

my $action_columns = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['action:add_product_note', 'product_name', 'action:mark_for_review'],
    field_alias => ['', 'Product', ''],
    field_format => ['', '', ''],
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
});
ok $action_columns->valid, 'multiple action columns are valid detail selections';
is_deeply $action_columns->fields,
    ['action:add_product_note', 'product_name', 'action:mark_for_review'],
    'action columns retain their order among data columns';
is_deeply $action_columns->field_configs->{'action:add_product_note'},
    {alias => '', format => ''}, 'action columns do not accept presentation configuration';
my $action_only = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'action:add_product_note', measure => 'count',
});
ok $action_only->valid, 'an action can be the only selected detail column';
is $action_only->order, 'id', 'action-only detail results use the domain primary key for stable ordering';

my $configured = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'graph',
    chart_type => 'area',
    graph_show_table => 1,
    field => ['product_name', 'unit_price'],
    group => ['category.category_name'],
    measure => 'total_price',
    filter_field => ['unit_price', 'category.category_name'],
    filter_op => ['gte', 'in'],
    filter_value => ['12.50', 'Tools, Produce'],
    order => 'unit_price',
    direction => 'desc',
    limit => 50,
    page => 3,
});
ok $configured->valid, 'configured graph state is valid';
is $configured->chart_type, 'area', 'configured chart type is retained';
ok $configured->graph_show_table, 'the optional graph aggregate table is retained';
is $configured->measure, 'total_price', 'configured measure is retained';
is $configured->limit, $config->max_limit,
    'graph point limits are raised to the largest configured test limit';
is $configured->page, 1, 'graph results always use their first point set';
like join('&', @{$configured->query_pairs}), qr/graph_show_table&1/,
    'canonical graph state retains the aggregate-table preference';
is_deeply $configured->filters, [
    { field => 'unit_price', op => 'gte', value => '12.50', value_end => '' },
    { field => 'category.category_name', op => 'in', value => 'Tools, Produce', value_end => '' },
], 'filters retain governed field, operator, and bound value intent';

my $aggregate_grid = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    aggregate_grid => 1,
    aggregate_grid_colorize => 1,
    aggregate_grid_color_scale => 'log',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    order => 'product_name',
});
ok $aggregate_grid->aggregate_grid, 'aggregate grid mode survives state normalization';
ok $aggregate_grid->aggregate_grid_colorize, 'aggregate heat-map colors survive state normalization';
is $aggregate_grid->aggregate_grid_color_scale, 'log',
    'the selected logarithmic heat scale survives state normalization';
like join('&', @{$aggregate_grid->query_pairs}),
    qr/aggregate_grid&1&aggregate_grid_colorize&1&aggregate_grid_color_scale&log/,
    'canonical query state retains aggregate grid presentation options';

my $normalized_grid_scale = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    aggregate_grid => 1,
    aggregate_grid_color_scale => 'not-a-scale',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    order => 'product_name',
});
is $normalized_grid_scale->aggregate_grid_color_scale, 'linear',
    'unknown heat-map scales normalize to the governed linear default';

my $detail_with_grid_input = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    aggregate_grid => 1,
    aggregate_grid_colorize => 1,
    field => 'product_name',
    measure => 'count',
    order => 'product_name',
});
ok !$detail_with_grid_input->aggregate_grid,
    'aggregate grid parameters cannot alter a Detail result';

my $grid_cell_selection = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    filter_field => 'unit_price',
    filter_op => 'gte',
    filter_value => '10',
    filter_value_end => '',
    filter_group => 0,
    filter_clause => '',
    grid_cell => ['["East",1]', '["West",2]'],
    order => 'product_name',
});
ok $grid_cell_selection->valid,
    'multiple aggregate grid cells become valid governed detail filter clauses';
is_deeply $grid_cell_selection->filters, [
    {field => 'unit_price', op => 'gte', value => '10', value_end => ''},
    {field => 'category.category_name', op => 'eq', value => 'East', value_end => '', clause => 1},
    {field => 'units_in_stock', op => 'eq', value => '1', value_end => '', clause => 1},
    {field => 'category.category_name', op => 'eq', value => 'West', value_end => '', clause => 2},
    {field => 'units_in_stock', op => 'eq', value => '2', value_end => '', clause => 2},
], 'each selected cell retains its row and column as one aligned alternative';
my @grid_filter_clauses;
my $grid_cell_pairs = $grid_cell_selection->query_pairs;
for (my $index = 0; $index < @$grid_cell_pairs; $index += 2) {
    push @grid_filter_clauses, $grid_cell_pairs->[$index + 1]
        if $grid_cell_pairs->[$index] eq 'filter_clause';
}
is_deeply \@grid_filter_clauses, ['', 1, 1, 2, 2],
    'canonical state aligns ordinary and alternative filter clause markers';
unlike join('&', @$grid_cell_pairs), qr/(?:^|&)grid_cell&/,
    'raw grid cell payloads are replaced by validated canonical filters';

my $single_axis_grid_clause = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    filter_field => 'category.category_name',
    filter_op => 'eq',
    filter_value => '7',
    filter_clause => 1,
    order => 'product_name',
});
ok $single_axis_grid_clause->valid,
    'a governed alternative clause may represent one complete grid row or column';
is_deeply $single_axis_grid_clause->filters, [{
    field => 'category.category_name', op => 'eq', value => '7', value_end => '', clause => 1,
}], 'a complete axis remains one condition instead of expanding into cell pairs';

my $ordinary_alternatives = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'product_name',
    filter_field => ['product_name', 'category.category_name'],
    filter_op => ['eq', 'eq'], filter_value => ['Open', 'Preferred'],
    filter_clause => [1, 2],
});
ok $ordinary_alternatives->valid,
    'alternative ordinary filters do not require a grid or aggregate groups';
is_deeply [map { $_->{clause} } @{$ordinary_alternatives->filters}], [1, 2],
    'ordinary alternatives retain their OR grouping';

my $compacted_grid_selection = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    grid_axis => '{"axis":0,"value":"East"}',
    grid_cell => ['["East",1]', '["East",2]', '["West",3]'],
    order => 'product_name',
});
ok $compacted_grid_selection->valid,
    'a complete axis and remaining grid cells become valid compact filter state';
is_deeply $compacted_grid_selection->filters, [
    {field => 'category.category_name', op => 'eq', value => 'East', value_end => '', clause => 1},
    {field => 'category.category_name', op => 'eq', value => 'West', value_end => '', clause => 2},
    {field => 'units_in_stock', op => 'eq', value => '3', value_end => '', clause => 2},
], 'cells covered by a complete row are omitted while uncovered cells remain paired';

my $malformed_grid_cell = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    grid_cell => '{not json}',
    order => 'product_name',
});
ok !$malformed_grid_cell->valid, 'malformed grid cell state is rejected';
like join(' ', @{$malformed_grid_cell->errors}), qr/selected grid cell is invalid/,
    'malformed grid cell state produces an actionable validation error';

for my $chart_type (qw(bar horizontal_bar stacked_bar line area pie doughnut scatter)) {
    my $chart = Selecto::Components::State->from_input($config, $domain, {
        q => 1,
        view => 'graph',
        chart_type => $chart_type,
        field => 'product_name',
        group => 'category.category_name',
        measure => 'count',
        order => 'product_name',
    });
    ok $chart->valid, "$chart_type is an available dashboard chart type";
    is $chart->chart_type, $chart_type, "$chart_type survives state normalization";
    ok !$chart->graph_show_table, 'the aggregate table is off by default for graphs';
    is $chart->page, 1, 'graphs do not expose paged result sets';
}

my $invalid_chart = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'graph',
    chart_type => 'javascript:alert(1)',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
});
ok !$invalid_chart->valid, 'an unknown chart type is rejected';
is $invalid_chart->chart_type, 'bar', 'an invalid chart type falls back safely';
like join(' ', @{$invalid_chart->errors}), qr/available chart type/,
    'invalid chart type reports a governed validation error';

my $page_baseline = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    limit => 25,
    page => 3,
});
my $page_only = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_signature => $page_baseline->query_signature,
    view => 'detail',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    limit => 25,
    page => 7,
});
is $page_only->page, 7, 'changing only Page retains the explicitly requested page';
my $new_query = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_signature => $page_baseline->query_signature,
    view => 'detail',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    filter_field => 'unit_price',
    filter_op => 'gte',
    filter_value => '10',
    order => 'product_name',
    limit => 25,
    page => 7,
});
is $new_query->page, 1, 'changing query intent resets an existing query to page one';

my $graph_baseline = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'graph',
    chart_type => 'bar',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    limit => 25,
    page => 4,
});
my $changed_chart = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    query_signature => $graph_baseline->query_signature,
    view => 'graph',
    chart_type => 'line',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    limit => 25,
    page => 4,
});
is $changed_chart->page, 1, 'changing chart type resets the result to page one';

my $drilldown = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['created_on', 'product_name'],
    group => 'created_on',
    group_format => 'month',
    measure => 'count',
    filter_field => 'created_on',
    filter_op => 'eq',
    filter_value => '2026-08',
    filter_group => 1,
    filter_promote_field => 'created_on',
    order => 'created_on',
    limit => 25,
    page => 1,
});
ok $drilldown->valid, 'an aggregate group value is valid detail drilldown state';
is_deeply $drilldown->filters->[0], {
    field => 'created_on', op => 'eq', value => '2026-08', value_end => '',
    grouped => 1, promoted => 1,
}, 'drilldown state retains its grouping expression and automatic promotion';
my $drilldown_pairs = $drilldown->query_pairs;
my @filter_groups;
for (my $index = 0; $index < @$drilldown_pairs; $index += 2) {
    push @filter_groups, $drilldown_pairs->[$index + 1]
        if $drilldown_pairs->[$index] eq 'filter_group';
}
is_deeply \@filter_groups, [1], 'canonical state preserves the aligned drilldown marker';
like join('&', @$drilldown_pairs), qr/filter_promote_field&created_on/,
    'canonical state preserves promotion for a grouped aggregate drilldown';

my $bad_drilldown = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => 'category.category_name',
    filter_field => 'unit_price',
    filter_op => 'eq',
    filter_value => '10',
    filter_group => 1,
    order => 'product_name',
});
ok !$bad_drilldown->valid, 'a drilldown marker cannot target a field outside the configured groups';
like join(' ', @{$bad_drilldown->errors}), qr/aggregate drilldown filter is not available/,
    'invalid drilldown state fails with an actionable error';

my $multiple_measures = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    field => 'product_name',
    group => 'unit_price',
    group_format => 'buckets',
    group_bucket_ranges => '0-10, 11+',
    measure => ['count', 'total_price'],
    measure_alias => ['', 'Average price'],
    measure_function => ['count', 'avg'],
    measure_bucket_ranges => ['', ''],
    measure_ignore_nulls => [0, 0],
    order => 'product_name',
});
ok $multiple_measures->valid, 'multiple configured measures and a numeric group bucket are valid';
is_deeply $multiple_measures->measures, ['count', 'total_price'],
    'measure order is retained';
is_deeply $multiple_measures->measure_configs->{total_price}, {
    alias => 'Average price', function => 'avg', bucket_ranges => '',
    null_handling => 'sql', ignore_nulls => 0,
    series_id => 'series_2', chart_type => 'auto', axis => 'auto', stack => '',
    raw_unit => {kind => 'currency', code => 'USD'},
    unit => {kind => 'currency', code => 'USD'}, behavior => 'flow', transforms => [],
}, 'each selected measure retains independent configuration';
my $repeated_measure = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => ['total_price', 'total_price'],
    measure_alias => ['Revenue', 'Average revenue'],
    measure_function => ['sum', 'avg'],
});
ok $repeated_measure->valid, 'the same measure can be selected more than once';
is_deeply $repeated_measure->measures, ['total_price', 'total_price'],
    'repeated measure order is retained';
is_deeply $repeated_measure->measure_config_list, [
    {alias => 'Revenue', function => 'sum', bucket_ranges => '',
        null_handling => 'auto', ignore_nulls => 1,
        series_id => 'series_1', chart_type => 'auto', axis => 'auto', stack => '',
        resolved_axis => 'left', raw_unit => {kind => 'currency', code => 'USD'},
        unit => {kind => 'currency', code => 'USD'}, behavior => 'flow', transforms => []},
    {alias => 'Average revenue', function => 'avg', bucket_ranges => '',
        null_handling => 'auto', ignore_nulls => 0,
        series_id => 'series_2', chart_type => 'auto', axis => 'auto', stack => '',
        resolved_axis => 'left', raw_unit => {kind => 'currency', code => 'USD'},
        unit => {kind => 'currency', code => 'USD'}, behavior => 'flow', transforms => []},
], 'each repeated measure retains independent positional configuration';
my @repeated_null_modes;
my $repeated_query_pairs = $repeated_measure->query_pairs;
for (my $index = 0; $index < @$repeated_query_pairs; $index += 2) {
    push @repeated_null_modes, $repeated_query_pairs->[$index + 1]
        if $repeated_query_pairs->[$index] eq 'measure_ignore_nulls';
}
is_deeply \@repeated_null_modes, ['auto', 'auto'],
    'automatic NULL handling remains explicit in canonical graph state';
my $graph_sql_nulls = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => 'total_price', measure_function => 'sum', measure_ignore_nulls => 0,
});
ok !$graph_sql_nulls->measure_config_list->[0]{ignore_nulls},
    'a graph can explicitly retain SQL SUM NULL behavior';
is $graph_sql_nulls->measure_config_list->[0]{null_handling}, 'sql',
    'an explicit SQL NULL policy remains distinguishable from the graph default';
my @repeated_pairs = @{$repeated_measure->query_pairs};
is scalar(grep { $_ eq 'total_price' } @repeated_pairs), 2,
    'canonical state serializes both repeated measure instances';
is $multiple_measures->group_configs->{unit_price}{bucket_ranges}, '0-10, 11+',
    'group bucket ranges remain aligned with the selected group';

my $column_measure_config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'column_products', measures => []
);
my $column_measure_catalog = $column_measure_config->measure_catalog($domain);
my %column_measure_by_id = map { $_->{path} => $_ } @$column_measure_catalog;
ok $column_measure_by_id{'__row_count__'}, 'a row-count measure is available without configured presets';
is_deeply $column_measure_by_id{unit_price}, {
    path => 'unit_price', label => 'Unit Price', type => 'decimal',
    field => 'unit_price', default_function => 'count',
    source_unit => {kind => 'currency', code => 'USD'},
    source_behavior => 'flow', unit => {kind => 'count'},
}, 'a numeric domain column is available as a configurable measure';
is_deeply $column_measure_by_id{'category.category_name'}, {
    path => 'category.category_name',
    label => $column_measure_config->field_map($domain)->{'category.category_name'}{label},
    type => 'string',
    field => 'category.category_name', default_function => 'count',
    unit => {kind => 'count'},
}, 'a relationship column is available as a configurable measure';

my $colliding_preset_config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'preset_collision',
    measures => [{ id => 'unit_price', label => 'Curated price', aggregate => 'sum', field => 'unit_price' }],
);
my %colliding_measure_by_id = map { $_->{path} => $_ }
    @{$colliding_preset_config->measure_catalog($domain)};
ok $colliding_measure_by_id{unit_price} && $colliding_measure_by_id{'field:unit_price'},
    'a curated preset cannot hide the configurable domain column with the same id';

my $restricted_contract = dclone($domain->contract);
$restricted_contract->{source}{columns}{unit_price}{internal} = 1;
$restricted_contract->{editors}{product_profile}{fields} = [grep {
    $_->{field} ne 'unit_price'
} @{$restricted_contract->{editors}{product_profile}{fields}}];
my $restricted_domain = Selecto::Domain->parse($restricted_contract, strict => 1);
my %restricted_measure_by_id = map { $_->{path} => $_ }
    @{$colliding_preset_config->measure_catalog($restricted_domain)};
ok !$restricted_measure_by_id{unit_price} && !$restricted_measure_by_id{'field:unit_price'},
    'a curated measure cannot expose a domain field marked internal by host policy';

my $column_measures = Selecto::Components::State->from_input($column_measure_config, $domain, {
    q => 1,
    view => 'aggregate',
    field => 'product_name',
    group => 'category.category_name',
    measure => ['unit_price', 'category.category_name'],
    measure_alias => ['', 'Named categories'],
    measure_function => ['sum', 'count_distinct'],
    order => 'product_name',
});
ok $column_measures->valid, 'domain columns can construct independently configured aggregates';
is_deeply $column_measures->measures, ['unit_price', 'category.category_name'],
    'column-derived measure order is retained';
is_deeply $column_measures->measure_configs->{'category.category_name'}, {
    alias => 'Named categories', function => 'count_distinct', bucket_ranges => '',
    null_handling => 'auto', ignore_nulls => 0,
    series_id => 'series_2', chart_type => 'auto', axis => 'auto', stack => '',
    raw_unit => {kind => 'count'}, unit => {kind => 'count'}, behavior => 'flow', transforms => [],
}, 'relationship-column aggregate configuration is retained';
is $column_measures->measure_config_list->[0]{null_handling}, 'auto',
    'aggregate sums use the automatic NULL policy by default';
ok $column_measures->measure_config_list->[0]{ignore_nulls},
    'automatic aggregate sums treat NULL values as zero';

my $dual_axis_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => ['count', 'total_price'],
    measure_function => ['count', 'sum'],
    measure_series_id => ['volume', 'revenue'],
    measure_chart_type => ['bar', 'line'],
    measure_axis => ['auto', 'auto'],
});
ok $dual_axis_graph->valid, 'two incompatible units receive separate automatic axes';
is_deeply [map { $_->{resolved_axis} } @{$dual_axis_graph->measure_config_list}],
    ['left', 'right'], 'automatic axis planning is stable and unit-aware';
is_deeply [map { $_->{series_id} } @{$dual_axis_graph->measure_config_list}],
    ['volume', 'revenue'], 'submitted stable series identifiers are retained';

my $bad_axis_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => ['count', 'total_price'],
    measure_function => ['count', 'sum'],
    measure_axis => ['left', 'left'],
});
ok !$bad_axis_graph->valid, 'an explicit axis rejects incompatible units';
like join(' ', @{$bad_axis_graph->errors}), qr/incompatible units/,
    'manual axis conflict explains the unit incompatibility';

my $stacked_expenses = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => ['total_price', 'total_price'],
    measure_function => ['sum', 'sum'],
    measure_series_id => ['carrier_expense', 'driver_expense'],
    measure_chart_type => ['bar', 'bar'],
    measure_stack => ['expenses', 'expenses'],
});
ok $stacked_expenses->valid, 'compatible series can share a named stack group';
is_deeply [map { $_->{stack} } @{$stacked_expenses->measure_config_list}],
    ['expenses', 'expenses'], 'stack group remains positional for repeated measures';

my $bad_stack = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => ['count', 'total_price'],
    measure_function => ['count', 'sum'],
    measure_stack => ['mixed', 'mixed'],
});
ok !$bad_stack->valid, 'one stack cannot combine incompatible count and currency units';
like join(' ', @{$bad_stack->errors}), qr/stack group mixed requires compatible units/,
    'invalid stack names the affected group and correction';

my $colored_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => 'total_price', measure_function => 'sum', measure_color => '#A1B2C3',
});
ok $colored_graph->valid, 'a six-digit custom graph color is valid';
is $colored_graph->measure_config_list->[0]{color}, '#a1b2c3',
    'custom graph colors normalize for stable saved URLs';

my $bad_color_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => 'total_price', measure_function => 'sum', measure_color => 'red; background:url(x)',
});
ok !$bad_color_graph->valid, 'arbitrary CSS is rejected as a graph color';
like join(' ', @{$bad_color_graph->errors}), qr/#RRGGBB/,
    'invalid color reports the required safe format';

my $breakout_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', chart_type => 'line',
    field => 'product_name',
    group => ['created_on', 'category.category_name'],
    group_format => ['month', ''],
    graph_series_group => 'category.category_name',
    measure => 'discontinued', measure_function => 'true_percentage',
});
ok $breakout_graph->valid, 'a selected graph group can split a measure into series';
is $breakout_graph->graph_series_group, 'category.category_name',
    'the graph series group is retained';
is_deeply $breakout_graph->measure_config_list->[0]{unit},
    {kind => 'percentage', scale => 'whole'},
    'percent-true measures carry percentage units';
like join('&', @{$breakout_graph->query_pairs}),
    qr/graph_series_group&category\.category_name/,
    'canonical graph state saves the series-group selection';

my $bad_breakout_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'created_on',
    graph_series_group => 'category.category_name', measure => 'count',
});
ok !$bad_breakout_graph->valid,
    'a graph cannot split by a field that is not one of its selected groups';
like join(' ', @{$bad_breakout_graph->errors}), qr/series group must be one of/,
    'an invalid graph series group has an actionable error';

my $transformed_graph = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => ['count', 'total_price'],
    measure_function => ['count', 'sum'],
    measure_transform => ['percent_of_total', 'moving_average'],
    measure_transform_window => ['', 7],
});
ok $transformed_graph->valid, 'governed graph transforms parse with typed parameters';
is_deeply $transformed_graph->measure_config_list->[0]{unit},
    {kind => 'percentage', scale => 'whole'},
    'a transform changes the series result unit without changing its source column';
is_deeply $transformed_graph->measure_config_list->[1]{transforms},
    [{type => 'moving_average', parameters => {window => 7}}],
    'moving-average window is retained in ordered series state';

my $bad_transform_window = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', field => 'product_name', group => 'category.category_name',
    measure => 'total_price', measure_function => 'sum',
    measure_transform => 'moving_average', measure_transform_window => 999,
});
ok !$bad_transform_window->valid, 'out-of-range transform parameters fail closed';
like join(' ', @{$bad_transform_window->errors}), qr/window must be from 2 through 365/,
    'invalid smoothing window has a corrective error';

my $unconfigured_measure_state = Selecto::Components::State->from_input(
    $column_measure_config, $domain, {}
);
is $unconfigured_measure_state->measure, '__row_count__',
    'row count is the default when no curated presets are configured';

my $bad_bucket = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    field => 'product_name',
    group => 'unit_price',
    group_format => 'buckets',
    group_bucket_ranges => q{0-10); DROP TABLE products; --},
    measure => 'count',
    order => 'product_name',
});
ok !$bad_bucket->valid, 'arbitrary bucket input fails closed';
like join(' ', @{$bad_bucket->errors}), qr/group bucket range is not available/,
    'rejected group bucket has an actionable error';

my $pairs = $configured->query_pairs;
my @field_values;
for (my $index = 0; $index < @$pairs; $index += 2) {
    push @field_values, $pairs->[$index + 1] if $pairs->[$index] eq 'field';
}
is_deeply \@field_values, ['product_name', 'unit_price'], 'canonical query pairs preserve repeated fields';

my $configured_columns = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['created_on', 'product_name'],
    field_alias => ['Created month', 'Product'],
    field_format => ['month', ''],
    group => ['created_on'],
    group_alias => ['Month'],
    group_format => ['month'],
    measure => 'count',
    order => ['created_on', 'product_name'],
    direction => ['desc', 'asc'],
    limit => 25,
    page => 1,
});
ok $configured_columns->valid, 'column configuration and multiple sort fields are valid';
is_deeply $configured_columns->field_configs->{created_on},
    { alias => 'Created month', format => 'month' },
    'detail column retains its governed format and presentation label';

my $repeated_columns = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['created_on', 'created_on'],
    field_alias => ['Created date', 'Created time'],
    field_format => ['day', 'time'],
    order => 'created_on',
});
ok $repeated_columns->valid, 'the same detail field can be selected more than once';
is_deeply $repeated_columns->field_config_list, [
    {alias => 'Created date', format => 'day'},
    {alias => 'Created time', format => 'time'},
], 'each repeated detail field retains independent presentation configuration';
my @repeated_column_pairs = @{$repeated_columns->query_pairs};
is scalar(grep { $_ eq 'created_on' } @repeated_column_pairs), 3,
    'repeated detail fields survive canonical URL serialization alongside ordering';
is_deeply $configured_columns->group_configs->{created_on},
    {
        alias => 'Month', format => 'month', bucket_ranges => '',
        prefix_length => 2, exclude_articles => 1,
    },
    'aggregate group column retains independent configuration';
is_deeply $configured_columns->orders, [
    { field => 'created_on', direction => 'desc' },
    { field => 'product_name', direction => 'asc' },
], 'ordered sort fields retain priority and direction';

my $bad_column_format = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    field_format => q{month'); DROP TABLE products; --},
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
});
ok !$bad_column_format->valid, 'arbitrary and non-temporal column formats fail closed';
like join(' ', @{$bad_column_format->errors}), qr/column format is not available/,
    'rejected column format has an actionable error';

my $draft = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['product_name', 'unit_price'],
    group => ['category.category_name'],
    measure => 'count',
    filter_field => ['unit_price', 'category.category_name'],
    filter_op => ['eq', 'eq'],
    filter_value => ['', 'Camp Pantry'],
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
});
ok $draft->valid, 'an empty newly added filter is a valid draft';
is_deeply $draft->filters, [
    { field => 'unit_price', op => 'eq', value => '', value_end => '', draft => 1 },
    { field => 'category.category_name', op => 'eq', value => 'Camp Pantry', value_end => '' },
], 'draft and complete filters retain their aligned URL state';
my $draft_query = Selecto::Components::QueryBuilder->build($config, $domain, $draft);
my $draft_statement = Selecto::PostgreSQL->new(
    dbh => bless({}, 'TestSelectoComponents::CompileDBH'),
)->compile($domain, $draft_query->{query});
unlike $draft_statement->sql, qr/"s0"\."unit_price"\s*=/,
    'draft filter does not compile into SQL';
like $draft_statement->sql, qr/"j_category"\."category_name" = \$1/,
    'complete filter still compiles alongside a draft';
is_deeply $draft_statement->params, ['Camp Pantry'], 'only complete filter values are bound';

my $date_between = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'between',
    filter_value => '2026-01-01',
    filter_value_end => '2026-03-31',
    order => 'created_on',
});
ok $date_between->valid, 'date BETWEEN accepts two ISO date values';
is_deeply $date_between->filters->[0], {
    field => 'created_on', op => 'between', value => '2026-01-01', value_end => '2026-03-31',
}, 'date range retains independently aligned start and end values';

my $date_shortcut = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'date_shortcut',
    filter_value => 'this_year',
    order => 'created_on',
});
ok $date_shortcut->valid, 'whitelisted date shortcut is accepted';

my $bad_date_shortcut = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'date_shortcut',
    filter_value => q{this_year'); DROP TABLE products; --},
    order => 'created_on',
});
ok !$bad_date_shortcut->valid, 'arbitrary date shortcut fails closed';
like join(' ', @{$bad_date_shortcut->errors}), qr/date shortcut is not available/,
    'rejected shortcut has an actionable error';

my $bad_date = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'created_on',
    filter_field => 'created_on',
    filter_op => 'eq',
    filter_value => '2026-02-31',
    order => 'created_on',
});
ok !$bad_date->valid, 'invalid calendar date fails closed';

my $bad_string_range = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    filter_field => 'product_name',
    filter_op => 'between',
    filter_value => 'A',
    filter_value_end => 'Z',
    order => 'product_name',
});
ok !$bad_string_range->valid, 'field type controls which filter operators are available';

my $duplicate_filter = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    filter_field => ['unit_price', 'unit_price'],
    filter_op => ['gte', 'eq'],
    filter_value => ['10', '20'],
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
});
ok $duplicate_filter->valid, 'the same field can be used by independent filters';
is_deeply [map { [$_->{op}, $_->{value}] } @{$duplicate_filter->filters}],
    [['gte', '10'], ['eq', '20']],
    'repeated filters retain their independent operators and values';

my $independently_promoted_filter = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    filter_field => ['unit_price', 'unit_price'],
    filter_op => ['gte', 'lte'],
    filter_value => ['10', '20'],
    filter_promote_index => 2,
    order => 'product_name',
});
ok !$independently_promoted_filter->filters->[0]{promoted}
    && $independently_promoted_filter->filters->[1]{promoted},
    'promotion targets one repeated filter instance rather than every filter on its field';

my $six_filters = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    filter_field => [
        'id',
        'product_name',
        'category_id',
        'unit_price',
        'units_in_stock',
        'category.category_name',
    ],
    filter_op => [qw(eq eq eq gte gt eq)],
    filter_value => [1, 'Widget', 2, 10, 0, 'Tools'],
    order => 'product_name',
    direction => 'asc',
    limit => 25,
    page => 1,
});
ok $six_filters->valid, 'the default capacity accepts more than five filters';
is scalar(@{$six_filters->filters}), 6, 'all six distinct filters are retained';

my $invalid = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'raw_sql',
    field => ['product_name', 'drop_table'],
    group => ['unknown.field'],
    measure => 'eval',
    order => 'drop_table',
    direction => 'sideways',
    limit => 10000,
    filter_field => 'unit_price; DROP TABLE products',
    filter_op => 'sql',
    filter_value => 'anything',
});
ok !$invalid->valid, 'unknown query capabilities fail closed';
cmp_ok scalar(@{$invalid->errors}), '>=', 6, 'invalid state reports the rejected controls';
is_deeply $invalid->fields, ['product_name'], 'valid fields survive alongside rejected fields';
is $invalid->limit, $config->max_limit, 'limit is bounded by host configuration';

my $missing_fields = Selecto::Components::State->from_input($config, $domain, {q => 1});
ok !$missing_fields->valid, 'configured request cannot silently reset an empty field selection';
like join(' ', @{$missing_fields->errors}), qr/Choose at least one detail column/, 'empty selection has an actionable error';

my $invalid_page = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => 'product_name',
    group => 'category.category_name',
    measure => 'count',
    order => 'product_name',
    direction => 'asc',
    limit => 'many',
    page => 'zero',
});
ok !$invalid_page->valid, 'malformed pagination does not silently become canonical';
like join(' ', @{$invalid_page->errors}), qr/Row limit must be a positive integer/, 'malformed limit is reported';
like join(' ', @{$invalid_page->errors}), qr/Page must be a positive integer/, 'malformed page is reported';

done_testing;
