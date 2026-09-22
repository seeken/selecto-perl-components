use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Test::More;
use TestSelectoComponents ();

use Selecto::Components::Templates::Dispatcher;
use Selecto::Components::Templates::Event;
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
my $initial_effect = $mounted->{observation}{effects}[0];
my $first_claim = $dispatcher->claim_effect(
    owner_scope => $owner,
    instance_id => $instance_id,
    effect => $initial_effect,
    lease_seconds => 5,
);
is $first_claim->{status}, 'claimed', 'a source generation can be claimed';
my $duplicate_claim = $dispatcher->claim_effect(
    owner_scope => $owner,
    instance_id => $instance_id,
    effect => $initial_effect,
    lease_seconds => 5,
);
is $duplicate_claim->{status}, 'busy', 'a live claim rejects duplicate execution';
$now = 106;
my $replacement_claim = $dispatcher->claim_effect(
    owner_scope => $owner,
    instance_id => $instance_id,
    effect => $initial_effect,
    lease_seconds => 5,
);
is $replacement_claim->{status}, 'claimed', 'an expired claim can be replaced';
isnt $replacement_claim->{claim_token}, $first_claim->{claim_token},
    'a replacement receives a new claim token';
is(
    $dispatcher->release_effect_claim(
        owner_scope => $owner,
        instance_id => $instance_id,
        effect => $initial_effect,
        claim_token => $replacement_claim->{claim_token},
    )->{status},
    'ok',
    'the current worker can release its claim',
);

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

my $browser_manifest = _event_transport_fixture();
for my $case (@{$browser_manifest->{cases}}) {
    my $result = Selecto::Components::Templates::Event->normalize(
        {events => $browser_manifest->{events}}, $case->{event}, $case->{params},
    );
    is $result->{status}, $case->{outcome}, "$case->{id}: outcome";
    if ($case->{outcome} eq 'ok') {
        is_deeply $result->{payload}, $case->{payload}, "$case->{id}: normalized payload";
    } else {
        is $result->{code}, $case->{code}, "$case->{id}: error code";
    }
}
is(
    Selecto::Components::Templates::Event->max_value_bytes(),
    $browser_manifest->{max_value_bytes},
    'transport budget matches the protocol fixture',
);
my $oversized = Selecto::Components::Templates::Event->normalize(
    {events => [{name => 'changed', payload => {value => 'string'}}]},
    'changed', {value => 'x' x (Selecto::Components::Templates::Event->max_value_bytes() + 1)},
);
is $oversized->{code}, 'event_value_too_large', 'oversized browser values fail before dispatch';

my $second = $dispatcher->mount(
    owner_scope => $owner,
    manifest => $manifest,
    release_id => 'release-perl-1',
    inputs => {},
    expires_at => 200,
);
my $browser_integer = $dispatcher->dispatch_params(
    owner_scope => $owner,
    instance_id => $second->{instance_id},
    manifest => $manifest,
    event_id => 'event-perl-browser-1',
    name => 'order_selected',
    expected_state_revision => 0,
    params => {value => '17'},
);
is $browser_integer->{status}, 'ok', 'dispatcher accepts normalized browser parameters';
is $browser_integer->{observation}{snapshot}{state}{selected_order_id}, 17,
    'dispatcher passes an integer to the portable reducer';
my $injected = $dispatcher->dispatch_params(
    owner_scope => $owner,
    instance_id => $second->{instance_id},
    manifest => $manifest,
    event_id => 'event-perl-browser-2',
    name => 'order_selected',
    params => {value => '18', tenant_id => 9},
);
is $injected->{code}, 'invalid_event_params', 'extra browser parameters fail before dispatch';

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

my $claimed_mount = $dispatcher->mount(
    owner_scope => $owner,
    manifest => $manifest,
    release_id => 'release-perl-1',
    inputs => {},
    expires_at => 200,
);
my $claimed_effect = $claimed_mount->{observation}{effects}[0];
my $claimed = $dispatcher->claim_effect(
    owner_scope => $owner,
    instance_id => $claimed_mount->{instance_id},
    effect => $claimed_effect,
    lease_seconds => 10,
);
my $claimed_completion = $dispatcher->complete_claimed_effect(
    owner_scope => $owner,
    instance_id => $claimed_mount->{instance_id},
    manifest => $manifest,
    claim_token => $claimed->{claim_token},
    completion => _completion(
        $claimed_mount->{instance_id}, 1, [{id => 2, order_number => 'PO-200'}],
    ),
);
is $claimed_completion->{status}, 'ok', 'a claimed completion succeeds';
is $claimed_completion->{store_revision}, 1,
    'a claimed completion atomically advances storage';
is $claimed_completion->{observation}{snapshot}{sources}{orders}{status}, 'ready',
    'a claimed completion updates source state';
is(
    $dispatcher->complete_claimed_effect(
        owner_scope => $owner,
        instance_id => $claimed_mount->{instance_id},
        manifest => $manifest,
        claim_token => $claimed->{claim_token},
        completion => _completion(
            $claimed_mount->{instance_id}, 1, [{id => 3, order_number => 'PO-300'}],
        ),
    )->{status},
    'claim_lost',
    'a consumed claim token cannot complete twice',
);

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
    return TestSelectoComponents::template_order_manifest();
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

sub _event_transport_fixture {
    return TestSelectoComponents::template_event_transport_fixture();
}
