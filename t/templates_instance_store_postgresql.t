use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use POSIX qw(_exit);
use Storable qw(dclone);
use Test::More;
use Time::HiRes qw(time);
use TestSelectoComponents ();

use Selecto::Components::Templates::Dispatcher;
use Selecto::Components::Templates::InstanceStore::PostgreSQL;

{
    package Selecto::Components::Templates::PausedPageStore;
    use parent 'Selecto::Components::Templates::InstanceStore::PostgreSQL';

    sub compare_and_set {
        my ($self, %args) = @_;
        if (my $ready = delete $self->{race_ready_fh}) {
            my $go = delete $self->{race_go_fh};
            syswrite($ready, 'R') == 1 or die "page race readiness failed\n";
            my $signal;
            sysread($go, $signal, 1) == 1 && $signal eq 'G'
                or die "page race release failed\n";
        }
        return $self->SUPER::compare_and_set(%args);
    }
}

my $dsn = $ENV{SELECTO_TEMPLATES_POSTGRES_DSN};
plan skip_all => 'template PostgreSQL DSN is not configured'
    unless defined($dsn) && length($dsn);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };

my $worker_one_dbh = _connect();
my $worker_two_dbh = _connect();
my $table = sprintf 'selecto_template_instances_%d_%d', $$, int(time() * 1_000_000);
my $claims_table = $table . '_claims';
my $worker_one = _store($worker_one_dbh);
my $worker_two = _store($worker_two_dbh);
$worker_one->install_schema;

END {
    eval { $worker_one_dbh->do(qq{DROP TABLE IF EXISTS "$claims_table"}) if $worker_one_dbh };
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

my $effect_two = $dispatched->{observation}{effects}[0];
my $claim_one = $dispatcher_one->claim_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    effect => $effect_two,
    lease_seconds => 5,
);
is $claim_one->{status}, 'claimed', 'worker one claims the current source generation';
my $claim_two = $dispatcher_two->claim_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    effect => $effect_two,
    lease_seconds => 5,
);
is $claim_two->{status}, 'busy', 'worker two cannot duplicate a live source claim';
is(
    $dispatcher_two->claim_effect(
        owner_scope => $wrong_owner,
        instance_id => $mounted->{instance_id},
        effect => $effect_two,
        lease_seconds => 5,
    )->{status},
    'not_found',
    'a claim does not disclose an instance to another owner',
);

my $claimed_completion = $dispatcher_one->complete_claimed_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    manifest => $manifest,
    claim_token => $claim_one->{claim_token},
    completion => _completion(
        $mounted->{instance_id}, 'release-perl-postgresql-1', 2,
        [{id => 1, order_number => 'PO-100'}],
    ),
);
is $claimed_completion->{status}, 'ok', 'the claim owner commits its completion';
is $claimed_completion->{store_revision}, 2,
    'claimed completion and claim consumption are one revisioned update';
is(
    $dispatcher_two->complete_claimed_effect(
        owner_scope => $owner,
        instance_id => $mounted->{instance_id},
        manifest => $manifest,
        claim_token => $claim_one->{claim_token},
        completion => _completion(
            $mounted->{instance_id}, 'release-perl-postgresql-1', 2,
            [{id => 2, order_number => 'PO-duplicate'}],
        ),
    )->{status},
    'claim_lost',
    'a consumed PostgreSQL claim cannot complete twice',
);

my $third_generation = $dispatcher_one->dispatch_params(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    manifest => $manifest,
    event_id => 'postgres-worker-one-next-event',
    name => 'search_changed',
    params => {value => 'PO-200'},
);
is $third_generation->{store_revision}, 3, 'a later event creates another generation';
my $effect_three = $third_generation->{observation}{effects}[0];
my $expiring_claim = $dispatcher_one->claim_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    effect => $effect_three,
    lease_seconds => 1,
);
is $expiring_claim->{status}, 'claimed', 'worker one obtains a short source lease';
$worker_one_dbh->selectrow_array('SELECT pg_sleep(1.05)');
my $replacement_claim = $dispatcher_two->claim_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    effect => $effect_three,
    lease_seconds => 5,
);
is $replacement_claim->{status}, 'claimed', 'worker two replaces an expired source lease';
isnt $replacement_claim->{claim_token}, $expiring_claim->{claim_token},
    'the replacement lease has a new token';
