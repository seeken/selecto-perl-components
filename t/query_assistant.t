use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::QueryContract;
use Selecto::Components::QueryAssistant::Draft;
use Selecto::Components::QueryAssistant::Store;
use Selecto::Components::QueryAssistant::Target;
use Selecto::Components::QueryAssistant::Tools;
use Selecto::Components::QueryAssistant::Validator;
use Selecto::Components::State;
use Selecto::Engine;
use Selecto::PostgreSQL;

{
    package TestQueryAssistantAdapter;
    use Mojo::Base 'TestSelectoComponents::Adapter', -signatures;
    our $EXECUTIONS = 0;
    sub execute_query ($self, @args) {
        $EXECUTIONS++;
        return $self->SUPER::execute_query(@args);
    }
}

my $store = Selecto::Components::QueryAssistant::Store->new;
my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'products',
    query_assistant => {
        store => $store, policy_version => 'test-v1',
        palettes => {ocean => ['#0b7285', '#74c0fc']},
    },
);
my $domain = TestSelectoComponents::domain();
my $engine = Selecto::Engine->new(
    domain => $domain,
    adapter => TestQueryAssistantAdapter->new(dbh => bless({}, 'TestSelectoComponents::DBH')),
);
my $state = Selecto::Components::State->from_input($config, $domain, {});
my $contract = Selecto::Components::QueryContract->build(
    config => $config, domain => $domain, state => $state, scope => 'actor-1',
);

is $contract->{query_contract_version}, 1, 'contract has an explicit version';
is $contract->{active_target}{view}, 'detail', 'contract exposes the active editable target';
ok !grep({ $_->{id} eq 'id' && $_->{internal} } @{$contract->{fields}}),
    'contract does not leak internal catalog metadata';
is_deeply $contract->{graph}{point_limit},
    {minimum => 100, default => 100, maximum => 100, page => 1},
    'graph point bounds remain usable below 250 without raising the host cap';

my $membership = Selecto::Components::QueryAssistant::Validator->validate(
    config => $config, domain => $domain, engine => $engine,
    target => {
        view => 'detail',
        fields => [{field => 'product_name'}], orders => [], limit => 25,
        filters => [{
            field => 'product_name', operator => 'in', value => ['A,B', ' C ', '', '雪'],
        }],
    },
);
ok $membership->{ok}, 'array-valued membership target validates';
is_deeply $membership->{state}->filters->[0]{values}, ['A,B', ' C ', '', '雪'],
    'membership values preserve commas, whitespace, empty strings, and Unicode';
my $membership_statement = Selecto::PostgreSQL->new(
    dbh => bless({}, 'TestSelectoComponents::CompileDBH'),
)->compile($domain, $membership->{prepared}{query});
is_deeply $membership_statement->params, ['A,B', ' C ', '', '雪'],
    'lossless membership values remain separate bound parameters';

my $graph_target = {
    view => 'graph', filters => [],
    groups => [{field => 'category.category_name'}],
    measures => [
        {
            id => 'total_price', function => 'sum', alias => 'Revenue',
            null_handling => 'auto', series_id => 'revenue', chart_type => 'bar',
            axis => 'left', stack => 'sales', color => '#2563EB', transforms => [],
        },
        {
            id => 'total_price', function => 'sum', alias => 'Revenue average',
            null_handling => 'sql', series_id => 'revenue_average', chart_type => 'line',
            axis => 'left', stack => undef, color => '#F97316',
            transforms => [{type => 'moving_average', parameters => {window => 3}}],
        },
    ],
    graph => {chart_type => 'bar', show_table => 1}, limit => 100,
};
my $validation = Selecto::Components::QueryAssistant::Validator->validate(
    config => $config, domain => $domain, engine => $engine, target => $graph_target,
);
ok $validation->{ok}, 'a complete mixed graph target validates and compiles'
    or diag explain $validation;
is $TestQueryAssistantAdapter::EXECUTIONS, 0,
    'validation compiles without executing a report or count query';
is $validation->{normalized_target}{measures}[0]{color}, '#2563eb',
    'explicit series colors normalize through ordinary state';
is $validation->{normalized_target}{measures}[0]{stack}, 'sales',
    'named stacks survive target normalization';
is $validation->{normalized_target}{measures}[1]{null_handling}, 'sql',
    'NULL policy remains distinct from its derived aggregate behavior';
