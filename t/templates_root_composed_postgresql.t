use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Test::More;
use Selecto::Components::Templates::RootCursor ();
use Selecto::Components::Templates::PageCursor ();
use Selecto::Components::Templates::SourceExecutor ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

my $dsn = $ENV{SELECTO_TEMPLATES_POSTGRES_DSN};
plan skip_all => 'template PostgreSQL DSN is not configured'
    unless defined($dsn) && length($dsn);
plan skip_all => 'DBD::Pg is not installed'
    unless eval { require DBI; require DBD::Pg; 1 };

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $fixture = _json("$fixtures/order-root-composed.cases.json");
my $manifest = _json("$fixtures/order-root-composed.compile.json");
my $catalog = _json("$fixtures/domains.json");
my $source = $manifest->{sources}[0];
my $dbh = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
END { eval { $dbh->disconnect if $dbh } }

$dbh->do('CREATE TEMP TABLE orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)');
$dbh->do('CREATE TEMP TABLE order_lines(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_id integer NOT NULL, sku text NOT NULL, quantity integer NOT NULL)');
$dbh->do('CREATE TEMP TABLE line_allocations(id integer PRIMARY KEY, tenant_id integer NOT NULL, line_id integer NOT NULL, warehouse text NOT NULL, quantity integer NOT NULL)');
for my $row (@{$fixture->{orders}}) {
    $dbh->do('INSERT INTO orders VALUES (?, ?, ?, ?)', undef,
        @$row{qw(id tenant_id order_number status)});
}
for my $row (@{$fixture->{lines}}) {
    $dbh->do('INSERT INTO order_lines VALUES (?, ?, ?, ?, ?)', undef,
        @$row{qw(id tenant_id order_id sku quantity)});
}
for my $row (@{$fixture->{allocations}}) {
    $dbh->do('INSERT INTO line_allocations VALUES (?, ?, ?, ?, ?)', undef,
        @$row{qw(id tenant_id line_id warehouse quantity)});
}

my $mounted = Selecto::Templates->mount_runtime(
    $manifest,
    instance_id => 'pg-root-composed', release_id => 'pg-root-composed-v1',
    inputs => {},
);
my $effect = $mounted->{effects}[0];
my $scope = {
    tenant_id => '7', principal_id => 'actor-1',
    authorization_revision => 'acl-1', membership_revision => 'open-orders-1',
};
my $secret = 'c' x 32;
my $authorization_calls = 0;
my $authorize = sub {
    $authorization_calls++;
    my $domain = Selecto::Domain->parse(
        $catalog->{domains}{orders_nested}, strict => 1,
    )->with_required_predicate(
        Selecto::Expression->eq('tenant_id', $fixture->{tenant_id}),
    );
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query->where(
            Selecto::Expression->eq('status', $fixture->{host_status}),
        ),
        page_scope => $scope,
    };
};

my $first = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    root_cursor => 'first', resource_budget => {max_source_statements => 3},
);
is $first->{status}, 'ok', 'first composed root page executes';
_assert_page($first->{result}, $fixture->{pages}[0], 'first');
is $authorization_calls, 1, 'first page received fresh authorization';
ok !grep({ $_->{parent_path}[0] == 3 }
    (@{$first->{result}{pages}}, @{$first->{result}{identities}})),
    'lookahead root has no nested page metadata';

my $snapshot = $mounted->{snapshot};
$snapshot->{sources}{orders}{status} = 'ready';
$snapshot->{sources}{orders}{result} = $first->{result};
my $first_pages = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $snapshot, source_id => 'orders', source_plan => $source,
    scope => $scope, secret => $secret, now => 999, ttl_seconds => 60,
);
is $first_pages->{status}, 'ok',
    'first root page issues child cursors before root continuation';
my ($first_line_control) = grep {
    join(',', @{$_->{collection_path}}) eq 'lines'
        && join(',', @{$_->{parent_path}}) eq '1'
} @{$first_pages->{pages}};
ok defined($first_line_control->{token}), 'first root has a line continuation';
my $expanded_first = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    page_cursor => $first_line_control->{token},
    page_snapshot => $snapshot, page_secret => $secret,
    page_now => 1000, page_ttl_seconds => 60,
    resource_budget => {max_source_statements => 3},
);
is $expanded_first->{status}, 'ok',
    'first root child page advances before root continuation';
is_deeply [map { $_->{id} } @{$expanded_first->{result}{rows}[0]{lines}}],
    [11, 12], 'first root retains and appends its line';
