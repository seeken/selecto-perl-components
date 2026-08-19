use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::DateShortcut ();
use Selecto::Components::QueryBuilder;
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
    qr/\ASELECT \* FROM \(SELECT .*\) AS rollupfix ORDER BY 1 ASC NULLS FIRST LIMIT 25 OFFSET 0\z/s,
    'ordered bucket rollups use the PostgreSQL positional outer-sort workaround';
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

done_testing;
