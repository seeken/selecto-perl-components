use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Storable qw(dclone);
use Test::More;
use TestSelectoComponents ();
use Selecto::Components::Templates::SourceExecutor;
use Selecto::Components::Templates::PageCursor ();
use Selecto::Components::Templates::RootCursor ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

my $manifest = TestSelectoComponents::template_order_manifest();
my $catalog = TestSelectoComponents::template_domain_catalog();
my $effect = Selecto::Templates->mount_runtime(
    $manifest,
    instance_id => 'source-executor-perl',
    release_id => 'source-executor-release',
    inputs => {},
)->{effects}[0];
$effect->{bindings}{state}{search} = 'PO-100';

my $dbh = TemplateSourceDBH->new(
    rows => [[1, 'PO-100', '2026-09-21T12:00:00Z', 'open', 44]],
    pg_type => [qw(int4 text timestamptz text int4)],
);
my $authorization_calls = 0;
my $authorize = sub {
    my ($source, $received_effect) = @_;
    $authorization_calls++;
    is $source->{id}, 'orders', 'executor resolves the source from the server manifest';
    is $received_effect->{generation}, 1, 'authorization receives the data-only effect';

    my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {
        status => 'ok',
        engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))
            ->limit(10),
    };
};

my $executed = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
);
is $executed->{status}, 'ok', 'authorized source execution succeeds';
is $authorization_calls, 1, 'host authorization runs once for the effect';
is_deeply(
    $executed->{result},
    [{
        id => 1,
        order_number => 'PO-100',
        ordered_at => '2026-09-21T12:00:00',
        status => 'open',
        customer => {id => 44},
    }],
    'native positional rows are projected into portable source data',
);
my $filtered_manifest;
{
    my $path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-filtered-total.compile.json";
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    $filtered_manifest = JSON::PP->new->utf8->decode(<$handle>);
}
my $filtered_effect = Selecto::Templates->mount_runtime(
    $filtered_manifest,
    instance_id => 'filtered-source-perl',
    release_id => 'filtered-source-release',
    inputs => {},
)->{effects}[0];
$filtered_effect->{bindings}{state}{search} = 'PO-100';
my $filtered_authorize = sub {
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders_nested}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))
            ->limit(1),
    };
};
my $no_snapshot = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $filtered_manifest, effect => $filtered_effect,
    authorize => $filtered_authorize,
);
is $no_snapshot->{code}, 'source_snapshot_unavailable',
    'declared filtered total fails closed without a host snapshot';
my $snapshot_calls = 0;
my $under_budget = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $filtered_manifest, effect => $filtered_effect,
    authorize => $filtered_authorize,
    resource_budget => {max_source_statements => 1},
    snapshot_run => sub { die 'two-statement source must not execute' },
);
is $under_budget->{code}, 'source_budget_exceeded',
    'two-statement source fails its host statement budget before execution';
my $filtered = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $filtered_manifest, effect => $filtered_effect,
    authorize => $filtered_authorize,
    snapshot_run => sub {
        my ($engine, $page, $counts, $effect, $roles) = @_;
        $snapshot_calls++;
        is_deeply $roles, ['page', 'filtered_total:order_count'],
            'snapshot runner receives the accounted statement roles';
        is $page->limit_value, 1, 'snapshot keeps the host page limit';
        ok !defined($counts->{order_count}->limit_value),
            'snapshot count removes the root page limit';
        return {rows => [[1, 'PO-100']], totals => {order_count => 2}};
    },
);
is $filtered->{status}, 'ok', 'host accepts a declared filtered total snapshot';
is $snapshot_calls, 1, 'page and count use one snapshot callback';
is_deeply($filtered->{result},
    {rows => [{id => 1, order_number => 'PO-100'}], totals => {order_count => 2}},
    'filtered total stays in the source result envelope');
my $page_filtered_manifest;
{
    my $path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-page-filtered-total.compile.json";
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    $page_filtered_manifest = JSON::PP->new->utf8->decode(<$handle>);
}
my $page_filtered_effect = Selecto::Templates->mount_runtime(
    $page_filtered_manifest,
    instance_id => 'page-filtered-source-perl',
    release_id => 'page-filtered-source-release',
    inputs => {},
)->{effects}[0];
$page_filtered_effect->{bindings}{state}{search} = 'PO-100';
my $page_filtered = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_filtered_manifest, effect => $page_filtered_effect,
    authorize => $filtered_authorize,
    snapshot_run => sub {
        my ($engine, $page, $counts, $effect, $roles) = @_;
        is_deeply $roles, ['page', 'filtered_total:order_count'],
            'page count adds no source statement';
        is_deeply [sort keys %$counts], ['order_count'],
            'snapshot runner receives only the filtered count query';
        return {rows => [[1, 'PO-100']], totals => {order_count => 3}};
    },
);
is_deeply($page_filtered->{result},
    {rows => [{id => 1, order_number => 'PO-100'}],
     totals => {page_count => 1, order_count => 3}},
    'page and filtered counts share one source result');