is_deeply $expanded_first->{result}{totals}, $first->{result}{totals},
    'first child continuation retains source totals';
is_deeply $expanded_first->{result}{root_page}, $first->{result}{root_page},
    'first child continuation retains the pending root cursor';
$snapshot->{sources}{orders}{result} = $expanded_first->{result};
my $issued = Selecto::Components::Templates::RootCursor->issue(
    snapshot => $snapshot, source_id => 'orders', source_plan => $source,
    scope => $scope, secret => $secret, now => 1000, ttl_seconds => 60,
);
is $issued->{status}, 'ok', 'first composed page issues an opaque cursor';

my $second = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    root_cursor => $issued->{token}, root_snapshot => $snapshot,
    root_secret => $secret, root_now => 1001, root_ttl_seconds => 60,
    resource_budget => {max_source_statements => 3},
);
is $second->{status}, 'ok', 'continued composed root page executes';
_assert_page($second->{result}, $fixture->{pages}[1], 'second');
is $authorization_calls, 3, 'root continuation received fresh authorization';
ok !grep({ $_->{parent_path}[0] != 3 }
    (@{$second->{result}{pages}}, @{$second->{result}{identities}})),
    'continued page metadata belongs only to its visible root';

my $continued_snapshot = $snapshot;
$continued_snapshot->{sources}{orders}{result} = $second->{result};
my $issued_pages = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $continued_snapshot, source_id => 'orders',
    source_plan => $source, scope => $scope, secret => $secret,
    now => 1002, ttl_seconds => 60,
);
is $issued_pages->{status}, 'ok',
    'continued root page issues collection cursors for its visible root';
my ($line_control) = grep {
    join(',', @{$_->{collection_path}}) eq 'lines'
        && join(',', @{$_->{parent_path}}) eq '3'
} @{$issued_pages->{pages}};
ok defined($line_control->{token}), 'new root has a line continuation';
my $expanded = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    page_cursor => $line_control->{token},
    page_snapshot => $continued_snapshot, page_secret => $secret,
    page_now => 1003, page_ttl_seconds => 60,
    resource_budget => {max_source_statements => 3},
);
is $expanded->{status}, 'ok', 'nested line page advances on the continued root';
is_deeply [map { $_->{id} } @{$expanded->{result}{rows}[0]{lines}}],
    [31, 32], 'line continuation retains the first line and adds the second';
is_deeply $expanded->{result}{totals}, $second->{result}{totals},
    'nested continuation retains composed source totals';
is_deeply $expanded->{result}{root_page}, $second->{result}{root_page},
    'nested continuation retains the terminal root page';
is $authorization_calls, 4, 'later child continuation received fresh authorization';

my $offset_manifest = _json("$fixtures/order-root-offset-composed.compile.json");
my $offset_source = $offset_manifest->{sources}[0];
my $offset_mounted = Selecto::Templates->mount_runtime(
    $offset_manifest,
    instance_id => 'pg-offset-composed', release_id => 'pg-offset-composed-v1',
    inputs => {},
);
my $offset_first = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $offset_manifest, effect => $offset_mounted->{effects}[0],
    authorize => $authorize, resource_budget => {max_source_statements => 3},
);
is $offset_first->{status}, 'ok', 'first offset root page executes';
is_deeply [map { $_->{id} } @{$offset_first->{result}{rows}}], [1, 2],
    'first offset root page contains the first two authorized roots';
is "$offset_first->{result}{totals}{page_quantity}", '9',
    'first offset page total covers its visible roots';
my $offset_first_snapshot = $offset_mounted->{snapshot};
$offset_first_snapshot->{sources}{orders}{status} = 'ready';
$offset_first_snapshot->{sources}{orders}{result} = $offset_first->{result};
my $offset_first_controls = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $offset_first_snapshot, source_id => 'orders',
    source_plan => $offset_source, scope => $scope, secret => $secret,
    now => 999, ttl_seconds => 60,
);
is $offset_first_controls->{status}, 'ok',
    'first offset page issues a child cursor before the page change';
my ($old_offset_line) = grep {
    join(',', @{$_->{collection_path}}) eq 'lines'
        && join(',', @{$_->{parent_path}}) eq '1'
} @{$offset_first_controls->{pages}};
ok defined($old_offset_line->{token}), 'first offset root has a child cursor';

