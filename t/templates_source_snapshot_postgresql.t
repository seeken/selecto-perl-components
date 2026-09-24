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
    package Selecto::Components::Templates::InterleavingEngine;
    use parent 'Selecto::Engine';

    sub new {
        my ($class, %args) = @_;
        my $on_page_read = delete $args{on_page_read};
        my $self = $class->SUPER::new(%args);
        $self->{on_page_read} = $on_page_read;
        return $self;
    }

    sub all {
        my ($self, $query) = @_;
        my $result = $self->SUPER::all($query);
        if (!$self->{page_read}) {
            $self->{page_read} = 1;
            $self->{on_page_read}->();
        }
        return $result;
    }
}

my $dsn = $ENV{SELECTO_TEMPLATES_POSTGRES_DSN};
plan skip_all => 'template PostgreSQL DSN is not configured'
    unless defined($dsn) && length($dsn);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };

my $reader = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
my $writer = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
my $schema = 'selecto_snapshot_' . $$ . '_' . int(rand(1_000_000));

END {
    eval { $reader->do("DROP SCHEMA IF EXISTS $schema CASCADE") if $reader };
    eval { $reader->disconnect if $reader };
    eval { $writer->disconnect if $writer };
}

$reader->do("CREATE SCHEMA $schema");
$reader->do(
    "CREATE TABLE $schema.base_orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)",
);
$reader->do(
    "INSERT INTO $schema.base_orders(id, tenant_id, order_number, status) VALUES (1, 7, 'PO-100', 'open'), (2, 7, 'PO-100', 'open'), (3, 8, 'PO-100', 'open')",
);
$reader->do(
    "CREATE TEMP VIEW orders AS SELECT id, tenant_id, order_number, status FROM $schema.base_orders",
);

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $manifest = _json("$fixtures/order-page-filtered-total.compile.json");
my $catalog = _json("$fixtures/domains.json");
my $effect = Selecto::Templates->mount_runtime(
    $manifest,
    instance_id => 'snapshot-perl', release_id => 'snapshot-perl-v1', inputs => {},
)->{effects}[0];
$effect->{bindings}{state}{search} = 'PO-100';

my $authorize = sub {
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders_nested}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Components::Templates::InterleavingEngine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $reader),
        on_page_read => sub {
            $writer->do(
                "INSERT INTO $schema.base_orders(id, tenant_id, order_number, status) VALUES (4, 7, 'PO-100', 'open')",
            );
        },
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))
            ->limit(1),
    };
};

my $result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest, effect => $effect, authorize => $authorize,
);
is $result->{status}, 'ok', 'Perl host reads the page and count in one snapshot';
is_deeply($result->{result},
    {rows => [{id => 1, order_number => 'PO-100'}],
     totals => {page_count => 1, order_count => 2}},
    'concurrent matching insert leaves page and filtered totals on one snapshot');
my ($visible_after) = $writer->selectrow_array(
    "SELECT count(*) FROM $schema.base_orders WHERE tenant_id = 7",
);
is $visible_after, 3, 'separate connection committed the matching order';
ok($reader->{AutoCommit}, 'reader transaction committed after both statements');

