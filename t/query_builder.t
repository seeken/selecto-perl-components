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
my $dbh = bless {}, 'TestSelectoComponents::CompileDBH';
my $postgresql = Selecto::PostgreSQL->new(dbh => $dbh);

my $detail_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'detail',
    field => ['product_name', 'category.category_name', 'unit_price'],
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
    [qw(product_name category__category_name unit_price)],
    'detail aliases are stable and relationship-safe';

my $aggregate_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'graph',
    field => ['product_name'],
    group => ['category.category_name'],
    measure => 'total_price',
    order => 'product_name',
    direction => 'asc',
    limit => 10,
    page => 1,
});
my $aggregate = Selecto::Components::QueryBuilder->build($config, $domain, $aggregate_state);
my $aggregate_statement = $postgresql->compile($domain, $aggregate->{query});
like $aggregate_statement->sql, qr/SUM\("s0"\."unit_price"\) AS "total_price"/, 'configured aggregate compiles';
like $aggregate_statement->sql, qr/GROUP BY "j_category"\."category_name"/, 'configured group compiles';
ok $aggregate->{graph}, 'graph uses aggregate query with graph rendering metadata';

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
    qr/GROUP BY TO_CHAR\("s0"\."created_on", 'YYYY-MM'\)/,
    'aggregate date configuration defines the SQL grouping bucket';
is $formatted_aggregate->{columns}[0]{label}, 'Month',
    'aggregate group label uses its independent configuration';

done_testing;