my $page_only_manifest = dclone($page_filtered_manifest);
$page_only_manifest->{sources}[0]{query}{source_totals} = [
    grep { $_->{scope} eq 'page' }
        @{$page_only_manifest->{sources}[0]{query}{source_totals}}
];
my $page_only = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_only_manifest, effect => $page_filtered_effect,
    authorize => $filtered_authorize,
    resource_budget => {max_source_statements => 1},
    run => sub { return {rows => [[1, 'PO-100']]}; },
);
is_deeply($page_only->{result},
    {rows => [{id => 1, order_number => 'PO-100'}], totals => {page_count => 1}},
    'page-only count uses the one authorized page statement');
my $related_manifest;
{
    my $path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-related-source-totals.compile.json";
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    $related_manifest = JSON::PP->new->utf8->decode(<$handle>);
}
my $related_effect = Selecto::Templates->mount_runtime(
    $related_manifest,
    instance_id => 'related-source-perl', release_id => 'related-source-release',
    inputs => {},
)->{effects}[0];
$related_effect->{bindings}{state}{search} = 'PO-100';
my $related_under_budget = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $related_manifest, effect => $related_effect,
    authorize => $filtered_authorize,
    resource_budget => {max_source_statements => 4},
    snapshot_run => sub { die 'budget must reject before snapshot' },
);
is $related_under_budget->{code}, 'source_budget_exceeded',
    'four related totals reserve four statements beside the page';
my $related = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $related_manifest, effect => $related_effect,
    authorize => $filtered_authorize,
    resource_budget => {max_source_statements => 5},
    snapshot_run => sub {
        my ($engine, $page, $totals, $effect, $roles) = @_;
        is_deeply($roles, ['page',
            'filtered_total:filtered_line_count', 'filtered_total:filtered_quantity',
            'page_total:page_line_count', 'page_total:page_quantity'],
            'related total roles account for all five statements');
        ok(!defined($totals->{filtered_quantity}{query}->limit_value),
            'filtered related total drops the root page limit');
        is($totals->{page_quantity}{query}->limit_value, 1,
            'page related total keeps the root page limit');
        return {
            rows => [[1, 'PO-100', '[{"id":11,"sku":"A","quantity":2}]']],
            totals => {page_quantity => '3', filtered_quantity => '7',
                       page_line_count => 2, filtered_line_count => 3},
        };
    },
);
is $related->{status}, 'ok', 'host accepts related totals in the shared result';
is_deeply($related->{result}{totals},
    {page_quantity => '3', filtered_quantity => '7',
     page_line_count => 2, filtered_line_count => 3},
    'related page and filtered totals remain at source level');
my $prepared = $dbh->prepared->[0];
like $prepared->sql, qr/"s0"\."tenant_id"/, 'native SQL retains tenant scope';
ok scalar(grep { defined($_) && !ref($_) && $_ eq '7' } @{$prepared->params}),
    'tenant scope stays bound';
ok scalar(grep { defined($_) && !ref($_) && $_ eq 'open' } @{$prepared->params}),
    'host membership stays bound';
ok scalar(grep { defined($_) && !ref($_) && $_ eq 'PO-100' } @{$prepared->params}),
    'template search stays bound';

my $not_called = 0;
my $unknown = {%$effect, source => 'missing'};
my $unknown_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $unknown,
    authorize => sub { $not_called++; return undef },
);
is $unknown_result->{code}, 'unknown_source', 'unknown sources fail before authorization';
is $not_called, 0, 'unknown sources never reach host authorization';

my $denied = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => sub { return {status => 'error', token => 'must-not-escape'} },
);
is $denied->{code}, 'source_authorization_failed', 'authorization denial is bounded';
unlike(
    JSON::PP->new->canonical->encode($denied),
    qr/must-not-escape/,
    'authorization detail does not escape',
);

my $execution_failed = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    run => sub { die "password=must-not-escape\n" },
);
is $execution_failed->{code}, 'source_execution_failed', 'execution failure is bounded';
unlike(
    JSON::PP->new->canonical->encode($execution_failed),
    qr/must-not-escape/,
    'database detail does not escape',
);

my $invalid_rows = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    run => sub { return {rows => [[1]]} },
);
is $invalid_rows->{code}, 'invalid_source_result', 'invalid native rows fail projection';

my $budget_runs = 0;
for my $budget (
    {max_root_rows => 5},
    {max_result_nodes => 5},
) {
    my $over_budget = Selecto::Components::Templates::SourceExecutor->execute(
        manifest => $manifest,
        effect => $effect,
        authorize => $authorize,
        resource_budget => $budget,
        run => sub { $budget_runs++; return {rows => []} },
    );
    is $over_budget->{code}, 'source_budget_exceeded',
        'host source budget rejects the effective query';
}
is $budget_runs, 0, 'over-budget sources never reach the query runner';