my $related_dbh = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$related_dbh->do(
    'CREATE TEMP TABLE orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)',
);
$related_dbh->do(
    'CREATE TEMP TABLE order_lines(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_id integer NOT NULL, sku text NOT NULL, quantity integer NOT NULL)',
);
my $related_fixture = _json("$fixtures/order-related-source-totals.execution.json");
my $related_base = _json("$fixtures/$related_fixture->{base_execution}");
my $insert_order = $related_dbh->prepare(
    'INSERT INTO orders(id, tenant_id, order_number, status) VALUES (?, ?, ?, ?)',
);
for my $order (@{$related_base->{orders}}, @{$related_fixture->{extra_orders}}) {
    $insert_order->execute(@$order{qw(id tenant_id order_number status)});
}
my $insert_line = $related_dbh->prepare(
    'INSERT INTO order_lines(id, tenant_id, order_id, sku, quantity) VALUES (?, ?, ?, ?, ?)',
);
for my $line (@{$related_base->{order_lines}}, @{$related_fixture->{extra_lines}}) {
    $insert_line->execute(@$line{qw(id tenant_id order_id sku quantity)});
}
my $related_manifest = _json("$fixtures/$related_fixture->{source_fixture}");
my $related_effect = Selecto::Templates->mount_runtime(
    $related_manifest,
    instance_id => 'related-snapshot-perl', release_id => 'related-snapshot-perl-v1',
    inputs => {},
)->{effects}[0];
$related_effect->{bindings}{state}{search} = 'PO-100';
my $related_authorize = sub {
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders_nested}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $related_dbh),
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))->limit(1),
    };
};
my $related_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $related_manifest, effect => $related_effect,
    authorize => $related_authorize,
    resource_budget => {max_source_statements => 5},
);
is $related_result->{status}, 'ok',
    'Perl host reads related page and filtered totals in one PostgreSQL snapshot';
is_deeply($related_result->{result}{totals},
    {page_quantity => '3', filtered_quantity => '7',
     page_line_count => 2, filtered_line_count => 3},
    'Perl host returns exact related source totals independent of child display limit');
is_deeply([map { $_->{id} } @{$related_result->{result}{rows}[0]{lines}}], [11],
    'displayed top-one line does not narrow the source totals');
ok($related_dbh->{AutoCommit}, 'related total snapshot commits before host response');
$related_dbh->disconnect;

my $related_race_reader = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
my $related_race_writer = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
my $related_race_schema = 'selecto_related_snapshot_' . $$ . '_' . int(rand(1_000_000));
$related_race_reader->do("CREATE SCHEMA $related_race_schema");
$related_race_reader->do(
    "CREATE TABLE $related_race_schema.base_orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)",
);
$related_race_reader->do(
    "CREATE TABLE $related_race_schema.base_lines(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_id integer NOT NULL, sku text NOT NULL, quantity integer NOT NULL)",
);
$related_race_reader->do(
    "INSERT INTO $related_race_schema.base_orders VALUES (1, 7, 'PO-100', 'open'), (5, 7, 'PO-100', 'open'), (2, 8, 'PO-100', 'open')",
);
$related_race_reader->do(
    "INSERT INTO $related_race_schema.base_lines VALUES (11, 7, 1, 'A', 2), (12, 7, 1, 'B', 1), (51, 7, 5, 'EXTRA', 4), (52, 8, 5, 'LEAK', 50)",
);
$related_race_reader->do(
    "CREATE TEMP VIEW orders AS SELECT id, tenant_id, order_number, status FROM $related_race_schema.base_orders",
);
$related_race_reader->do(
    "CREATE TEMP VIEW order_lines AS SELECT id, tenant_id, order_id, sku, quantity FROM $related_race_schema.base_lines",
);
my $related_race_effect = Selecto::Templates->mount_runtime(
    $related_manifest,
    instance_id => 'related-race-perl', release_id => 'related-race-perl-v1',
    inputs => {},
)->{effects}[0];
$related_race_effect->{bindings}{state}{search} = 'PO-100';
my $related_race_authorize = sub {
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders_nested}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Components::Templates::InterleavingEngine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $related_race_reader),
        on_page_read => sub {
            $related_race_writer->do(
                "INSERT INTO $related_race_schema.base_lines VALUES (99, 7, 1, 'NEW', 9)",
            );
        },
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))->limit(1),
    };
};
my $related_race_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $related_manifest, effect => $related_race_effect,
    authorize => $related_race_authorize,
    resource_budget => {max_source_statements => 5},
);
is $related_race_result->{status}, 'ok',
    'Perl host reads related totals while a child insert commits after the page';
is_deeply($related_race_result->{result}{totals},
    {page_quantity => '3', filtered_quantity => '7',
     page_line_count => 2, filtered_line_count => 3},
    'related page and filtered totals retain the page snapshot');
