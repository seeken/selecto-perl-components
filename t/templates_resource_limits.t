use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Mojo::IOLoop ();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Promise ();
use Mojolicious;
use Test::More;
use Test::Mojo;
use TestSelectoComponents ();
use Selecto::Components::Controller::Templates ();
use Selecto::Components::Templates::InstanceStore::Memory ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Templates::SourceScheduler ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

# ---------------------------------------------------------------------------
# Scheduler: per-owner share of the worker pool
# ---------------------------------------------------------------------------

is(Selecto::Components::Templates::SourceScheduler->new(max_workers => 4)
    ->max_workers_per_owner, 2, 'default per-owner share is half the pool');
is(Selecto::Components::Templates::SourceScheduler->new(max_workers => 1)
    ->max_workers_per_owner, 1, 'a one-worker pool still admits one job per owner');
is(Selecto::Components::Templates::SourceScheduler->new(max_workers => 7)
    ->max_workers_per_owner, 3, 'odd pools round the per-owner share down');
ok !eval {
    Selecto::Components::Templates::SourceScheduler->new(
        max_workers => 2, max_workers_per_owner => 3,
    );
    1;
}, 'per-owner share cannot exceed the pool';
like $@, qr/max_workers_per_owner must be an integer between 1 and 2/,
    'per-owner share validation names the option';

{
    my $scheduler = Selecto::Components::Templates::SourceScheduler->new(
        max_workers => 3, max_workers_per_owner => 1, timeout_seconds => 5,
    );
    my @finished;
    my $slow = sub {
        select undef, undef, undef, 0.3;
        return {status => 'ok'};
    };
    my $first = $scheduler->execute(
        payload => {}, owner_key => 'alice', work => $slow,
        on_finish => sub { push @finished, 'alice' },
    );
    is $first->{status}, 'scheduled', 'first owner job is scheduled';
    is $scheduler->active_workers_for('alice'), 1, 'owner slot is counted';
    my $second = $scheduler->execute(
        payload => {}, owner_key => 'alice', work => $slow,
        on_finish => sub { fail 'over-share work must not run' },
    );
    is $second->{status}, 'busy', 'owner over its share is refused';
    is $second->{code}, 'source_owner_workers_busy', 'per-owner refusal has a stable code';
    is $scheduler->active_workers, 1, 'refused owner work takes no global slot';
    my $other = $scheduler->execute(
        payload => {}, owner_key => 'bob', work => $slow,
        on_finish => sub { push @finished, 'bob' },
    );
    is $other->{status}, 'scheduled', 'another owner still gets a worker';
    my $bad_key = $scheduler->execute(
        payload => {}, owner_key => {}, work => $slow,
        on_finish => sub { fail 'invalid owner keys must not run' },
    );
    is $bad_key->{code}, 'invalid_source_job', 'owner keys must be scalars';
    _drain_until(sub { @finished == 2 && $scheduler->active_workers == 0 });
    is_deeply [sort @finished], [qw(alice bob)], 'both owners completed';
    is $scheduler->active_workers_for('alice'), 0, 'owner slot is released on finish';
    my $again = $scheduler->execute(
        payload => {}, owner_key => 'alice', work => sub { return {status => 'ok'} },
        on_finish => sub { push @finished, 'again' },
    );
    is $again->{status}, 'scheduled', 'owner may run again after its job finished';
    _drain_until(sub { @finished == 3 && $scheduler->active_workers == 0 });

    no warnings 'redefine';
    local *Mojo::IOLoop::Subprocess::run = sub { die "Can't fork: simulated\n" };
    my $unforkable = $scheduler->execute(
        payload => {}, owner_key => 'alice', work => $slow,
        on_finish => sub { fail 'unforked work must not finish' },
    );
    is $unforkable->{code}, 'source_worker_failed', 'fork failure is a bounded error';
    is $scheduler->active_workers, 0, 'fork failure releases the global slot';
    is $scheduler->active_workers_for('alice'), 0, 'fork failure releases the owner slot';
}

# ---------------------------------------------------------------------------
# Shared HTTP fixture
# ---------------------------------------------------------------------------