my $invalid_budget = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    resource_budget => {max_root_rows => 0},
    run => sub { $budget_runs++ },
);
is $invalid_budget->{code}, 'invalid_source_budget',
    'invalid host budget fails closed';
is $budget_runs, 0, 'invalid host budget never reaches the query runner';

my $oversized_effect = dclone($effect);
$oversized_effect->{bindings}{state}{search} = 'x' x 200;
my $input_authorization_calls = 0;
my $oversized_input = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $oversized_effect,
    authorize => sub { $input_authorization_calls++; return $authorize->(@_) },
    resource_budget => {max_input_bytes => 100},
);
is $oversized_input->{code}, 'source_input_too_large',
    'source effect above the host byte limit is rejected';
is $input_authorization_calls, 0,
    'oversized source effect never reaches host authorization';

my $excess_roots = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    run => sub {
        return {rows => [map {
            [$_, "PO-$_", '2026-09-21T12:00:00Z', 'open', 44]
        } 1 .. 11]};
    },
);
is $excess_roots->{code}, 'source_budget_exceeded',
    'native rows beyond the effective host query limit are not returned';

my $oversized_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    resource_budget => {max_result_bytes => 80},
    run => sub {
        return {rows => [[1, 'x' x 200, '2026-09-21T12:00:00Z', 'open', 44]]};
    },
);
is $oversized_result->{code}, 'source_result_too_large',
    'projected response above the host byte limit is not returned';

my $top_n_manifest = TestSelectoComponents::_protocol_fixture(
    'order-lines-top-n.compile.json',
);
my $nested_effect = Selecto::Templates->mount_runtime(
    $top_n_manifest,
    instance_id => 'budget-nested-perl',
    release_id => 'budget-nested-release',
    inputs => {},
)->{effects}[0];
$nested_effect->{bindings}{state}{search} = 'PO-100';
$nested_effect->{bindings}{state}{warehouse} = 'A1';
my $nested_authorize = sub {
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders_nested}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {status => 'ok', engine => $engine, query => $engine->query->limit(10)};
};
my $nested_runs = 0;
my $nested_run = sub { $nested_runs++; return {rows => []} };

my $nested_admitted = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $top_n_manifest,
    effect => $nested_effect,
    authorize => $nested_authorize,
    resource_budget => {max_result_nodes => 30, max_collection_depth => 2},
    run => $nested_run,
);
is $nested_admitted->{status}, 'ok',
    'two-level top-N source fits its exact projected-node and depth budget';
is $nested_runs, 1, 'admitted nested source reaches its runner';

for my $budget (
    {max_result_nodes => 29},
    {max_collection_depth => 1},
) {
    my $rejected = Selecto::Components::Templates::SourceExecutor->execute(
        manifest => $top_n_manifest,
        effect => $nested_effect,
        authorize => $nested_authorize,
        resource_budget => $budget,
        run => $nested_run,
    );
    is $rejected->{code}, 'source_budget_exceeded',
        'nested projected-node or depth budget rejects the source';
}
is $nested_runs, 1, 'rejected nested sources never reach the runner';

my $unbounded_manifest = dclone($top_n_manifest);
delete $unbounded_manifest->{sources}[0]{query}{collections}[0]{max_items};
my $unbounded = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $unbounded_manifest,
    effect => $nested_effect,
    authorize => $nested_authorize,
    run => $nested_run,
);
is $unbounded->{code}, 'unbounded_collection',
    'a collection without max-items cannot pass host budget admission';
is $nested_runs, 1, 'unbounded collection never reaches the runner';

my $excess_lines = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $top_n_manifest,
    effect => $nested_effect,
    authorize => $nested_authorize,
    run => sub {
        return {rows => [[1, 'PO-100', JSON::PP->new->encode([
            {id => 11, sku => 'A', quantity => 2, allocations => []},
            {id => 12, sku => 'B', quantity => 1, allocations => []},
        ])]]};
    },
);
is $excess_lines->{code}, 'source_budget_exceeded',
    'native rows that violate compiled max-items are not returned';

my $page_manifest = dclone($top_n_manifest);
$page_manifest->{sources}[0]{query}{collections}[0]{page_size} = 1;
$page_manifest->{sources}[0]{query}{collections}[0]{max_items} = 2;
$page_manifest->{sources}[0]{query}{collections}[0]{primary_key} = 'id';
$page_manifest->{sources}[0]{query}{collections}[0]{collections}[0]{page_size} = 1;
$page_manifest->{sources}[0]{query}{collections}[0]{collections}[0]{max_items} = 2;
$page_manifest->{sources}[0]{query}{collections}[0]{collections}[0]{primary_key} = 'id';
my $page_run = sub {
    return {rows => [[1, 'PO-100', JSON::PP->new->encode([
        {id => 11, sku => 'A', quantity => 2, allocations => [
            {id => 111, warehouse => 'A1', quantity => 1},
            {id => 110, warehouse => 'A1', quantity => 1},
        ]},
        {id => 12, sku => 'B', quantity => 1, allocations => []},
    ])]]};
};
my $page_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_manifest,
    effect => $nested_effect,
    authorize => $nested_authorize,
    run => $page_run,
);
is($page_result->{status}, 'ok',
    'host executor accepts a candidate bounded first-page result');
