use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Test::More;
use Selecto::Components::Templates::RootCursor ();
use Selecto::Components::Templates::SourceExecutor ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

my $dsn = $ENV{SELECTO_TEMPLATES_POSTGRES_DSN};
plan skip_all => 'template PostgreSQL DSN is not configured'
    unless defined($dsn) && length($dsn);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };

my $dbh = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
END { eval { $dbh->disconnect if $dbh } }

$dbh->do('CREATE TEMP TABLE orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)');
$dbh->do("INSERT INTO orders VALUES (1, 7, 'PO-1', 'open'), (2, 7, 'PO-2', 'open'), (3, 7, 'PO-3', 'open'), (4, 7, 'PO-4', 'open'), (5, 7, 'PO-5', 'closed'), (6, 8, 'PO-6', 'open')");

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $manifest = _json("$fixtures/order-root-page.compile.json");
delete $manifest->{sources}[0]{query}{page};
my $source = $manifest->{sources}[0];
my $catalog = _json("$fixtures/domains.json");
my $mounted = Selecto::Templates->mount_runtime(
    $manifest,
    instance_id => 'pg-root-page', release_id => 'pg-root-page-v1', inputs => {},
);
my $effect = $mounted->{effects}[0];
my $scope = {
    tenant_id => '7', principal_id => 'actor-1',
    authorization_revision => 'acl-1', membership_revision => 'open-orders-1',
};
my $secret = 'r' x 32;
my $authorization_calls = 0;
my $authorize = sub {
    $authorization_calls++;
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query->where(Selecto::Expression->eq('status', 'open')),
        page_scope => $scope,
    };
};

my $first = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    root_cursor => 'first',
);
is $first->{status}, 'ok', 'first root page executes against PostgreSQL';
is_deeply [map { $_->{id} } @{$first->{result}{rows}}], [1, 2],
    'first page contains only the first two tenant-owned open orders';
ok $first->{result}{root_page}{has_more}, 'lookahead yields a continuation';
is_deeply $first->{result}{root_page}{after_values}, [2],
    'first page retains its private seek position';
is $authorization_calls, 1, 'first page received fresh host authorization';

my $snapshot = $mounted->{snapshot};
$snapshot->{sources}{orders}{status} = 'ready';
$snapshot->{sources}{orders}{result} = $first->{result};
my $issued = Selecto::Components::Templates::RootCursor->issue(
    snapshot => $snapshot, source_id => 'orders', source_plan => $source,
    scope => $scope, secret => $secret, now => 1000, ttl_seconds => 60,
);
is $issued->{status}, 'ok', 'server-held first page issues a root cursor';

my $second = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    root_cursor => $issued->{token}, root_snapshot => $snapshot,
    root_secret => $secret, root_now => 1001, root_ttl_seconds => 60,
);
is $second->{status}, 'ok', 'root continuation executes against PostgreSQL';
is_deeply [map { $_->{id} } @{$second->{result}{rows}}], [3, 4],
    'continued page excludes the lookahead, closed, and foreign-tenant orders';
ok !$second->{result}{root_page}{has_more}, 'second page is terminal';
is $second->{result}{root_page}{after_values}, undef,
    'terminal page carries no seek position';
is $authorization_calls, 2, 'continuation received fresh host authorization';

my $query_count = 0;
my $forged = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
    root_cursor => "$issued->{token}forged", root_snapshot => $snapshot,
    root_secret => $secret, root_now => 1001, root_ttl_seconds => 60,
    run => sub { $query_count++; die 'forged token reached PostgreSQL' },
);
is $forged->{code}, 'invalid_root_cursor', 'forged cursor fails closed';
is $query_count, 0, 'forged cursor reaches no native query';
is $authorization_calls, 3, 'forged attempt still reauthorizes first';

done_testing;

sub _json {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    return JSON::PP->new->utf8->decode(<$handle>);
}
