use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Test::More;
use Time::HiRes qw(time);
use TestSelectoComponents ();

use Selecto::Components::Templates::Dispatcher;
use Selecto::Components::Templates::InstanceStore::PostgreSQL;

my $dsn = $ENV{SELECTO_TEMPLATES_POSTGRES_DSN};
plan skip_all => 'template PostgreSQL DSN is not configured'
    unless defined($dsn) && length($dsn);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };

my $worker_one_dbh = _connect();
my $worker_two_dbh = _connect();
my $table = sprintf 'selecto_template_instances_%d_%d', $$, int(time() * 1_000_000);
my $worker_one = _store($worker_one_dbh);
my $worker_two = _store($worker_two_dbh);
$worker_one->install_schema;

END {
    eval { $worker_one_dbh->do(qq{DROP TABLE IF EXISTS "$table"}) if $worker_one_dbh };
    eval { $worker_one_dbh->disconnect if $worker_one_dbh };
    eval { $worker_two_dbh->disconnect if $worker_two_dbh };
}

my $owner = {tenant_id => 'tenant-1', actor_id => 'actor-1', session_id => 'session-1'};
my $wrong_owner = {%$owner, session_id => 'session-2'};

my $first_id = $worker_one->new_instance_id;
my $first_snapshot = _snapshot($first_id, 'release-1', 'initial');
is(
    $worker_one->create(
        owner_scope => $owner,
        release => 'release-1',
        initial_snapshot => $first_snapshot,
        expires_at => time() + 30,
        instance_id => $first_id,
    ),
    $first_id,
    'worker one creates an opaque instance',
);

my $cross_worker = $worker_two->load(owner_scope => $owner, instance_id => $first_id);
is $cross_worker->{status}, 'ok', 'worker two loads state created by worker one';
is_deeply $cross_worker->{snapshot}, $first_snapshot, 'snapshot survives JSONB storage';
is $cross_worker->{revision}, 0, 'new instance starts at revision zero';
is(
    $worker_two->load(owner_scope => $wrong_owner, instance_id => $first_id)->{status},
    'not_found',
    'owner mismatch does not disclose the instance',
);

my ($scope_digest) = $worker_one_dbh->selectrow_array(
    qq{SELECT owner_scope_digest FROM "$table" WHERE instance_id = ?}, undef, $first_id,
);
like $scope_digest, qr/\A[0-9a-f]{64}\z/, 'owner scope is stored as a digest';
unlike $scope_digest, qr/tenant-1/, 'stored owner binding contains no plaintext tenant';

my $worker_one_copy = $worker_one->load(owner_scope => $owner, instance_id => $first_id);
my $worker_two_copy = $worker_two->load(owner_scope => $owner, instance_id => $first_id);
$worker_one_copy->{snapshot}{state}{search} = 'worker-one';
my $won = $worker_one->compare_and_set(
    owner_scope => $owner,
    instance_id => $first_id,
    revision => $worker_one_copy->{revision},
    next_snapshot => $worker_one_copy->{snapshot},
);
is_deeply $won, {status => 'ok', revision => 1}, 'first worker wins atomic CAS';

$worker_two_copy->{snapshot}{state}{search} = 'worker-two-stale';
my $lost = $worker_two->compare_and_set(
    owner_scope => $owner,
    instance_id => $first_id,
    revision => $worker_two_copy->{revision},
    next_snapshot => $worker_two_copy->{snapshot},
);
is_deeply $lost, {status => 'conflict', revision => 1}, 'stale worker gets current revision';
is(
    $worker_two->load(owner_scope => $owner, instance_id => $first_id)
        ->{snapshot}{state}{search},
    'worker-one',
    'stale CAS cannot overwrite newer state',
);

my $manifest = _manifest();
my $dispatcher_one = Selecto::Components::Templates::Dispatcher->new(store => $worker_one);
my $dispatcher_two = Selecto::Components::Templates::Dispatcher->new(store => $worker_two);
my $mounted = $dispatcher_one->mount(
    owner_scope => $owner,
    manifest => $manifest,
    release_id => 'release-perl-postgresql-1',
    inputs => {},
    expires_at => time() + 30,
);
is $mounted->{status}, 'ok', 'dispatcher mounts through worker one';