ok $validation->{normalized_target}{graph}{show_table},
    'raw aggregate table preference survives normalization';

my $record = Selecto::Components::QueryAssistant::Draft->create(
    store => $store, owner => 'owner-1', config => $config, state => $state,
    context_version => $contract->{context_version},
);
my $applied = Selecto::Components::QueryAssistant::Draft->apply(
    store => $store, id => $record->{id}, owner => 'owner-1', config => $config,
    domain => $domain, engine => $engine, context_version => $contract->{context_version},
    base_revision => 0, request_id => 'request-1', target => $graph_target,
);
ok $applied->{ok}, 'draft applies atomically' or diag explain $applied;
is $applied->{revision}, 1, 'draft revision advances once';
ok $applied->{undo_token}, 'apply creates one opaque undo token';
is $TestQueryAssistantAdapter::EXECUTIONS, 0, 'draft application still executes no report';

my $replay = Selecto::Components::QueryAssistant::Draft->apply(
    store => $store, id => $record->{id}, owner => 'owner-1', config => $config,
    domain => $domain, engine => $engine, context_version => $contract->{context_version},
    base_revision => 0, request_id => 'request-1', target => $graph_target,
);
is $replay->{revision}, 1, 'idempotent replay returns the original receipt';

my $stale = Selecto::Components::QueryAssistant::Draft->apply(
    store => $store, id => $record->{id}, owner => 'owner-1', config => $config,
    domain => $domain, engine => $engine, context_version => $contract->{context_version},
    base_revision => 0, request_id => 'request-2', target => $graph_target,
);
is $stale->{code}, 'revision_conflict', 'stale application is rejected';

my $undone = Selecto::Components::QueryAssistant::Draft->undo(
    store => $store, id => $record->{id}, owner => 'owner-1', base_revision => 1,
    undo_token => $applied->{undo_token},
);
ok $undone->{ok}, 'current assistant edit can be undone';
is $undone->{target}{view}, 'detail', 'undo restores the pre-assistant target';

my $inactive_state = Selecto::Components::State->from_input($config, $domain, {
    view => 'detail', field => ['product_name'], limit => 25,
    chart_type => 'line', graph_palette => 'ocean', graph_show_table => 1,
    group => ['category.category_name'], measure => ['total_price'],
    measure_function => ['sum'], measure_color => ['#abcdef'],
    measure_fill_opacity => ['0.35'],
});
my $inactive_record = Selecto::Components::QueryAssistant::Draft->create(
    store => $store, owner => 'owner-2', config => $config, state => $inactive_state,
    context_version => $contract->{context_version},
);
my $detail_change = Selecto::Components::QueryAssistant::Draft->apply(
    store => $store, id => $inactive_record->{id}, owner => 'owner-2', config => $config,
    domain => $domain, engine => $engine, context_version => $contract->{context_version},
    base_revision => 0, request_id => 'preserve-inactive', target => {
        view => 'detail', fields => [{field => 'product_name'}, {field => 'unit_price'}],
        orders => [], filters => [], limit => 25,
    },
);
ok $detail_change->{ok}, 'detail edit validates with inactive graph configuration';
is $detail_change->{input}{graph_palette}, 'ocean', 'inactive graph palette survives an assistant detail edit';
is $detail_change->{input}{measure_color}, '#abcdef',
    'inactive graph series colors survive an assistant detail edit';

my $limited_store = Selecto::Components::QueryAssistant::Store->new(max_drafts_per_owner => 1);
$limited_store->create({owner => 'quota-owner'});
my $quota_ok = eval { $limited_store->create({owner => 'quota-owner'}); 1 };
ok !$quota_ok, 'the in-memory store enforces a per-owner draft quota';
like $@, qr/quota exceeded/, 'quota failures are explicit';

my $bad = Selecto::Components::QueryAssistant::Validator->validate(
    config => $config, domain => $domain, engine => $engine,
    target => {%$graph_target, limit => 99},
);
ok !$bad->{ok}, 'strict target validation rejects a silently coerced graph point limit';
like $bad->{errors}[0]{message}, qr/100 through 100/, 'point-limit diagnostic publishes the supported range';

is scalar(@{Selecto::Components::QueryAssistant::Tools->definitions}), 5,
    'the fixed browser surface contains exactly five tools';

done_testing;