is(
    $dispatcher_one->complete_claimed_effect(
        owner_scope => $owner,
        instance_id => $mounted->{instance_id},
        manifest => $manifest,
        claim_token => $expiring_claim->{claim_token},
        completion => _completion(
            $mounted->{instance_id}, 'release-perl-postgresql-1', 3,
            [{id => 3, order_number => 'PO-old-worker'}],
        ),
    )->{status},
    'claim_lost',
    'an expired worker cannot commit after the lease is replaced',
);
my $replacement_completion = $dispatcher_two->complete_claimed_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    manifest => $manifest,
    claim_token => $replacement_claim->{claim_token},
    completion => _completion(
        $mounted->{instance_id}, 'release-perl-postgresql-1', 3,
        [{id => 4, order_number => 'PO-200'}],
    ),
);
is $replacement_completion->{status}, 'ok', 'the replacement worker commits once';
is $replacement_completion->{store_revision}, 4,
    'the replacement completion advances the shared revision';

my $cleanup_generation = $dispatcher_one->dispatch_params(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    manifest => $manifest,
    event_id => 'postgres-claim-cleanup-event',
    name => 'search_changed',
    params => {value => 'PO-300'},
);
is $cleanup_generation->{store_revision}, 5,
    'another event creates a generation for abandoned-claim cleanup';
my $cleanup_effect = $cleanup_generation->{observation}{effects}[0];
my $abandoned_claim = $dispatcher_one->claim_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    effect => $cleanup_effect,
    lease_seconds => 1,
);
is $abandoned_claim->{status}, 'claimed', 'a worker can abandon a short lease';
$worker_one_dbh->selectrow_array('SELECT pg_sleep(1.05)');
is $worker_two->cleanup_expired_claims(limit => 1), 1,
    'expired effect-claim cleanup obeys its row limit';
my $claim_after_cleanup = $dispatcher_two->claim_effect(
    owner_scope => $owner,
    instance_id => $mounted->{instance_id},
    effect => $cleanup_effect,
    lease_seconds => 5,
);
is $claim_after_cleanup->{status}, 'claimed', 'a cleaned generation can be claimed again';
is(
    $dispatcher_two->release_effect_claim(
        owner_scope => $owner,
        instance_id => $mounted->{instance_id},
        effect => $cleanup_effect,
        claim_token => $claim_after_cleanup->{claim_token},
    )->{status},
    'ok',
    'a PostgreSQL claim can be released explicitly',
);

my $page_fixture_path =
    "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/runtime-page-commit.cases.json";
open my $page_fixture, '<:raw', $page_fixture_path
    or die "cannot read $page_fixture_path: $!";
my $page_fixture_text = do { local $/; <$page_fixture> };
close $page_fixture;
my $page_case = JSON::PP->new->utf8(1)->decode($page_fixture_text)->{cases}[0];
my $page_mount = $dispatcher_one->mount(
    owner_scope => $owner, manifest => $manifest,
    release_id => 'release-perl-page-race', inputs => {},
    expires_at => time() + 30,
);
is $page_mount->{status}, 'ok', 'worker one mounts the shared paged instance';
my $page_instance = $page_mount->{instance_id};
my $initial_pages = dclone($page_case->{snapshot}{sources}{orders}{result});
push @{$initial_pages->{rows}}, {id => 2, lines => [{id => 21}]};
push @{$initial_pages->{pages}}, {
    collection_path => ['lines'], parent_path => [2],
    has_more => JSON::PP::true, after_values => [21],
};
push @{$initial_pages->{identities}}, {
    collection_path => ['lines'], parent_path => [2], row_keys => [21],
};
my $page_ready = $dispatcher_two->complete(
    owner_scope => $owner, instance_id => $page_instance,
    manifest => $manifest,
    completion => _completion(
        $page_instance, 'release-perl-page-race', 1, $initial_pages,
    ),
);
is $page_ready->{store_revision}, 1,
    'worker two stores the two-parent first page';

my $page_commit_for = sub {
    my ($snapshot, $parent_index) = @_;
    my $result = dclone($snapshot->{sources}{orders}{result});
    my $next_line_id = $parent_index ? 22 : 12;
    push @{$result->{rows}[$parent_index]{lines}}, {id => $next_line_id};
    $result->{pages}[$parent_index]{has_more} = JSON::PP::false;
    $result->{pages}[$parent_index]{after_values} = undef;
    push @{$result->{identities}[$parent_index]{row_keys}}, $next_line_id;
    return {
        schema => 'selecto.template.runtime-page-commit.v1',
        instance_id => $page_instance,
        release_id => 'release-perl-page-race', source => 'orders',
        generation => $snapshot->{sources}{orders}{generation},
        expected_state_revision => $snapshot->{state_revision},
        expected_page => $snapshot->{sources}{orders}{page},
        result => $result,
    };
};

