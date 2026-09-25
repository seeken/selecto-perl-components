use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config ();
use Selecto::Components::Dashboard ();
use Selecto::Components::Explorer ();
use Selecto::Components::Renderer ();
use Selecto::Components::Renderer::Builder ();

my $dashboard = 'Selecto::Components::Dashboard';
my $config = Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products');
my $explorer = Selecto::Components::Explorer->new(config => $config);
my $controller = TestSelectoComponents::Controller->new;

# A saved view: created_on (promoted, "today") and unit_price >= 5 (not promoted).
my $saved = '/explore/products?q=1&view=detail&field=product_name&field_alias=&field_format='
    . '&filter_field=created_on&filter_op=date_shortcut&filter_value=today&filter_value_end='
    . '&filter_group=0&filter_clause=&filter_promote_field=created_on'
    . '&filter_field=unit_price&filter_op=gte&filter_value=5&filter_value_end=&filter_group=0&filter_clause='
    . '&limit=25&page=3&unknown=ignored';

subtest 'saved view URLs' => sub {
    my $input = $dashboard->input_from_url($saved);
    is $input->{view}, 'detail', 'single values stay scalars';
    is_deeply $input->{filter_field}, ['created_on', 'unit_price'], 'repeated values become lists';
    ok !exists $input->{unknown}, 'unknown parameters are dropped';
    is $dashboard->path_from_url($saved), '/explore/products', 'the explorer path';
};

my $model = $explorer->model($controller, $dashboard->input_from_url($saved));
ok $model->{state}->valid, 'the saved view is valid' or diag explain $model->{state}->errors;

subtest 'promoted filters' => sub {
    my $filters = $dashboard->promoted_filters($model->{config}, $model->{domain}, $model->{state});
    is scalar(@$filters), 1, 'only promoted filters are listed';
    my ($created) = @$filters;
    is $created->{field}, 'created_on', 'identified by field path';
    is $created->{kind}, 'date', 'date kind';
    is $created->{summary}, 'Today', 'date shortcuts summarise as their label';
    ok((grep { $_->[0] eq 'date_shortcut' } @{$created->{operators}}), 'offers date shortcuts');
};

subtest 'compact summaries' => sub {
    my $field = {path => 'x', label => 'X', type => 'string'};
    my $choice = {%$field, filter_choices => [map { {value => $_, label => "L$_"} } 1 .. 4]};
    is $dashboard->filter_summary($config, $field, {op => 'between', value => '2026-09-01', value_end => '2026-09-15'}),
        '2026-09-01 – 2026-09-15', 'ranges';
    is $dashboard->filter_summary($config, $field, {op => 'eq', value => ''}), 'Any', 'no value';
    is $dashboard->filter_summary($config, $field, {op => 'gte', value => 100}), '≥ 100', 'comparisons';
    is $dashboard->filter_summary($config, $field, {op => 'is_null'}), 'Empty', 'empty checks';
    is $dashboard->filter_summary($config, $choice, {op => 'in', value => '1,2,3,4'}), 'L1, L2 +2',
        'choices show labels, the first two and a count';
    is Selecto::Components::Renderer::Builder::_filter_value_text({op => 'date_shortcut', value => 'mtd'}),
        'Month to Date', 'Explorer summaries also show shortcut labels';
};

subtest 'shared filter values' => sub {
    my $input = $dashboard->apply_overrides($model->{state}, {
        created_on => {op => 'date_shortcut', value => 'this_week'},
        unit_price => {op => 'eq', value => 999},   # not promoted: ignored
        missing => {op => 'eq', value => 1},
    });
    my $applied = $explorer->model($controller, $input);
    ok $applied->{state}->valid, 'the overridden view is valid';
    my %by_field = map { $_->{field} => $_ } @{$applied->{state}->filters};
    is $by_field{created_on}{value}, 'this_week', 'the promoted filter takes the shared value';
    ok $by_field{created_on}{promoted}, 'and stays promoted';
    is $by_field{unit_price}{op}, 'gte', 'other filters keep their operator';
    is $by_field{unit_price}{value}, 5, 'and value';
    is $applied->{state}->page, 1, 'back to the first page';
    is_deeply $applied->{state}->fields, $model->{state}->fields, 'fields are unchanged';

    my $between = $explorer->model($controller, $dashboard->apply_overrides($model->{state}, {
        created_on => {op => 'between', value => '2026-09-01', value_end => '2026-09-15'},
    }));
    my ($created) = grep { $_->{field} eq 'created_on' } @{$between->{state}->filters};
    is_deeply [@$created{qw(op value value_end)}], ['between', '2026-09-01', '2026-09-15'],
        'the operator can change too';
};

