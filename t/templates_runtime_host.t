use 5.034;
use strict;
use warnings;

use JSON::PP ();
use Test::More;

use Selecto::Components::Templates::Dispatcher;
use Selecto::Components::Templates::InstanceStore::Memory;

my $now = 100;
my $next_id = 0;
my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
    clock => sub { $now },
    id_generator => sub { 'instance-perl-' . ++$next_id },
);
my $dispatcher = Selecto::Components::Templates::Dispatcher->new(store => $store);
my $manifest = _manifest();
my $owner = {tenant_id => 'tenant-1', actor_id => 'actor-1', session_id => 'session-1'};

my $mounted = $dispatcher->mount(
    owner_scope => $owner,
    manifest => $manifest,
    release_id => 'release-perl-1',
    inputs => {},
    expires_at => 200,
);
is $mounted->{status}, 'ok', 'mount creates a server-side instance';
is $mounted->{instance_id}, 'instance-perl-1', 'store owns the opaque instance ID';
is $mounted->{observation}{snapshot}{state_revision}, 0, 'runtime begins at revision zero';
is scalar(@{$mounted->{observation}{effects}}), 1, 'mount returns its initial source effect';

my $instance_id = $mounted->{instance_id};
my $wrong_owner = $dispatcher->load(
    owner_scope => {%$owner, actor_id => 'actor-2'},
    instance_id => $instance_id,
);
is $wrong_owner->{status}, 'not_found', 'an owner mismatch does not disclose the instance';

my $loaded = $dispatcher->load(owner_scope => $owner, instance_id => $instance_id);
$loaded->{snapshot}{state}{search} = 'tampered copy';
my $reloaded = $dispatcher->load(owner_scope => $owner, instance_id => $instance_id);
is $reloaded->{snapshot}{state}{search}, '', 'load returns an isolated snapshot copy';

my $dispatched = $dispatcher->dispatch(
    owner_scope => $owner,
    instance_id => $instance_id,
    manifest => $manifest,
    event_id => 'event-perl-1',
    name => 'search_changed',
    expected_state_revision => 0,
    payload => {value => 'PO-100'},
);
is $dispatched->{status}, 'ok', 'declared event dispatch succeeds';
is $dispatched->{store_revision}, 1, 'accepted event advances the store CAS revision';
is $dispatched->{observation}{snapshot}{state}{search}, 'PO-100',
    'portable reducer updates state';
is $dispatched->{observation}{effects}[0]{generation}, 2,
    'portable reducer emits the next source generation';

my $stale_event = $dispatcher->dispatch(
    owner_scope => $owner,
    instance_id => $instance_id,
    manifest => $manifest,
    event_id => 'event-perl-2',
    name => 'search_changed',
    expected_state_revision => 0,
    payload => {value => 'stale'},
);
is $stale_event->{status}, 'ok', 'stale event is a valid reducer observation';
is $stale_event->{observation}{outcome}, 'rejected', 'stale event is rejected';
is $stale_event->{observation}{code}, 'stale_revision', 'stale revision is explicit';
is $stale_event->{store_revision}, 1, 'a rejected event does not advance storage';

my $stale_completion = $dispatcher->complete(
    owner_scope => $owner,
    instance_id => $instance_id,
    manifest => $manifest,
    completion => _completion($instance_id, 1, [{id => 99}]),
);
is $stale_completion->{observation}{outcome}, 'ignored', 'stale completion is ignored';
is $stale_completion->{observation}{code}, 'stale_completion',
    'stale completion reason is explicit';
is $stale_completion->{store_revision}, 1, 'ignored completion does not advance storage';

my $completion = $dispatcher->complete(
    owner_scope => $owner,
    instance_id => $instance_id,
    manifest => $manifest,
    completion => _completion($instance_id, 2, [{id => 1, order_number => 'PO-100'}]),
);
is $completion->{status}, 'ok', 'current completion succeeds';
is $completion->{store_revision}, 2, 'accepted completion advances the CAS revision';
is $completion->{observation}{snapshot}{sources}{orders}{status}, 'ready',
    'accepted completion updates source state';

my $conflict = $store->compare_and_set(
    owner_scope => $owner,
    instance_id => $instance_id,
    revision => 1,
    next_snapshot => $completion->{observation}{snapshot},
);
is $conflict->{status}, 'conflict', 'stale store revisions fail compare-and-set';
is $conflict->{revision}, 2, 'conflict reports the current store revision';

$now = 201;
my $expired = $dispatcher->load(owner_scope => $owner, instance_id => $instance_id);
is $expired->{status}, 'expired', 'expired instances return an explicit result';
my $gone = $dispatcher->load(owner_scope => $owner, instance_id => $instance_id);
is $gone->{status}, 'not_found', 'expired instances are removed from memory storage';

done_testing;

sub _manifest {
    my $path = '../selecto-protocol/spec/fixtures/templates/order-browser.compile.json';
    open my $file, '<:raw', $path or die "could not read $path: $!";
    local $/;
    return JSON::PP->new->utf8(1)->decode(<$file>);
}

sub _completion {
    my ($instance_id, $generation, $rows) = @_;
    return {
        schema => 'selecto.template.runtime-completion.v1',
        instance_id => $instance_id,
        release_id => 'release-perl-1',
        effect_id => "$instance_id:source:orders:$generation",
        source => 'orders',
        generation => $generation,
        outcome => 'ok',
        result => $rows,
    };
}