is_deeply($page_result->{result}{rows}, [{
    id => 1, order_number => 'PO-100',
    lines => [{
        id => 11, sku => 'A', quantity => 2,
        allocations => [{id => 111, warehouse => 'A1', quantity => 1}],
    }],
}], 'host result envelope carries only visible public rows');
is_deeply([map {[$_->{parent_path}, $_->{has_more} ? 1 : 0]}
    @{$page_result->{result}{pages}}],
    [[[1], 1], [[1, 11], 1]],
    'host result envelope keeps separate internal parent positions');
is_deeply([map {[$_->{parent_path}, $_->{row_keys}]}
    @{$page_result->{result}{identities}}],
    [[[1], [11]], [[1, 11], [111]]],
    'host result envelope keeps private row keys for nested page merging');
my $page_scope = {
    tenant_id => 'tenant-7', principal_id => 'actor-1',
    authorization_revision => 'acl-2', membership_revision => 'open-orders-v1',
};
my $page_secret = 's' x 32;
my $page_source = $page_manifest->{sources}[0];
my $page_snapshot = {
    instance_id => 'budget-nested-perl',
    release_id => 'budget-nested-release',
    template_fingerprint => $page_manifest->{template}{fingerprint},
    inputs => $nested_effect->{bindings}{input},
    state => $nested_effect->{bindings}{state},
    sources => {
        $page_source->{id} => {
            status => 'ready', generation => 1,
            result => $page_result->{result},
        },
    },
};
my $issued_pages = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $page_snapshot, source_id => $page_source->{id},
    source_plan => $page_source, scope => $page_scope,
    secret => $page_secret, now => 1000, ttl_seconds => 60,
);
is $issued_pages->{status}, 'ok', 'executor page positions issue opaque host cursors';
my $scoped_authorize = sub {
    my $authority = $nested_authorize->(@_);
    $authority->{page_scope} = $page_scope;
    return $authority;
};
my @continued_statements;
my $continuation_index = 0;
my $continued_run = sub {
    my ($engine, $query) = @_;
    push @continued_statements, $engine->compile($query);
    my $children = $continuation_index++ == 0
        ? [{id => 12, sku => 'B', quantity => 1, allocations => [
            {id => 122, warehouse => 'A1', quantity => 1},
            {id => 121, warehouse => 'A1', quantity => 1},
        ]}]
        : [{id => 11, sku => 'A', quantity => 2, allocations => [
            {id => 110, warehouse => 'A1', quantity => 1},
        ]}];
    return {rows => [[1, 'PO-100', JSON::PP->new->encode($children)]]};
};
my $continued_line_result;
for my $index (0, 1) {
    my $continued = Selecto::Components::Templates::SourceExecutor->execute(
        manifest => $page_manifest, effect => $nested_effect,
        authorize => $scoped_authorize, run => $continued_run,
        page_snapshot => $page_snapshot,
        page_cursor => $issued_pages->{pages}[$index]{token},
        page_secret => $page_secret,
        page_now => 1001, page_ttl_seconds => 60,
    );
    is $continued->{status}, 'ok',
        'host resolves opaque cursor after fresh authorization and runs query';
    if ($index == 0) {
        $continued_line_result = $continued->{result};
        is_deeply([map { $_->{id} } @{$continued->{result}{rows}[0]{lines}}],
            [11, 12], 'line continuation appends to the selected parent');
        is_deeply($continued->{result}{identities}[0]{row_keys}, [11, 12],
            'merged line identities align with visible rows');
        ok(!$continued->{result}{pages}[0]{has_more},
            'line cursor reaches the final page');
        ok($continued->{result}{pages}[1]{has_more},
            'unrelated allocation cursor retains its position');
    } else {
        is_deeply([map { $_->{id} }
            @{$continued->{result}{rows}[0]{lines}[0]{allocations}}],
            [111, 110], 'nested continuation appends to its hidden parent');
        is_deeply($continued->{result}{identities}[1]{row_keys}, [111, 110],
            'merged nested identities align with visible rows');
        ok($continued->{result}{pages}[0]{has_more},
            'unrelated line cursor retains its position');
        ok(!$continued->{result}{pages}[1]{has_more},
            'allocation cursor reaches the final page');
    }
}
ok(scalar(grep { defined($_) && $_ eq '11' }
    @{$continued_statements[0]->params}),
    'line continuation reaches native parent-bound query parameters');