my ($new_page_sum) = $related_race_writer->selectrow_array(
    "SELECT sum(quantity) FROM $related_race_schema.base_lines WHERE tenant_id = 7 AND order_id = 1",
);
my ($new_filtered_sum) = $related_race_writer->selectrow_array(
    "SELECT sum(quantity) FROM $related_race_schema.base_lines WHERE tenant_id = 7 AND order_id IN (1, 5)",
);
is $new_page_sum, 12, 'separate connection sees the committed page-child insert';
is $new_filtered_sum, 16, 'separate connection sees the committed filtered-child insert';
ok($related_race_reader->{AutoCommit}, 'related race snapshot commits before response');
$related_race_reader->do("DROP SCHEMA $related_race_schema CASCADE");
$related_race_reader->disconnect;
$related_race_writer->disconnect;

my $decimal_dbh = DBI->connect($dsn, undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$decimal_dbh->do(
    'CREATE TEMP TABLE orders(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_number text NOT NULL, status text NOT NULL)',
);
$decimal_dbh->do(
    'CREATE TEMP TABLE order_lines(id integer PRIMARY KEY, tenant_id integer NOT NULL, order_id integer NOT NULL, sku text NOT NULL, quantity numeric(40, 10) NOT NULL)',
);
$decimal_dbh->do(
    "INSERT INTO orders VALUES (1, 7, 'PO-100', 'open'), (5, 7, 'PO-100', 'open')",
);
$decimal_dbh->do(
    "INSERT INTO order_lines VALUES (11, 7, 1, 'LARGE', 9007199254740993.10), (12, 7, 1, 'SMALL', 0.20), (51, 7, 5, 'NEXT', 0.40), (52, 8, 5, 'LEAK', 50.00)",
);
my $decimal_contract = JSON::PP->new->decode(
    JSON::PP->new->encode($catalog->{domains}{orders_nested}),
);
$decimal_contract->{schemas}{order_lines}{columns}{quantity}{type} = 'decimal';
$decimal_contract->{domain_fingerprint} =
    'sha256:3b6f30b77f972969917a98a74131d9c474d0b8d77db9abb9163e4d37eb3932cc';
my $decimal_document = Selecto::Templates->parse(
    _read("$fixtures/order-related-source-totals.valid.selecto"),
);
my $decimal_manifest = Selecto::Templates->compile(
    $decimal_document,
    domains => {orders_nested => Selecto::Domain->parse($decimal_contract, strict => 1)},
    capabilities => _json("$fixtures/capabilities.json"),
);
my $decimal_effect = Selecto::Templates->mount_runtime(
    $decimal_manifest,
    instance_id => 'related-decimal-perl', release_id => 'related-decimal-perl-v1',
    inputs => {},
)->{effects}[0];
$decimal_effect->{bindings}{state}{search} = 'PO-100';
my $decimal_authorize = sub {
    my $domain = Selecto::Domain->parse($decimal_contract, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $decimal_dbh),
    );
    return {
        status => 'ok', engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))->limit(1),
    };
};
my $decimal_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $decimal_manifest, effect => $decimal_effect,
    authorize => $decimal_authorize,
    resource_budget => {max_source_statements => 5},
);
is $decimal_result->{status}, 'ok',
    'Perl compiler and host accept a declared decimal related sum';
is_deeply($decimal_result->{result}{totals},
    {page_quantity => '9007199254740993.3',
     filtered_quantity => '9007199254740993.7',
     page_line_count => 2, filtered_line_count => 3},
    'related sums retain exact decimal values beyond JavaScript integer precision');
is $decimal_result->{result}{rows}[0]{lines}[0]{quantity},
    '9007199254740993.1000000000',
    'displayed nested decimal is also an exact string';
$decimal_dbh->disconnect;

done_testing;

sub _json {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    return JSON::PP->new->utf8->decode(<$handle>);
}

sub _read {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/;
    return <$handle>;
}
