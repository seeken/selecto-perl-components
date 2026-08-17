use 5.034;
use strict;
use warnings;
use Test::More;
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
is_deeply $initial->fields,
    [qw(product_name category.category_name unit_price)],
    'configured detail fields become initial state';
is_deeply $initial->groups, ['category.category_name'], 'configured group becomes initial state';

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
is $configured->measure, 'total_price', 'configured measure is retained';
is $configured->page, 3, 'page is retained';
is_deeply $configured->filters, [
    { field => 'unit_price', op => 'gte', value => '12.50', value_end => '' },
    { field => 'category.category_name', op => 'in', value => 'Tools, Produce', value_end => '' },
], 'filters retain governed field, operator, and bound value intent';

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
    order => 'created_on',
    limit => 25,
    page => 1,
});
ok $drilldown->valid, 'an aggregate group value is valid detail drilldown state';
is_deeply $drilldown->filters->[0], {
    field => 'created_on', op => 'eq', value => '2026-08', value_end => '', grouped => 1,
}, 'drilldown state marks the filter as a governed grouping expression';
my $drilldown_pairs = $drilldown->query_pairs;
my @filter_groups;
for (my $index = 0; $index < @$drilldown_pairs; $index += 2) {
    push @filter_groups, $drilldown_pairs->[$index + 1]
        if $drilldown_pairs->[$index] eq 'filter_group';
}
is_deeply \@filter_groups, [1], 'canonical state preserves the aligned drilldown marker';

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
    alias => 'Average price', function => 'avg', bucket_ranges => '', ignore_nulls => 0,
}, 'each selected measure retains independent configuration';
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
}, 'a numeric domain column is available as a configurable measure';
is_deeply $column_measure_by_id{'category.category_name'}, {
    path => 'category.category_name',
    label => $column_measure_config->field_map($domain)->{'category.category_name'}{label},
    type => 'string',
    field => 'category.category_name', default_function => 'count',
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
    alias => 'Named categories', function => 'count_distinct', bucket_ranges => '', ignore_nulls => 0,
}, 'relationship-column aggregate configuration is retained';

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
ok !$duplicate_filter->valid, 'the same field cannot be added as two filters';
like join(' ', @{$duplicate_filter->errors}), qr/can be set only once/,
    'duplicate filter has an actionable error';

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