ok(scalar(grep { defined($_) && $_ eq '111' }
    @{$continued_statements[1]->params}),
    'allocation continuation reaches its own parent-bound query parameters');
my $later_snapshot = dclone($page_snapshot);
$later_snapshot->{sources}{$page_source->{id}}{result} = $continued_line_result;
my $later_issued = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $later_snapshot, source_id => $page_source->{id},
    source_plan => $page_source, scope => $page_scope,
    secret => $page_secret, now => 1001, ttl_seconds => 60,
);
is $later_issued->{status}, 'ok',
    'later loaded line can issue a separate nested cursor';
my ($later_cursor) = grep {
    join(',', @{$_->{parent_path}}) eq '1,12'
} @{$later_issued->{pages}};
ok($later_cursor->{token}, 'later loaded line exposes an opaque nested cursor');
my $later_statement;
my $later_nested = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_manifest, effect => $nested_effect,
    authorize => $scoped_authorize,
    page_snapshot => $later_snapshot,
    page_cursor => $later_cursor->{token},
    page_secret => $page_secret,
    page_now => 1002, page_ttl_seconds => 60,
    run => sub {
        my ($engine, $query) = @_;
        $later_statement = $engine->compile($query);
        return {rows => [[1, 'PO-100', JSON::PP->new->encode([
            {id => 12, sku => 'B', quantity => 1, allocations => [
                {id => 121, warehouse => 'A1', quantity => 1},
            ]},
        ])]]};
    },
);
is $later_nested->{status}, 'ok',
    'host follows nested cursor after its parent was loaded on a later page';
like($later_statement->sql, qr/"c_lines"\."id"\s*=\s*\$[0-9]+/,
    'nested host query binds the trusted later line identity');
is_deeply([map { $_->{id} } @{$later_nested->{result}{rows}[0]{lines}}],
    [11, 12], 'host keeps both accumulated ancestor rows');
is_deeply([map { $_->{id} }
    @{$later_nested->{result}{rows}[0]{lines}[1]{allocations}}],
    [122, 121], 'host appends only the later line nested child');
my ($later_terminal) = grep {
    join(',', @{$_->{parent_path}}) eq '1,12'
} @{$later_nested->{result}{pages}};
ok(!$later_terminal->{has_more}, 'later nested collection reaches its final page');
my $expired_cursor = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_manifest, effect => $nested_effect,
    authorize => $scoped_authorize,
    run => sub { die 'expired cursor must not execute' },
    page_snapshot => $page_snapshot,
    page_cursor => $issued_pages->{pages}[0]{token},
    page_secret => $page_secret,
    page_now => 1061, page_ttl_seconds => 60,
);
is $expired_cursor->{code}, 'invalid_page_cursor',
    'expired browser cursor is rejected before native execution';
my $unscoped_cursor = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_manifest, effect => $nested_effect,
    authorize => $nested_authorize,
    run => sub { die 'unscoped cursor must not execute' },
    page_snapshot => $page_snapshot,
    page_cursor => $issued_pages->{pages}[0]{token},
    page_secret => $page_secret,
    page_now => 1001, page_ttl_seconds => 60,
);
is $unscoped_cursor->{code}, 'invalid_page_cursor',
    'continuation requires fresh authorization scope';
my $changed_effect = dclone($nested_effect);
$changed_effect->{bindings}{state}{search} = 'changed';
my $changed_cursor = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_manifest, effect => $changed_effect,
    authorize => $scoped_authorize,
    run => sub { die 'changed bindings must not execute' },
    page_snapshot => $page_snapshot,
    page_cursor => $issued_pages->{pages}[0]{token},
    page_secret => $page_secret,
    page_now => 1001, page_ttl_seconds => 60,
);
is $changed_cursor->{code}, 'invalid_page_cursor',
    'effect binding drift is rejected before native execution';
my $public_bytes = length(JSON::PP->new->utf8->canonical->encode(
    $page_result->{result}{rows},
));
my $page_over_bytes = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $page_manifest,
    effect => $nested_effect,
    authorize => $nested_authorize,
    resource_budget => {max_result_bytes => $public_bytes + 1},
    run => $page_run,
);
is($page_over_bytes->{code}, 'source_result_too_large',
    'host byte budget includes private page metadata');