{ package ResourceLimitDBH; sub new { bless {}, shift } sub errstr { undef } }

my $catalog = TestSelectoComponents::template_domain_catalog();
my $manifest = TestSelectoComponents::template_order_manifest();
my $authorizer = sub {
    my ($ctx) = @_;
    my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
        ->with_required_predicate(
            Selecto::Expression->eq('tenant_id', $ctx->{owner_scope}{tenant_id}),
        );
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => ResourceLimitDBH->new));
    return {status => 'ok', engine => $engine, query => $engine->query};
};
my $row = [1, 'PO-1', '2026-09-22T12:00:00Z', 'open', 44];
my $fast_runner = sub { return {rows => [$row]} };
my $slow_runner = sub {
    select undef, undef, undef, 1.0;
    return {rows => [$row]};
};
my $huge_runner = sub {
    return {rows => [[1, ('X' x 6_000), '2026-09-22T12:00:00Z', 'open', 44]]};
};

sub _registry {
    my $safe = sub { Selecto::Components::Templates::Renderer->safe_html($_[0]) };
    return {
        components => {
            SearchInput => sub {
                my ($node) = @_;
                my $event = $node->{transport}{events}{change};
                my $fields = join '', map {
                    '<input type="hidden" name="' . html_escape($_) . '" value="' .
                        html_escape($event->{fields}{$_}) . '">'
                } sort keys %{$event->{fields}};
                return $safe->('<form data-template-event="' .
                    html_escape($event->{fields}{event}) . '" method="post" action="' .
                    html_escape($event->{action}) . '">' . $fields .
                    '<input name="value" value=""></form>');
            },
            OrderTable => sub { return $safe->('<table></table>') },
        },
        elements => {},
        include => sub { return $safe->('<aside></aside>') },
    };
}

sub _owner_resolver {
    return sub {
        my ($c) = @_;
        my $actor = $c->req->headers->header('X-Actor') // '';
        return {status => 'unauthenticated'} unless length $actor;
        return {status => 'ok', owner_scope => {tenant_id => 7, actor_id => $actor}};
    };
}

my %template_defaults = (
    manifest => $manifest, registry => _registry(), ttl_seconds => 60,
    lease_seconds => 10, source_timeout_seconds => 5,
    source_authorizer => $authorizer,
);
my %alice = ('X-Actor' => 'alice');
my %bob = ('X-Actor' => 'bob');

sub _mount {
    my ($t, $template, $headers) = @_;
    $t->get_ok("/templates/$template" => $headers)->status_is(200);
    return (
        $t->tx->res->headers->header('X-Selecto-Template-Instance'),
        $t->tx->res->dom->at('input[name=csrf_token]')->attr('value'),
    );
}

# ---------------------------------------------------------------------------
# One owner cannot starve another of source workers
# ---------------------------------------------------------------------------