my $dispatched = $dispatcher_two->dispatch_params(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    manifest => $manifest,
    event_id => 'postgres-worker-two-event',
    name => 'search_changed',
    params => {value => 'PO-100'},
);
is $dispatched->{status}, 'ok', 'worker two dispatches against shared runtime state';
is $dispatched->{store_revision}, 1, 'cross-worker dispatch advances storage revision';
is(
    $dispatcher_one->load(
        owner_scope => $owner,
        instance_id => $mounted->{instance_id},
    )->{snapshot}{state}{search},
    'PO-100',
    'worker one observes the state committed by worker two',
);

my $small_store = Selecto::Components::Templates::InstanceStore::PostgreSQL->new(
    dbh_provider => sub { $worker_one_dbh },
    table => $table,
    max_snapshot_bytes => 256,
);
my $large_id = $small_store->new_instance_id;
my $large_error = eval {
    $small_store->create(
        owner_scope => $owner,
        release => 'release-large',
        initial_snapshot => {
            %{_snapshot($large_id, 'release-large', 'large')},
            extra => 'x' x 512,
        },
        expires_at => time() + 30,
        instance_id => $large_id,
    );
    '';
};
$large_error = $@ if $@;
like $large_error, qr/^snapshot_too_large:/, 'oversized snapshots fail before insertion';

my @expired_ids;
for my $suffix (1 .. 2) {
    my $instance_id = $worker_one->new_instance_id;
    push @expired_ids, $instance_id;
    $worker_one->create(
        owner_scope => $owner,
        release => "release-expired-$suffix",
        initial_snapshot => _snapshot($instance_id, "release-expired-$suffix", ''),
        expires_at => time() + 0.15,
        instance_id => $instance_id,
    );
}
$worker_one_dbh->selectrow_array('SELECT pg_sleep(0.25)');
is $worker_two->cleanup_expired(limit => 1), 1, 'expiry cleanup obeys its row limit';
is $worker_two->cleanup_expired(limit => 1), 1, 'a later cleanup removes the next row';

my $expiry_id = $worker_one->new_instance_id;
$worker_one->create(
    owner_scope => $owner,
    release => 'release-expiry-result',
    initial_snapshot => _snapshot($expiry_id, 'release-expiry-result', ''),
    expires_at => time() + 0.15,
    instance_id => $expiry_id,
);
$worker_one_dbh->selectrow_array('SELECT pg_sleep(0.25)');
is(
    $worker_two->load(owner_scope => $owner, instance_id => $expiry_id)->{status},
    'expired',
    'load reports an expired instance once',
);
is(
    $worker_one->load(owner_scope => $owner, instance_id => $expiry_id)->{status},
    'not_found',
    'expired load removes the stored instance',
);

is(
    $worker_two->dispose(owner_scope => $owner, instance_id => $first_id)->{status},
    'ok',
    'a second worker can dispose the instance',
);
is(
    $worker_one->load(owner_scope => $owner, instance_id => $first_id)->{status},
    'not_found',
    'disposed state is gone for every worker',
);

$worker_two_dbh->disconnect;
my $unavailable = $dispatcher_two->load(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
);
is $unavailable->{status}, 'error', 'dispatcher contains database failures';
is $unavailable->{code}, 'instance_store_unavailable', 'store failure has a bounded code';
is $unavailable->{message}, 'template instance store is unavailable',
    'store failure does not expose database details';
$worker_two_dbh = undef;

done_testing;

sub _connect {
    return DBI->connect($dsn, undef, undef, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    });
}

sub _store {
    my ($dbh) = @_;
    return Selecto::Components::Templates::InstanceStore::PostgreSQL->new(
        dbh_provider => sub { $dbh },
        table => $table,
    );
}

sub _snapshot {
    my ($instance_id, $release_id, $search) = @_;
    return {
        schema => 'selecto.template.runtime-snapshot.v1',
        instance_id => $instance_id,
        release_id => $release_id,
        state_revision => 0,
        state => {search => $search},
        sources => {},
    };
}

sub _manifest {
    return TestSelectoComponents::template_order_manifest();
}
