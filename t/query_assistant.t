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
    query_assistant => {allow_anonymous => 1,
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
    store => $store, id => $record->{id}, owner => 'owner-1', config => $config,
    context_version => $contract->{context_version}, base_revision => 1,
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


subtest 'assistant roundtrips grouped and alternative predicates' => sub {
    my $filtered = Selecto::Components::State->from_input($config, $domain, {
        q => 1, view => 'detail', field => ['product_name'], limit => 25,
        group => ['created_on'], group_format => ['month'],
        filter_field => ['product_name', 'product_name', 'created_on'],
        filter_op => ['eq', 'eq', 'eq'], filter_value => ['A', 'B', '2026-09'],
        filter_group => [0, 0, 1], filter_clause => [1, 2, ''],
    });
    ok $filtered->valid, 'the existing grouped/OR state is valid' or diag explain $filtered->errors;
    my $target = Selecto::Components::QueryAssistant::Target->from_state($filtered);
    is scalar(@{$target->{filters}}), 3, 'every active predicate is published';
    my $record = Selecto::Components::QueryAssistant::Draft->create(
        store => $store, owner => 'filter-owner', config => $config, state => $filtered,
        context_version => $contract->{context_version},
    );
    $target->{fields} = [{field => 'product_name'}, {field => 'unit_price'}];
    my $result = Selecto::Components::QueryAssistant::Draft->apply(
        store => $store, id => $record->{id}, owner => 'filter-owner', config => $config,
        domain => $domain, engine => $engine, context_version => $contract->{context_version},
        base_revision => 0, request_id => 'keep-predicates', target => $target,
    );
    ok $result->{ok}, 'changing selected fields retains the full governed predicate' or diag explain $result;
    my $again = Selecto::Components::State->from_input($config, $domain, $result->{input});
    is_deeply $again->filters, $filtered->filters, 'OR clauses and formatted drilldown predicate survive';
    my $validation = Selecto::Components::QueryAssistant::Validator->validate(
        config => $config, domain => $domain, engine => $engine,
        target => $result->{target}, preserve_input => $result->{input},
    );
    my $compiled = Selecto::PostgreSQL->new(
        dbh => bless({}, 'TestSelectoComponents::CompileDBH'),
    )->compile($domain, $validation->{prepared}{query});
    like $compiled->sql, qr/\bOR\b/, 'the preserved alternatives compile as OR';
    is_deeply $compiled->params, ['2026-09', 'A', 'B'], 'every predicate remains bound';
};

subtest 'draft mutations enforce explorer and current context' => sub {
    my $other = Selecto::Components::Config->new(
        %{TestSelectoComponents::config()}, id => 'other_products',
        query_assistant => {allow_anonymous => 1,store => $store},
    );
    for my $method (qw(sync undo)) {
        my %args = (store => $store, id => $inactive_record->{id}, owner => 'owner-2',
            config => $other, context_version => $contract->{context_version}, base_revision => 1,
            state => $state, input => {}, undo_token => $detail_change->{undo_token});
        is(Selecto::Components::QueryAssistant::Draft->$method(%args)->{code}, 'forbidden',
            "$method cannot access another explorer's draft");
        $args{config} = $config;
        $args{context_version} = 'changed';
        is(Selecto::Components::QueryAssistant::Draft->$method(%args)->{code}, 'context_changed',
            "$method cannot restore or sync under a changed scope");
    }
    my $different = Selecto::Components::QueryAssistant::Draft->apply(
        store => $store, id => $inactive_record->{id}, owner => 'owner-2', config => $config,
        domain => $domain, engine => $engine, context_version => $contract->{context_version},
        base_revision => 0, request_id => 'preserve-inactive', target => $graph_target,
    );
    is $different->{code}, 'request_conflict', 'reusing an idempotency key with another target is rejected';
    is $store->get($inactive_record->{id})->{revision}, 1, 'rejected operations leave the stored revision unchanged';
};

subtest 'graph grouping and explicit row grain survive target validation' => sub {
    my $target = {%$graph_target, rows_of => '-', graph => {
        %{$graph_target->{graph}}, series_group => 'category.category_name',
    }};
    my $result = Selecto::Components::QueryAssistant::Validator->validate(
        config => $config, domain => $domain, engine => $engine, target => $target,
    );
    ok $result->{ok}, 'current graph series grouping validates' or diag explain $result;
    is $result->{normalized_target}{graph}{series_group}, 'category.category_name', 'series grouping stays in target';
    is $result->{normalized_target}{rows_of}, '-', 'explicit root grain stays in target';
    my $again = Selecto::Components::QueryAssistant::Validator->validate(
        config => $config, domain => $domain, engine => $engine,
        target => $result->{normalized_target}, preserve_input => $result->{input},
    );
    is_deeply $again->{normalized_target}, $result->{normalized_target}, 'normalized target roundtrips without changes';
};


subtest 'manual edits to inactive state invalidate assistant undo' => sub {
    my $current = $store->get($inactive_record->{id});
    my %input = %{$current->{input}};
    $input{graph_palette} = 'default';
    my $edited = Selecto::Components::State->from_input($config, $domain, \%input);
    my $result = Selecto::Components::QueryAssistant::Draft->sync(
        store => $store, id => $current->{id}, owner => 'owner-2', config => $config,
        context_version => $contract->{context_version}, base_revision => 1,
        state => $edited, input => \%input,
    );
    is $result->{revision}, 2, 'an inactive presentation edit advances the authoritative revision';
    my $stored = $store->get($current->{id});
    is $stored->{input}{graph_palette}, 'default', 'the current inactive preference is saved';
    ok !$stored->{undo}, 'a manual state edit invalidates assistant undo';
    is_deeply $stored->{receipts}, {}, 'manual state edits invalidate prior idempotency receipts';
    my %equivalent = (%input, query_signature => 'untrusted-signature', csrf_token => 'discarded');
    my $same = Selecto::Components::QueryAssistant::Draft->sync(
        store => $store, id => $current->{id}, owner => 'owner-2', config => $config,
        context_version => $contract->{context_version}, base_revision => 2,
        state => $edited, input => \%equivalent,
    );
    ok $same->{no_op}, 'transport-only state does not advance the revision';
};

subtest 'group formatting roundtrips in a complete target' => sub {
    my $target = {
        view => 'aggregate', filters => [], limit => 25,
        groups => [
            {field => 'unit_price', format => 'buckets', bucket_ranges => '0-10, 11+', prefix_length => 2, exclude_articles => 0},
            {field => 'product_name', format => 'text_prefix', prefix_length => 4, exclude_articles => 1},
        ],
        measures => [{id => 'total_price', function => 'sum'}],
    };
    my $first = Selecto::Components::QueryAssistant::Validator->validate(
        config => $config, domain => $domain, engine => $engine, target => $target,
    );
    ok $first->{ok}, 'bucket and prefix groups validate' or diag explain $first;
    is $first->{normalized_target}{groups}[0]{bucket_ranges}, '0-10, 11+', 'bucket ranges are published in the normalized target';
    is $first->{normalized_target}{groups}[1]{prefix_length}, 4, 'prefix length is published in the normalized target';
    my $second = Selecto::Components::QueryAssistant::Validator->validate(
        config => $config, domain => $domain, engine => $engine,
        target => $first->{normalized_target}, preserve_input => $first->{input},
    );
    is_deeply $second->{normalized_target}, $first->{normalized_target}, 'all normalized grouping settings roundtrip';
};

subtest 'explicit association grain uses its catalog and survives validation' => sub {
    my $retargeted = Selecto::Components::State->from_input($config, $domain, {
        q => 1, view => 'detail', rows_of => 'category', field => ['category.category_name'],
        order => ['category.category_name'], direction => ['asc'], limit => 25,
    });
    ok $retargeted->valid, 'an explicit association grain is valid' or diag explain $retargeted->errors;
    my $target = Selecto::Components::QueryAssistant::Target->from_state($retargeted);
    my $roundtrip = Selecto::Components::QueryAssistant::Validator->validate(
        config => $config, domain => $domain, engine => $engine, target => $target,
    );
    ok $roundtrip->{ok}, 'an association-grain target compiles' or diag explain $roundtrip;
    is $roundtrip->{state}->retarget, 'category', 'the chosen association grain is retained';
    my $context = Selecto::Components::QueryContract->build(
        config => $config, domain => $domain, state => $retargeted, scope => 'actor-1',
    );
    ok !grep({ $_->{id} eq 'product_name' } @{$context->{fields}}), 'the explicit grain context offers its own fields';
    is $context->{context_version}, $contract->{context_version}, 'editing the grain does not invalidate a stable authorization context';
};

subtest 'choice publication changes the authorization context' => sub {
    my $reconfigured = Selecto::Components::Config->new(
        %{TestSelectoComponents::config()}, id => 'products', query_assistant => {allow_anonymous => 1,
            store => $store, policy_version => 'test-v1', palettes => {ocean => ['#0b7285', '#74c0fc']},
            choice_fields => {product_name => 1},
        },
    );
    my $new = Selecto::Components::QueryContract->build(
        config => $reconfigured, domain => $domain, state => $state, scope => 'actor-1',
    );
    isnt $new->{context_version}, $contract->{context_version}, 'changing host choice publication changes the version at an unchanged domain fingerprint';
};

done_testing;