{
    my $now = 1_000;
    my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
        clock => sub { $now },
    );
    my $scheduler = Selecto::Components::Templates::SourceScheduler->new(
        max_workers => 2, timeout_seconds => 5,
    );
    is $scheduler->max_workers_per_owner, 1, 'a two-worker pool gives each owner one';
    my $app = Mojolicious->new;
    $app->secrets(['resource-limits-starvation']);
    $app->plugin('Selecto::Components::Templates' => {
        store => $store, clock => sub { $now }, source_scheduler => $scheduler,
        websocket_heartbeat_interval => 0, install_assets => 0,
        resolve_owner => _owner_resolver(),
        templates => {
            slow => {%template_defaults, release_id => 'slow-v1',
                source_runner => $slow_runner},
            fast => {%template_defaults, release_id => 'fast-v1',
                source_runner => $fast_runner},
        },
    });
    my $alice_t = Test::Mojo->new($app);
    my $bob_t = Test::Mojo->new($app);
    my ($alice_one, $alice_csrf) = _mount($alice_t, 'slow', \%alice);
    my ($alice_two) = _mount($alice_t, 'slow', \%alice);
    my ($bob_one, $bob_csrf) = _mount($bob_t, 'fast', \%bob);
    my $alice_key = Selecto::Components::Controller::Templates::owner_key(
        {tenant_id => 7, actor_id => 'alice'},
    );

    my $held_response;
    my $held = $alice_t->ua->post_p(
        "/template-instances/$alice_one/sources/orders" => \%alice
            => form => {csrf_token => $alice_csrf},
    )->then(sub { $held_response = $_[0]->res });
    Mojo::IOLoop->one_tick until $scheduler->active_workers_for($alice_key) == 1;

    my $second;
    $alice_t->ua->post_p(
        "/template-instances/$alice_two/sources/orders" => \%alice
            => form => {csrf_token => $alice_csrf},
    )->then(sub { $second = $_[0]->res })->wait;
    is $second->code, 409, 'the same owner over its share receives 409';
    like $second->body, qr/data-selecto-template-error="source_owner_workers_busy"/,
        'the owner refusal is distinguishable from a full pool';

    my $bob_response;
    $bob_t->ua->post_p(
        "/template-instances/$bob_one/sources/orders" => \%bob
            => form => {csrf_token => $bob_csrf},
    )->then(sub { $bob_response = $_[0]->res })->wait;
    is $bob_response->code, 200,
        'a different owner is served while the first owner holds a worker';
    ok !defined($held_response), 'the first owner request was still running';

    $held->wait;
    is $held_response->code, 200, 'the held owner request completes';
    $alice_t->post_ok(
        "/template-instances/$alice_two/sources/orders" => \%alice
            => form => {csrf_token => $alice_csrf},
    )->status_is(200, 'the refused source claim was released and can be retried');
}

ok !eval {
    Mojolicious->new->plugin('Selecto::Components::Templates' => {
        store => Selecto::Components::Templates::InstanceStore::Memory->new,
        resolve_owner => _owner_resolver(), install_assets => 0,
        source_max_workers => 2, source_max_workers_per_owner => 3,
        templates => {fast => {%template_defaults, release_id => 'v1'}},
    });
    1;
}, 'plugin rejects a per-owner share larger than the pool';
like $@, qr/source_max_workers_per_owner must be an integer between 1 and 2/,
    'plugin per-owner validation names the option';

# ---------------------------------------------------------------------------
# Per-owner live instance cap on mount
# ---------------------------------------------------------------------------

{
    my $now = 1_000;
    my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
        clock => sub { $now },
    );
    is $store->max_instances_per_owner, 32, 'memory store defaults to 32 live instances';
    my $app = Mojolicious->new;
    $app->secrets(['resource-limits-instances']);
    $app->plugin('Selecto::Components::Templates' => {
        store => $store, clock => sub { $now }, max_instances_per_owner => 3,
        websocket_heartbeat_interval => 0, install_assets => 0,
        resolve_owner => _owner_resolver(),
        templates => {orders => {%template_defaults, release_id => 'orders-v1',
            source_runner => $fast_runner}},
    });
    my $t = Test::Mojo->new($app);
    my ($bob_instance) = _mount($t, 'orders', \%bob);
    my @alice_instances = map { (_mount($t, 'orders', \%alice))[0] } 1 .. 5;
    my $owned_by = sub {
        my ($actor) = @_;
        my $key = $store->_scope_key({tenant_id => 7, actor_id => $actor});
        return scalar grep { $_->{owner_scope} eq $key } values %{$store->{instances}};
    };
    is $owned_by->('alice'), 3, 'five GETs leave only three live instances for the owner';
    is $owned_by->('bob'), 1, 'another owner keeps its instance';
    $t->get_ok("/template-instances/$alice_instances[0]" => \%alice)
        ->status_is(404, 'the oldest instance was evicted');
    $t->get_ok("/template-instances/$alice_instances[1]" => \%alice)
        ->status_is(404, 'the second oldest instance was evicted');
    $t->get_ok("/template-instances/$_" => \%alice)
        ->status_is(200, 'a recent instance survives') for @alice_instances[2 .. 4];
    $t->get_ok("/template-instances/$bob_instance" => \%bob)->status_is(200);

    ok !eval {
        Mojolicious->new->plugin('Selecto::Components::Templates' => {
            store => $store, resolve_owner => _owner_resolver(), install_assets => 0,
            max_instances_per_owner => 0,
            templates => {orders => {%template_defaults, release_id => 'v2'}},
        });
        1;
    }, 'a zero instance cap is rejected';
}