my $partial_manifest = dclone($top_n_manifest);
$partial_manifest->{sources}[0]{query}{collections}[0]{page_size} = 2;
$partial_manifest->{sources}[0]{query}{collections}[0]{max_items} = 3;
$partial_manifest->{sources}[0]{query}{collections}[0]{primary_key} = 'id';
my $partial_source = $partial_manifest->{sources}[0];
my $partial_current = {
    rows => [{
        id => 1, order_number => 'PO-100',
        lines => [
            {id => 11, sku => 'A', quantity => 2, allocations => []},
            {id => 12, sku => 'B', quantity => 1, allocations => []},
        ],
    }],
    pages => [{
        collection_path => ['lines'], parent_path => [1],
        has_more => JSON::PP::true, after_values => [12],
    }],
    identities => [{
        collection_path => ['lines'], parent_path => [1], row_keys => [11, 12],
    }],
};
my $partial_snapshot = {
    instance_id => 'budget-nested-perl',
    release_id => 'budget-nested-release',
    template_fingerprint => $partial_manifest->{template}{fingerprint},
    inputs => $nested_effect->{bindings}{input},
    state => $nested_effect->{bindings}{state},
    sources => {
        $partial_source->{id} => {
            status => 'ready', generation => 1, result => $partial_current,
        },
    },
};
my $partial_cursor = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $partial_snapshot, source_id => $partial_source->{id},
    source_plan => $partial_source, scope => $page_scope,
    secret => $page_secret, now => 1000, ttl_seconds => 60,
);
is $partial_cursor->{status}, 'ok',
    'partial page issues a cursor from server-held position';
my $partial_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $partial_manifest, effect => $nested_effect,
    authorize => $scoped_authorize,
    page_snapshot => $partial_snapshot,
    page_cursor => $partial_cursor->{pages}[0]{token},
    page_secret => $page_secret, page_now => 1001, page_ttl_seconds => 60,
    run => sub {
        return {rows => [[1, 'PO-100', JSON::PP->new->encode([
            {id => 13, sku => 'C', quantity => 1, allocations => []},
            {id => 14, sku => 'D', quantity => 1, allocations => []},
        ])]]};
    },
);
is $partial_result->{status}, 'ok',
    'host narrows the final query window to the remaining item allowance';
is_deeply([map { $_->{id} } @{$partial_result->{result}{rows}[0]{lines}}],
    [11, 12, 13], 'only one new line is appended despite native lookahead');
ok(!$partial_result->{result}{pages}[0]{has_more},
    'accumulated item cap removes the continuation');
is $partial_result->{result}{pages}[0]{after_values}, undef,
    'terminal accumulated page clears its seek tuple';
is_deeply($partial_result->{result}{identities}[0]{row_keys}, [11, 12, 13],
    'private row keys remain aligned after the partial page');

my $root_manifest;
{
    my $path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-root-page.compile.json";
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    $root_manifest = JSON::PP->new->utf8->decode(<$handle>);
}
delete $root_manifest->{sources}[0]{query}{page};
my $root_source = $root_manifest->{sources}[0];
my $root_effect = Selecto::Templates->mount_runtime(
    $root_manifest,
    instance_id => 'root-source-perl', release_id => 'root-source-release',
    inputs => {},
)->{effects}[0];
my $root_scope = {
    tenant_id => 'tenant-7', principal_id => 'actor-1',
    authorization_revision => 'acl-2', membership_revision => 'orders-v1',
};
my $root_authorizations = 0;
my $root_authorize = sub {
    $root_authorizations++;
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open')),
        page_scope => $root_scope,
    };
};
my @root_statements;
my @root_query_limits;
my $root_first = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_manifest, effect => $root_effect,
    authorize => $root_authorize, root_cursor => 'first',
    run => sub {
        my ($engine, $query) = @_;
        push @root_statements, $engine->compile($query);
        push @root_query_limits, $query->limit_value;
        return {rows => [[1, 'PO-100'], [2, 'PO-200'], [3, 'PO-300']]};
    },
);
is $root_first->{status}, 'ok', 'first root lookahead executes under host scope';
is_deeply [map { $_->{id} } @{$root_first->{result}{rows}}], [1, 2],
    'root lookahead row is removed from public rows';
ok $root_first->{result}{root_page}{has_more}, 'first root page has a continuation';
is_deeply $root_first->{result}{root_page}{after_values}, [2],
    'last visible root tuple stays in the server result';
is $root_query_limits[0], 3,
    'native query fetches one root lookahead';

my $root_snapshot = {
    instance_id => 'root-source-perl', release_id => 'root-source-release',
    template_fingerprint => $root_manifest->{template}{fingerprint},
    inputs => $root_effect->{bindings}{input},
    state => $root_effect->{bindings}{state},
    sources => {
        $root_source->{id} => {
            status => 'ready', generation => $root_effect->{generation},
            result => $root_first->{result},
        },
    },
};
my $root_secret = 'r' x 32;
my $root_issued = Selecto::Components::Templates::RootCursor->issue(
    snapshot => $root_snapshot, source_id => $root_source->{id},
    source_plan => $root_source, scope => $root_scope,
    secret => $root_secret, now => 1000, ttl_seconds => 60,
);
is $root_issued->{status}, 'ok', 'host seals the visible root page';
my $root_next = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_manifest, effect => $root_effect,
    authorize => $root_authorize,
    root_cursor => $root_issued->{token},
    root_snapshot => $root_snapshot, root_secret => $root_secret,
    root_now => 1001, root_ttl_seconds => 60,
    run => sub {
        my ($engine, $query) = @_;
        push @root_statements, $engine->compile($query);
        push @root_query_limits, $query->limit_value;
        return {rows => [[3, 'PO-300'], [4, 'PO-400']]};
    },
);
is $root_next->{status}, 'ok', 'opaque root continuation executes';
is_deeply [map { $_->{id} } @{$root_next->{result}{rows}}], [3, 4],
    'next root page contains only its visible rows';