subtest 'result cache keyed by the exact SQL' => sub {
    my $cache = MemoryCache->new;
    my $executions = $TestSelectoComponents::Adapter::COUNT_EXECUTIONS // 0;
    my $first = $explorer->model($controller, $dashboard->input_from_url($saved), {result_cache => $cache});
    is $first->{result}{cache}{hit}, 0, 'the first run is a miss';
    ok $first->{result}{cache}{created_at}, 'with a timestamp';
    is scalar(keys %{$cache->{entries}}), 2, 'data and count results are stored';
    my $second = $explorer->model($controller, $dashboard->input_from_url($saved), {result_cache => $cache});
    is $second->{result}{cache}{hit}, 1, 'the same query hits';
    is $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, $executions + 1, 'without running the count again';
    is_deeply $second->{result}{records}, $first->{result}{records}, 'and returns the same rows';

    my $other = $explorer->model($controller,
        $dashboard->apply_overrides($model->{state}, {created_on => {op => 'date_shortcut', value => 'yesterday'}}),
        {result_cache => $cache});
    is $other->{result}{cache}{hit}, 0, 'different bound values are a different entry';

    my $statement = Selecto::Statement->new(sql => 'SELECT 1', params => [1], columns => ['a'], adapter_name => 'test');
    my $scoped = Selecto::Statement->new(sql => 'SELECT 1', params => [2], columns => ['a'], adapter_name => 'test');
    isnt $explorer->result_cache_key($statement), $explorer->result_cache_key($scoped),
        'e.g. a user with different client ids in scope gets their own entry';

    my $uncached = $explorer->model($controller, $dashboard->input_from_url($saved));
    ok !exists $uncached->{result}{cache}, 'Explorer runs uncached by default';
    eval { $explorer->model($controller, {}, {result_cache => {}}) };
    like $@, qr/result_cache must provide fetch and store/, 'a cache object is validated';
};

subtest 'tile bodies' => sub {
    my $table = $dashboard->tile_html($model);
    like $table, qr/<table/, 'detail views render a table';
    unlike $table, qr/sc-pagination|sc-result-meta|sc-promoted-filters/, 'without page furniture';

    my $graph = $explorer->model($controller, {
        q => 1, view => 'graph', chart_type => 'bar', field => 'product_name',
        group => 'category.category_name', measure => 'count',
    });
    like $dashboard->tile_html($graph), qr/data-sc-chart/, 'graph views render a chart';

    my $invalid = $explorer->model($controller, {q => 1, view => 'detail', field => 'nope'});
    like $dashboard->tile_html($invalid), qr/sc-alert/, 'invalid views render their errors';
};

subtest 'filter editor controls' => sub {
    my ($created) = @{$dashboard->promoted_filters($model->{config}, $model->{domain}, $model->{state})};
    my $html = $dashboard->filter_controls_html($model->{config}, $model->{domain}, $created);
    like $html, qr/data-sc-promoted-filter-input="op"/, 'a match-mode control';
    like $html, qr/data-op="date_shortcut"(?![^>]*hidden)/, 'the current mode is shown';
    like $html, qr/data-op="between"[^>]*hidden/, 'other modes are hidden';
    like $html, qr/<option value="today" selected>Today<\/option>/, 'with the current value selected';
};

subtest 'export authorizer' => sub {
    my $denied = Selecto::Components::Config->new(
        %{TestSelectoComponents::config()}, id => 'products', export_authorizer => sub { 0 },
    );
    ok !$denied->for_request($controller)->export_allowed, 'the host can deny exports';
    ok $config->for_request($controller)->export_allowed, 'allowed without an authorizer';
    my $answer = 1;
    my $shared = Selecto::Components::Config->new(
        %{TestSelectoComponents::config()}, id => 'shared', export_authorizer => sub { $answer },
    );
    ok $shared->export_allowed($controller), 'the shared configuration asks the authorizer';
    $answer = 0;
    ok !$shared->export_allowed($controller), 'and does not remember an earlier request\'s answer';
    my $copy = $shared->for_request($controller);
    ok !$copy->export_allowed, 'a request copy asks once';
    $answer = 1;
    ok !$copy->export_allowed, 'and keeps its answer for the request';
    my $page = Selecto::Components::Renderer->surface(
        Selecto::Components::Explorer->new(config => $denied)->model($controller, {q => 1, view => 'detail', field => 'product_name'}),
    );
    unlike $page, qr/data-sc-export-format/, 'export links are hidden when denied';
    like(Selecto::Components::Renderer->surface($model), qr/data-sc-export-format/, 'and shown otherwise');
    eval { Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'x', export_authorizer => 1) };
    like $@, qr/export_authorizer must be a coderef/, 'validated';
};

done_testing;

package MemoryCache;
use Time::HiRes qw(time);
sub new { bless {entries => {}}, shift }
sub fetch { my ($self, $key) = @_; return $self->{entries}{$key} }
sub store { my ($self, $key, $result) = @_; $self->{entries}{$key} = {result => $result, created_at => time} }
