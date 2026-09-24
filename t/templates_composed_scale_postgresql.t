use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Test::More;
use Selecto::Components::Templates::SourceExecutor ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

{
    package Selecto::Components::Templates::CountedPostgreSQL;
    use parent 'Selecto::PostgreSQL';
    our $EXECUTIONS = 0;
    sub execute_query {
        ++$EXECUTIONS;
        return shift->SUPER::execute_query(@_);
    }
}

my $dsn = $ENV{SELECTO_TEMPLATES_POSTGRES_DSN};
plan skip_all => 'template PostgreSQL DSN is not configured'
    unless defined($dsn) && length($dsn);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };

my $dbh = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TEMP TABLE orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)');
$dbh->do('CREATE TEMP TABLE order_lines(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_id integer NOT NULL, sku text NOT NULL, quantity integer NOT NULL)');
$dbh->do('CREATE TEMP TABLE line_allocations(id integer PRIMARY KEY, tenant_id integer NOT NULL, line_id integer NOT NULL, warehouse text NOT NULL, quantity integer NOT NULL)');
$dbh->do(q{INSERT INTO orders SELECT n, 7, 'PO-SCALE', 'open' FROM generate_series(100, 124) AS n});
$dbh->do(q{INSERT INTO orders VALUES (200, 7, 'PO-SCALE', 'closed'), (201, 8, 'PO-SCALE', 'open')});
$dbh->do(q{INSERT INTO order_lines SELECT n * 10 + part, 7, n, 'OWNED', part FROM generate_series(100, 124) AS n CROSS JOIN generate_series(1, 2) AS part});
$dbh->do(q{INSERT INTO order_lines SELECT n * 10 + 3, 8, n, 'FOREIGN', 99 FROM generate_series(100, 124) AS n});
$dbh->do(q{INSERT INTO line_allocations SELECT n * 100 + part * 10 + allocation, 7, n * 10 + part, 'OWNED', allocation FROM generate_series(100, 124) AS n CROSS JOIN generate_series(1, 2) AS part CROSS JOIN generate_series(1, 2) AS allocation});
$dbh->do(q{INSERT INTO line_allocations SELECT n * 100 + 13, 8, n * 10 + 1, 'FOREIGN', 99 FROM generate_series(100, 124) AS n});

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $catalog = _json("$fixtures/domains.json");
my $domain = Selecto::Domain->parse($catalog->{domains}{orders_nested}, strict => 1);
my $manifest = Selecto::Templates->compile(
    Selecto::Templates->parse(_read("$fixtures/order-related-nested-totals.valid.selecto")),
    domains => {orders_nested => $domain},
    capabilities => _json("$fixtures/capabilities.json"),
);
my $effect = Selecto::Templates->mount_runtime(
    $manifest,
    instance_id => 'composed-scale-perl', release_id => 'composed-scale-v1',
    inputs => {},
)->{effects}[0];
$effect->{bindings}{state}{search} = 'PO-SCALE';

for my $root_count (1, 10, 25) {
    my $authorized_domain = $domain->with_required_predicate(
        Selecto::Expression->eq('tenant_id', 7),
    );
    my $engine = Selecto::Engine->new(
        domain => $authorized_domain,
        adapter => Selecto::Components::Templates::CountedPostgreSQL->new(dbh => $dbh),
    );
    my $authorize = sub {
        return {
            status => 'ok', engine => $engine,
            query => $engine->query
                ->where(Selecto::Expression->eq('status', 'open'))
                ->limit($root_count),
        };
    };

    $Selecto::Components::Templates::CountedPostgreSQL::EXECUTIONS = 0;
    my $under_budget = Selecto::Components::Templates::SourceExecutor->execute(
        manifest => $manifest, effect => $effect, authorize => $authorize,
        resource_budget => {max_source_statements => 4},
        snapshot_run => sub { die 'budget must reject before SQL' },
    );
    is $under_budget->{code}, 'source_budget_exceeded',
        "$root_count roots reject a four-statement host budget before execution";
    is $Selecto::Components::Templates::CountedPostgreSQL::EXECUTIONS, 0,
        "$root_count roots execute no data statement after budget rejection";

    my $read = Selecto::Components::Templates::SourceExecutor->execute(
        manifest => $manifest, effect => $effect, authorize => $authorize,
        resource_budget => {max_source_statements => 5},
    );
    is $read->{status}, 'ok', "$root_count roots complete the composed host read";
    is $Selecto::Components::Templates::CountedPostgreSQL::EXECUTIONS, 5,
        "$root_count roots use one page and four independent total statements";
    is_deeply [map { $_->{id} } @{$read->{result}{rows}}],
        [100 .. 99 + $root_count],
        "$root_count roots preserve tenant and host membership";

    for my $order (@{$read->{result}{rows}}) {
        is_deeply [map { $_->{id} } @{$order->{lines}}],
            [$order->{id} * 10 + 1],
            'limited line display retains the first owned child';
        is_deeply [map { $_->{id} } @{$order->{lines}[0]{allocations}}],
            [$order->{id} * 100 + 11, $order->{id} * 100 + 12],
            'nested allocations exclude tenant-colliding rows';
    }

    is_deeply $read->{result}{totals}, {
        page_quantity => '' . (3 * $root_count),
        filtered_quantity => '75',
        page_line_count => 2 * $root_count,
        filtered_line_count => 50,
    }, "$root_count roots retain independent page and filtered contributions";
}

ok $dbh->{AutoCommit}, 'composed host snapshots commit before returning';
$dbh->disconnect;
done_testing;

sub _json {
    my ($path) = @_;
    return JSON::PP->new->utf8->decode(_read($path));
}

sub _read {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    return <$handle>;
}