ok !$root_next->{result}{root_page}{has_more}, 'last root page has no cursor';
like $root_statements[1]->sql, qr/"s0"\."id" >/, 'root seek stays in native SQL';
ok scalar(grep { defined($_) && !ref($_) && $_ eq '2' }
    @{$root_statements[1]->params}), 'server-held seek value is bound';
like $root_statements[1]->sql, qr/"s0"\."tenant_id"/,
    'root continuation retains tenant scope';
like $root_statements[1]->sql, qr/"s0"\."status"/,
    'root continuation retains host membership';
is $root_authorizations, 2, 'host reauthorizes the root continuation';

my $root_query_count = scalar @root_statements;
my $root_forged = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_manifest, effect => $root_effect,
    authorize => $root_authorize,
    root_cursor => "$root_issued->{token}0",
    root_snapshot => $root_snapshot, root_secret => $root_secret,
    root_now => 1001, root_ttl_seconds => 60,
    run => sub { die 'forged root cursor must not execute' },
);
is $root_forged->{code}, 'invalid_root_cursor', 'forged root cursor fails closed';
is scalar(@root_statements), $root_query_count,
    'rejected root token runs no query';
my $root_changed = dclone($root_snapshot);
$root_changed->{state}{root_page} = 7;
my $root_stale = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_manifest, effect => $root_effect,
    authorize => $root_authorize,
    root_cursor => $root_issued->{token},
    root_snapshot => $root_changed, root_secret => $root_secret,
    root_now => 1001, root_ttl_seconds => 60,
    run => sub { die 'changed root state must not execute' },
);
is $root_stale->{code}, 'invalid_root_cursor',
    'changed state cannot reuse a root token';

my $root_nested_manifest = dclone($page_manifest);
$root_nested_manifest->{sources}[0]{query}{limit} = 1;
my $root_nested = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_nested_manifest, effect => $nested_effect,
    authorize => $nested_authorize, root_cursor => 'first',
    run => sub {
        return {rows => [
            [1, 'PO-1', JSON::PP->new->encode([
                {id => 11, sku => 'A', quantity => 1, allocations => []},
                {id => 12, sku => 'B', quantity => 1, allocations => []},
            ])],
            [2, 'PO-2', JSON::PP->new->encode([
                {id => 21, sku => 'C', quantity => 1, allocations => []},
                {id => 22, sku => 'D', quantity => 1, allocations => []},
            ])],
        ]};
    },
);
is $root_nested->{status}, 'ok', 'nested root lookahead projects';
is_deeply [map { $_->{id} } @{$root_nested->{result}{rows}}], [1],
    'hidden root is absent from public nested rows';
is_deeply [map { $_->{parent_path} } @{$root_nested->{result}{pages}}], [[1], [1, 11]],
    'hidden root contributes no nested page positions';
is_deeply [map { $_->{parent_path} } @{$root_nested->{result}{identities}}],
    [[1], [1, 11]], 'hidden root contributes no nested row identities';

my $root_related_manifest = dclone($related_manifest);
$root_related_manifest->{sources}[0]{query}{limit} = 1;
my $root_related_source = $root_related_manifest->{sources}[0];
my $root_related_first = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_related_manifest, effect => $related_effect,
    authorize => $scoped_authorize, root_cursor => 'first',
    resource_budget => {max_source_statements => 5},
    snapshot_run => sub {
        return {
            rows => [[1, 'PO-1', '[]'], [2, 'PO-2', '[]']],
            totals => {
                page_quantity => '2', filtered_quantity => '9',
                page_line_count => 1, filtered_line_count => 4,
            },
        };
    },
);
is $root_related_first->{status}, 'ok',
    'first root cursor read carries page and filtered related totals';
is_deeply [map { $_->{id} } @{$root_related_first->{result}{rows}}], [1],
    'first related-total page removes root lookahead';
my $root_related_snapshot = {
    instance_id => 'related-source-perl', release_id => 'related-source-release',
    template_fingerprint => $root_related_manifest->{template}{fingerprint},
    inputs => $related_effect->{bindings}{input},
    state => $related_effect->{bindings}{state},
    sources => {
        $root_related_source->{id} => {
            status => 'ready', generation => $related_effect->{generation},
            result => $root_related_first->{result},
        },
    },
};
my $root_related_token = Selecto::Components::Templates::RootCursor->issue(
    snapshot => $root_related_snapshot, source_id => $root_related_source->{id},
    source_plan => $root_related_source, scope => $page_scope,
    secret => $root_secret, now => 1000, ttl_seconds => 60,
);
is $root_related_token->{status}, 'ok',
    'host seals a root page carrying related totals';