{
    my $now = 1_000;
    my $sequence = 0;
    my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
        clock => sub { $now }, max_instances_per_owner => 2,
        id_generator => sub { 'instance-' . ++$sequence },
    );
    my $owner = {tenant_id => 7, actor_id => 'carol'};
    my $create = sub {
        my (%args) = @_;
        my $id = $store->new_instance_id;
        return $store->create(
            owner_scope => $owner, release => 'r1', expires_at => $now + ($args{ttl} // 60),
            initial_snapshot => {instance_id => $id, release_id => 'r1'},
            instance_id => $id,
            (exists($args{cap}) ? (max_instances_per_owner => $args{cap}) : ()),
        );
    };
    my $short = $create->(ttl => 5);
    my $long = $create->();
    $now += 10;
    my $third = $create->();
    is $store->load(owner_scope => $owner, instance_id => $short)->{status}, 'not_found',
        'an expired row of the owner is deleted on mount';
    is $store->load(owner_scope => $owner, instance_id => $long)->{status}, 'ok',
        'expired rows do not count against the live cap';
    my $fourth = $create->();
    is $store->load(owner_scope => $owner, instance_id => $long)->{status}, 'not_found',
        'the oldest live instance is evicted at the cap';
    is $store->load(owner_scope => $owner, instance_id => $fourth)->{status}, 'ok',
        'the new instance is always kept';
    $create->(cap => 1);
    is scalar(keys %{$store->{instances}}), 1, 'a per-call cap overrides the store default';
    ok !eval { $create->(cap => 'lots'); 1 }, 'an invalid per-call cap is rejected';
    like $@, qr/\Ainvalid_limit:/, 'invalid cap reports invalid_limit';
}

# ---------------------------------------------------------------------------
# Periodic cleanup of expired instances and claims
# ---------------------------------------------------------------------------

{
    my $now = 1_000;
    my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
        clock => sub { $now },
    );
    my $owner = {tenant_id => 7, actor_id => 'dana'};
    for my $id (qw(expired-1 expired-2 live-1)) {
        $store->create(
            owner_scope => $owner, release => 'r1', instance_id => $id,
            expires_at => $now + ($id =~ /expired/ ? 5 : 600),
            initial_snapshot => {instance_id => $id, release_id => 'r1',
                sources => {orders => {status => 'loading', generation => 1}}},
        );
    }
    my $claim = $store->claim_effect(
        owner_scope => $owner, instance_id => 'live-1', source => 'orders',
        generation => 1, effect_id => 'live-1:source:orders:1', lease_seconds => 5,
    );
    is $claim->{status}, 'claimed', 'fixture claim was taken';
    $now += 10;
    is $store->cleanup_expired(limit => 1), 1, 'memory cleanup obeys its row limit';
    is $store->cleanup_expired, 1, 'memory cleanup removes the next expired row';
    is $store->cleanup_expired, 0, 'memory cleanup leaves live rows';
    is $store->cleanup_expired_claims, 1, 'memory claim cleanup removes expired leases';
    is scalar(keys %{$store->{instances}{'live-1'}{effect_claims}}), 0,
        'the expired lease is gone';
}

