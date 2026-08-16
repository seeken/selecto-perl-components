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
    { field => 'unit_price', op => 'gte', value => '12.50' },
    { field => 'category.category_name', op => 'in', value => 'Tools, Produce' },
], 'filters retain governed field, operator, and bound value intent';

my $pairs = $configured->query_pairs;
my @field_values;
for (my $index = 0; $index < @$pairs; $index += 2) {
    push @field_values, $pairs->[$index + 1] if $pairs->[$index] eq 'field';
}
is_deeply \@field_values, ['product_name', 'unit_price'], 'canonical query pairs preserve repeated fields';

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
    { field => 'unit_price', op => 'eq', value => '', draft => 1 },
    { field => 'category.category_name', op => 'eq', value => 'Camp Pantry' },
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
like join(' ', @{$missing_fields->errors}), qr/Choose at least one detail field/, 'empty selection has an actionable error';

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