pipe(my $child_result_read, my $child_result_write)
    or die "cannot create page-race result pipe: $!";
pipe(my $child_go_read, my $child_go_write)
    or die "cannot create page-race release pipe: $!";
my $page_race_pid = fork();
defined($page_race_pid) or die "cannot fork page-race worker: $!";
if ($page_race_pid == 0) {
    close $child_result_read;
    close $child_go_write;
    my $child_dbh = _connect();
    my $child_store = Selecto::Components::Templates::PausedPageStore->new(
        dbh_provider => sub { $child_dbh },
        table => $table, claims_table => $claims_table,
    );
    $child_store->{race_ready_fh} = $child_result_write;
    $child_store->{race_go_fh} = $child_go_read;
    my $child_dispatcher = Selecto::Components::Templates::Dispatcher->new(
        store => $child_store,
    );
    my $child_result = $child_dispatcher->commit_page(
        owner_scope => $owner, instance_id => $page_instance,
        manifest => $manifest,
        commit => $page_commit_for->($page_ready->{observation}{snapshot}, 1),
    );
    my $encoded = JSON::PP->new->canonical(1)->encode($child_result);
    syswrite($child_result_write, $encoded) == length($encoded)
        or _exit(2);
    close $child_result_write;
    close $child_go_read;
    _exit(0);
}
close $child_result_write;
close $child_go_read;
my $ready_signal;
sysread($child_result_read, $ready_signal, 1) == 1
    && $ready_signal eq 'R'
    or die "page-race worker did not reach the store commit\n";
my $winning_page = $dispatcher_one->commit_page(
    owner_scope => $owner, instance_id => $page_instance,
    manifest => $manifest,
    commit => $page_commit_for->($page_ready->{observation}{snapshot}, 0),
);
is $winning_page->{status}, 'ok',
    'worker one commits a page while worker two holds an older snapshot';
is $winning_page->{store_revision}, 2,
    'the first page commit advances the shared PostgreSQL revision';
syswrite($child_go_write, 'G') == 1 or die "cannot release page-race worker\n";
close $child_go_write;
my $child_result_json = do { local $/; <$child_result_read> };
close $child_result_read;
waitpid($page_race_pid, 0);
is $?, 0, 'the second page worker exits cleanly';
my $losing_page = JSON::PP->new->decode($child_result_json);
is_deeply $losing_page, {status => 'conflict', revision => 2},
    'the paused worker cannot overwrite the other parent page';
my $after_race = $dispatcher_two->load(
    owner_scope => $owner, instance_id => $page_instance,
);
is_deeply [map { $_->{id} }
    @{$after_race->{snapshot}{sources}{orders}{result}{rows}[0]{lines}}],
    [11, 12], 'the winning parent retains its advanced rows';
is_deeply [map { $_->{id} }
    @{$after_race->{snapshot}{sources}{orders}{result}{rows}[1]{lines}}],
    [21], 'the losing parent remains on its first page';
my $retried_page = $dispatcher_two->commit_page(
    owner_scope => $owner, instance_id => $page_instance,
    manifest => $manifest,
    commit => $page_commit_for->($after_race->{snapshot}, 1),
);
is $retried_page->{status}, 'ok',
    'the other worker can retry the untouched parent from fresh state';
is $retried_page->{store_revision}, 3,
    'the retry advances the shared revision exactly once';
my $after_retry = $dispatcher_one->load(
    owner_scope => $owner, instance_id => $page_instance,
);
is_deeply [map { [map { $_->{id} } @{$_->{lines}}] }
    @{$after_retry->{snapshot}{sources}{orders}{result}{rows}}],
    [[11, 12], [21, 22]],
    'both workers observe both parent continuations after retry';

my $small_store = Selecto::Components::Templates::InstanceStore::PostgreSQL->new(
    dbh_provider => sub { $worker_one_dbh },
    table => $table,
    claims_table => $claims_table,
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
        claims_table => $claims_table,
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

sub _completion {
    my ($instance_id, $release_id, $generation, $rows) = @_;
    return {
        schema => 'selecto.template.runtime-completion.v1',
        instance_id => $instance_id,
        release_id => $release_id,
        effect_id => "$instance_id:source:orders:$generation",
        source => 'orders',
        generation => $generation,
        outcome => 'ok',
        result => $rows,
    };
}