{
    my $now = 1_000;
    my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
        clock => sub { $now },
    );
    my $app = Mojolicious->new;
    $app->secrets(['resource-limits-cleanup']);
    $app->log->level('fatal');
    $app->plugin('Selecto::Components::Templates' => {
        store => $store, clock => sub { $now }, cleanup_interval_seconds => 1,
        websocket_heartbeat_interval => 0, install_assets => 0,
        resolve_owner => _owner_resolver(),
        templates => {orders => {%template_defaults, release_id => 'orders-v1',
            source_runner => $fast_runner}},
    });
    my $t = Test::Mojo->new($app);
    _mount($t, 'orders', \%alice);
    is scalar(keys %{$store->{instances}}), 1, 'cleanup fixture mounted one instance';
    $now += 120;
    {
        local $Selecto::Components::Templates::SourceScheduler::IN_WORKER = 1;
        _run_loop_for(1.3);
        is scalar(keys %{$store->{instances}}), 1,
            'the cleanup timer does nothing inside a source worker';
    }
    _run_loop_for(1.3);
    is scalar(keys %{$store->{instances}}), 0,
        'the plugin timer removes expired instances without a reload';

    ok !eval {
        Mojolicious->new->plugin('Selecto::Components::Templates' => {
            store => $store, resolve_owner => _owner_resolver(), install_assets => 0,
            cleanup_interval_seconds => -1,
            templates => {orders => {%template_defaults, release_id => 'v3'}},
        });
        1;
    }, 'a negative cleanup interval is rejected';
    like $@, qr/cleanup_interval_seconds must be an integer between 0 and 86400/,
        'cleanup interval validation names the option';
}

# ---------------------------------------------------------------------------
# Oversized snapshots are client errors, not store outages
# ---------------------------------------------------------------------------

{
    my $now = 1_000;
    my $probe = Selecto::Templates->mount_runtime(
        $manifest, instance_id => ('0' x 64), release_id => 'orders-v1', inputs => {},
    );
    my $base = length JSON::PP->new->canonical(1)->ascii(1)->encode($probe->{snapshot});
    my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
        clock => sub { $now }, max_snapshot_bytes => $base + 1_024,
    );
    my $app = Mojolicious->new;
    $app->secrets(['resource-limits-snapshot']);
    $app->plugin('Selecto::Components::Templates' => {
        store => $store, clock => sub { $now },
        websocket_heartbeat_interval => 0, install_assets => 0,
        resolve_owner => _owner_resolver(),
        templates => {
            orders => {%template_defaults, release_id => 'orders-v1',
                source_runner => $huge_runner},
        },
    });
    my $t = Test::Mojo->new($app);
    my ($instance, $csrf) = _mount($t, 'orders', \%alice);
    my $form = $t->tx->res->dom->at('form[data-template-event=search_changed]');
    my %fields = map { $_->attr('name') => $_->attr('value') }
        @{$form->find('input[type=hidden]')};
    $t->post_ok("/template-instances/$instance/events" => \%alice
        => form => {%fields, value => ('s' x 4_000)})
        ->status_is(422, 'an event that overflows the snapshot is a client error')
        ->element_exists('[data-selecto-template-error="snapshot_too_large"]')
        ->content_like(qr/Template state is too large\./, 'the message is fixed');

    $t->post_ok("/template-instances/$instance/sources/orders" => \%alice
        => form => {csrf_token => $csrf})
        ->status_is(422, 'a source result that overflows the snapshot is a client error')
        ->element_exists('[data-selecto-template-error="snapshot_too_large"]');
    my $loaded = $store->load(
        owner_scope => {tenant_id => 7, actor_id => 'alice'}, instance_id => $instance,
    );
    is $loaded->{snapshot}{sources}{orders}{status}, 'error',
        'the overflowing source is completed with an error instead of staying loading';
    is $loaded->{snapshot}{sources}{orders}{error}{code}, 'source_result_too_large',
        'the stored source error is bounded';
    is scalar(keys %{$store->{instances}{$instance}{effect_claims}}), 0,
        'the source claim is not left behind';
}

done_testing;

sub _run_loop_for {
    my ($seconds) = @_;
    Mojo::IOLoop->timer($seconds => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
}

sub _drain_until {
    my ($condition) = @_;
    my $watcher;
    my $guard = Mojo::IOLoop->timer(5 => sub { Mojo::IOLoop->stop });
    $watcher = Mojo::IOLoop->recurring(0.005 => sub {
        return unless $condition->();
        Mojo::IOLoop->remove($guard);
        Mojo::IOLoop->remove($watcher);
        Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->start;
    ok $condition->(), 'scheduler work drained';
}