my $root_related_next = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_related_manifest, effect => $related_effect,
    authorize => $scoped_authorize,
    root_cursor => $root_related_token->{token},
    root_snapshot => $root_related_snapshot, root_secret => $root_secret,
    root_now => 1001, root_ttl_seconds => 60,
    resource_budget => {max_source_statements => 5},
    snapshot_run => sub {
        my ($engine, $page, $totals) = @_;
        for my $id (qw(page_quantity page_line_count)) {
            like $engine->compile($totals->{$id}{query})->sql,
                qr/"s0"\."id" >/, "$id seeks with the continued root page";
        }
        for my $id (qw(filtered_quantity filtered_line_count)) {
            unlike $engine->compile($totals->{$id}{query})->sql,
                qr/"s0"\."id" >/, "$id retains full filtered membership";
        }
        return {
            rows => [[2, 'PO-2', '[]']],
            totals => {
                page_quantity => '4', filtered_quantity => '9',
                page_line_count => 2, filtered_line_count => 4,
            },
        };
    },
);
is $root_related_next->{status}, 'ok',
    'continued root page executes related totals through the same seek';
is_deeply $root_related_next->{result}{totals},
    {
        page_quantity => '4', filtered_quantity => '9',
        page_line_count => 2, filtered_line_count => 4,
    }, 'continued page totals change while filtered totals remain stable';

my $root_count_manifest = dclone($page_filtered_manifest);
$root_count_manifest->{sources}[0]{query}{limit} = 2;
my $root_count = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $root_count_manifest, effect => $page_filtered_effect,
    authorize => $nested_authorize, root_cursor => 'first',
    snapshot_run => sub {
        return {
            rows => [[1, 'PO-1'], [2, 'PO-2'], [3, 'PO-3']],
            totals => {order_count => 3},
        };
    },
);
is $root_count->{status}, 'ok', 'root lookahead combines with source totals';
is_deeply $root_count->{result}{totals},
    {page_count => 2, order_count => 3},
    'page count excludes lookahead while filtered count retains full membership';
is_deeply [map { $_->{id} } @{$root_count->{result}{rows}}], [1, 2],
    'lookahead does not leak through source totals';

# A handle marked as created in another process (e.g. inherited across the
# source-worker fork) is refused before any statement is prepared.
for my $case (
    [inherited => $$ + 1, 'error'],
    [fresh => $$, 'ok'],
    [unmarked => undef, 'ok'],
) {
    my ($name, $pid, $expected) = @$case;
    my $marked_dbh = TemplateSourceDBH->new(
        rows => [[1, 'PO-100', '2026-09-21T12:00:00Z', 'open', 44]],
        pg_type => [qw(int4 text timestamptz text int4)],
    );
    $marked_dbh->{private_selecto_pid} = $pid if defined $pid;
    my $marked = Selecto::Components::Templates::SourceExecutor->execute(
        manifest => $manifest, effect => $effect,
        authorize => sub {
            my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
                ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
            my $engine = Selecto::Engine->new(
                domain => $domain,
                adapter => Selecto::PostgreSQL->new(dbh => $marked_dbh),
            );
            return {status => 'ok', engine => $engine, query => $engine->query->limit(10)};
        },
    );
    is $marked->{status}, $expected, "$name database handle: $expected";
    if ($expected eq 'error') {
        is $marked->{code}, 'source_connection_inherited',
            'an inherited handle is reported with a stable code';
        like $marked->{message}, qr/open a fresh connection inside the source worker/,
            'the inherited-handle error tells the host what to do';
        is scalar(@{$marked_dbh->prepared}), 0, 'no statement reaches an inherited handle';
    }
}

done_testing;

package TemplateSourceDBH;

sub new {
    my ($class, %args) = @_;
    return bless {%args, prepared => []}, $class;
}

sub prepare {
    my ($self, $sql) = @_;
    my $statement = TemplateSourceSTH->new(owner => $self, sql => $sql);
    push @{$self->{prepared}}, $statement;
    return $statement;
}

sub errstr { return undef }
sub prepared { return [@{$_[0]->{prepared}}] }

package TemplateSourceSTH;

sub new {
    my ($class, %args) = @_;
    return bless {
        %args,
        index => 0,
        params => [],
        pg_type => $args{owner}{pg_type},
    }, $class;
}

sub execute {
    my ($self, @params) = @_;
    $self->{params} = [@params];
    return 1;
}

sub fetchrow_array {
    my ($self) = @_;
    return if $self->{index} >= @{$self->{owner}{rows}};
    return @{$self->{owner}{rows}[$self->{index}++]};
}

sub err { return undef }
sub errstr { return undef }
sub sql { return $_[0]->{sql} }
sub params { return [@{$_[0]->{params}}] }