my $offset_event = {
    schema => 'selecto.template.runtime-event.v1',
    instance_id => 'pg-offset-composed', release_id => 'pg-offset-composed-v1',
    event_id => 'go-to-second-page', name => 'root_page_changed',
    expected_state_revision => 0, payload => {value => 1},
};
my $offset_dispatched = Selecto::Templates->dispatch_runtime(
    $offset_manifest, $offset_first_snapshot, $offset_event,
);
is $offset_dispatched->{outcome}, 'accepted',
    'declared event selects the second offset root page';
is $offset_dispatched->{snapshot}{state}{root_page}, 1,
    'second offset root page is bound from typed state';
my $offset_effect = $offset_dispatched->{effects}[0];
my $offset_second = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $offset_manifest, effect => $offset_effect,
    authorize => $authorize, resource_budget => {max_source_statements => 3},
);
is $offset_second->{status}, 'ok', 'second offset root page executes';
is_deeply [map { $_->{id} } @{$offset_second->{result}{rows}}], [3],
    'second offset root page contains only the final authorized root';
is "$offset_second->{result}{totals}{page_quantity}", '11',
    'second offset page total changes with the visible root';
is "$offset_second->{result}{totals}{filtered_quantity}", '20',
    'filtered total keeps all authorized matching roots';

my $offset_snapshot = $offset_dispatched->{snapshot};
$offset_snapshot->{sources}{orders}{status} = 'ready';
$offset_snapshot->{sources}{orders}{result} = $offset_second->{result};
my $old_cursor_queries = 0;
my $old_cursor_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $offset_manifest, effect => $offset_effect,
    authorize => $authorize, page_cursor => $old_offset_line->{token},
    page_snapshot => $offset_snapshot, page_secret => $secret,
    page_now => 1000, page_ttl_seconds => 60,
    run => sub { $old_cursor_queries++; die 'old cursor reached PostgreSQL' },
);
is $old_cursor_result->{code}, 'invalid_page_cursor',
    'page change rejects the old child cursor';
is $old_cursor_queries, 0, 'old child cursor reaches no native query';
my $offset_controls = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $offset_snapshot, source_id => 'orders',
    source_plan => $offset_source, scope => $scope, secret => $secret,
    now => 1000, ttl_seconds => 60,
);
is $offset_controls->{status}, 'ok',
    'second offset root page issues its child cursor';
my ($offset_line) = grep {
    join(',', @{$_->{collection_path}}) eq 'lines'
        && join(',', @{$_->{parent_path}}) eq '3'
} @{$offset_controls->{pages}};
ok defined($offset_line->{token}), 'later offset root has a line continuation';
my $offset_expanded = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $offset_manifest, effect => $offset_effect,
    authorize => $authorize, page_cursor => $offset_line->{token},
    page_snapshot => $offset_snapshot, page_secret => $secret,
    page_now => 1001, page_ttl_seconds => 60,
    resource_budget => {max_source_statements => 3},
);
is $offset_expanded->{status}, 'ok',
    'child continuation on later offset root executes';
is_deeply [map { $_->{id} } @{$offset_expanded->{result}{rows}}], [3],
    'child continuation keeps only the current offset root';
is_deeply [map { $_->{id} } @{$offset_expanded->{result}{rows}[0]{lines}}],
    [31, 32], 'later offset root appends its second line';
is_deeply $offset_expanded->{result}{totals}, $offset_second->{result}{totals},
    'child continuation keeps page and filtered totals';

done_testing;

sub _assert_page {
    my ($result, $expected, $label) = @_;
    is_deeply [map { $_->{id} } @{$result->{rows}}], $expected->{root_ids},
        "$label page has expected tenant-owned roots";
    is_deeply [map { $_->{lines}[0]{id} } @{$result->{rows}}],
        $expected->{visible_line_ids}, "$label page has one ordered line per root";
    is_deeply [map { $_->{lines}[0]{allocations}[0]{id} } @{$result->{rows}}],
        $expected->{visible_allocation_ids},
        "$label page has one ordered allocation per line";
    is "$result->{totals}{page_quantity}", $expected->{page_quantity},
        "$label page sum covers all authorized lines on visible roots";
    is "$result->{totals}{filtered_quantity}", $expected->{filtered_quantity},
        "$label filtered sum covers all authorized matching roots";
    is_deeply $result->{root_page}{has_more},
        $expected->{has_more} ? JSON::PP::true : JSON::PP::false,
        "$label page has expected continuation status";
    is_deeply $result->{root_page}{after_values}, $expected->{after_values},
        "$label page has expected private seek tuple";
}

sub _json {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    return JSON::PP->new->utf8->decode(<$handle>);
}
