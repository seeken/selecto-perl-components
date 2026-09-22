use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use File::Temp qw(tempfile);
use JSON::PP ();
use Mojolicious;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Promise;
use Test::More;
use Test::Mojo;
use TestSelectoComponents ();
use Selecto::Components::AssetManifest qw(asset_revision);
use Selecto::Components::Templates::InstanceStore::Memory ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

my $now = 1_000;
my $instance_sequence = 0;
my $claim_sequence = 0;
my $event_sequence = 0;
my $source_context_calls = 0;
my $alice_revoked = 0;
my ($worker_audit_handle, $worker_audit_path) = tempfile();
close $worker_audit_handle;
my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
    clock => sub { $now },
    id_generator => sub { 'http-instance-' . ++$instance_sequence },
    claim_token_generator => sub { 'http-claim-' . ++$claim_sequence },
);
my $manifest = TestSelectoComponents::template_order_manifest();
my $catalog = TestSelectoComponents::template_domain_catalog();
my $app = Mojolicious->new;
$app->secrets(['template-http-test-secret']);
$app->routes->get('/template-probe')->to(cb => sub {
    my ($controller) = @_;
    return $controller->render(text => 'ready');
});
my $resolve_source_context = sub {
    my ($controller, $owner_scope, $effect) = @_;
    $source_context_calls++;
    return {
        tenant_id => $owner_scope->{tenant_id},
        actor_id => $owner_scope->{actor_id},
        request_actor => $controller->req->headers->header('X-Test-Actor'),
        source => $effect->{source},
    };
};
my $source_authorizer = sub {
    my ($source_context, $source, $effect) = @_;
    die "invalid source context\n"
        unless $source_context->{tenant_id} == 7
        && $source_context->{actor_id} eq $source_context->{request_actor}
        && $source_context->{source} eq $source->{id};
    open my $audit, '>>', $worker_audit_path
        or die "worker audit unavailable\n";
    print {$audit} join(':', $$, $source_context->{actor_id},
        $source->{id}, $effect->{generation}), "\n";
    close $audit;
    my $domain = Selecto::Domain->parse(
        $catalog->{domains}{orders}, strict => 1,
    )->with_required_predicate(
        Selecto::Expression->eq('tenant_id', $source_context->{tenant_id}),
    );
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(
            dbh => TemplateHTTPDBH->new,
        ),
    );
    return {status => 'ok', engine => $engine, query => $engine->query};
};
my $source_runner = sub {
    my ($engine, $query, $effect) = @_;
    my $search = $effect->{bindings}{state}{search};
    my $number = length($search) ? $search : 'PO-100';
    return {rows => [[
        1, $number, '2026-09-22T12:00:00Z', 'open', 44,
    ]]};
};
$app->plugin('Selecto::Components::Templates' => {
    store => $store,
    clock => sub { $now },
    source_max_workers => 2,
    websocket_heartbeat_interval => 0,
    event_id_generator => sub { 'http-event-' . ++$event_sequence },
    resolve_owner => sub {
        my ($controller) = @_;
        my $actor = $controller->req->headers->header('X-Test-Actor') // '';
        return {status => 'unauthenticated'} unless length $actor;
        return {status => 'forbidden'} if $actor eq 'forbidden';
        return {status => 'forbidden'} if $actor eq 'alice' && $alice_revoked;
        return {status => 'ok', owner_scope => {
            tenant_id => 7, actor_id => "$actor", session_id => 'session-http',
        }};
    },
    templates => {
        orders => {
            title => 'Orders template',
            release_id => 'orders-http-v1',
            manifest => $manifest,
            registry => _registry(),
            ttl_seconds => 60,
            lease_seconds => 10,
            source_timeout_seconds => 5,
            resolve_source_context => $resolve_source_context,
            source_authorizer => $source_authorizer,
            source_runner => $source_runner,
        },
        slow_orders => {
            title => 'Slow orders template',
            release_id => 'slow-orders-http-v1',
            manifest => $manifest,
            registry => _registry(),
            ttl_seconds => 60,
            lease_seconds => 10,
            source_timeout_seconds => 2,
            resolve_source_context => $resolve_source_context,
            source_authorizer => $source_authorizer,
            source_runner => sub {
                my ($engine, $query, $effect) = @_;
                select undef, undef, undef, 0.25;
                return $source_runner->($engine, $query, $effect);
            },
        },
        invalid_context => {
            title => 'Invalid source context template',
            release_id => 'invalid-source-context-http-v1',
            manifest => $manifest,
            registry => _registry(),
            ttl_seconds => 60,
            lease_seconds => 10,
            source_timeout_seconds => 5,
            resolve_source_context => sub { return {unsafe => sub { return 1 }} },
            source_authorizer => $source_authorizer,
            source_runner => $source_runner,
        },
    },
});

my $t = Test::Mojo->new($app);
$t->get_ok('/templates/orders')
    ->status_is(401)
    ->header_is('Cache-Control' => 'no-store, private')
    ->element_exists('[data-selecto-template-error="authentication_required"]');
$t->get_ok('/templates/orders' => {'X-Test-Actor' => 'forbidden'})
    ->status_is(403)
    ->element_exists('[data-selecto-template-error="template_forbidden"]');
$t->get_ok('/templates/missing' => {'X-Test-Actor' => 'alice'})
    ->status_is(404)
    ->element_exists('[data-selecto-template-error="template_not_found"]');
$t->get_ok('/selecto-components/htmx.min.js')->status_is(200);

$t->get_ok('/templates/orders' => {'X-Test-Actor' => 'alice'})
    ->status_is(200)
    ->content_type_like(qr{text/html})
    ->header_is('Cache-Control' => 'no-store, private')
    ->header_is('X-Selecto-State-Revision' => 0)
    ->header_is('X-Selecto-Store-Revision' => 0)
    ->element_exists('main.selecto-template-instance[hx-history="false"]' .
        '[hx-status\\:4xx="swap: outerHTML"][hx-status\\:5xx="swap: outerHTML"]')
    ->element_exists('section.selecto-template-channel[hx-ext="ws"][hx-ws\\:connect]')
    ->element_exists('script[src="/selecto-components/htmx.min.js?v=' .
        asset_revision() . '"]')
    ->element_exists('script[src="/selecto-components/hx-ws.min.js?v=' .
        asset_revision() . '"]')
    ->element_exists('script[src="/selecto-components/selecto-components.js?v=' .
        asset_revision() . '"]')
    ->element_exists('form[data-template-event="search_changed"][hx-ws\\:send]')
    ->element_exists('form.selecto-template-source[data-selecto-template-source="orders"]' .
        '[hx-trigger="load"][hx-swap="outerHTML"]')
    ->element_exists_not('[data-order-number]');

my $initial_dom = $t->tx->res->dom;
my $root = $initial_dom->at('main.selecto-template-instance');
my $instance_id = $root->attr('data-selecto-template-instance');
like $instance_id, qr/\Ahttp-instance-\d+\z/, 'instance ID is opaque and server allocated';
unlike $t->tx->res->body, qr/selecto\.template\.compile-manifest/,
    'compiled manifest is not sent to the browser';
my $source_form = $initial_dom->at('form.selecto-template-source');
my $source_path = $source_form->attr('action');
my $source_csrf = $source_form->at('input[name="csrf_token"]')->attr('value');

$t->post_ok(
    $source_path => {'X-Test-Actor' => 'mallory', 'HX-Request' => 'true'} =>
        form => {csrf_token => $source_csrf},
)->status_is(404)
    ->element_exists('[data-selecto-template-error="template_not_found"]');
$t->post_ok(
    $source_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => {csrf_token => 'forged'},
)->status_is(403)
    ->element_exists('[data-selecto-template-error="invalid_csrf"]');
$t->post_ok(
    $source_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => {csrf_token => $source_csrf, query => 'select *'},
)->status_is(422)
    ->element_exists('[data-selecto-template-error="invalid_source_params"]');
my $held_claim = $store->claim_effect(
    owner_scope => {
        tenant_id => 7, actor_id => 'alice', session_id => 'session-http',
    },
    instance_id => $instance_id,
    source => 'orders', generation => 1,
    effect_id => "$instance_id:source:orders:1", lease_seconds => 10,
);
is $held_claim->{status}, 'claimed', 'test worker holds the initial source generation';
$t->post_ok(
    $source_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => {csrf_token => $source_csrf},
)->status_is(409)
    ->element_exists('[data-selecto-template-error="source_effect_busy"]');
is(
    $store->release_effect_claim(
        owner_scope => {
            tenant_id => 7, actor_id => 'alice', session_id => 'session-http',
        },
        instance_id => $instance_id,
        source => 'orders', generation => 1,
        effect_id => "$instance_id:source:orders:1",
        claim_token => $held_claim->{claim_token},
    )->{status},
    'ok',
    'test worker releases the held source generation',
);

$t->post_ok(
    $source_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => {csrf_token => $source_csrf},
)->status_is(200)
    ->header_is('X-Selecto-State-Revision' => 0)
    ->header_is('X-Selecto-Store-Revision' => 1)
    ->header_is('X-Selecto-Source' => 'orders')
    ->header_is('X-Selecto-Source-Generation' => 1)
    ->element_exists('main.selecto-template-instance')
    ->element_exists_not('html')
    ->element_exists('[data-order-number="PO-100"]')
    ->element_exists_not('form.selecto-template-source');
is $source_context_calls, 1,
    'request authority is reduced to source context for the initial generation';
my @worker_audit = _worker_audit($worker_audit_path);
is scalar(@worker_audit), 1, 'source authorization ran once for the initial generation';
unlike $worker_audit[0], qr/\A\Q$$\E:/,
    'source authorization and DB handle creation run outside the web process';
like $worker_audit[0], qr/:alice:orders:1\z/,
    'child authorization receives only the resolved actor and source effect data';

my $ready_dom = $t->tx->res->dom;
my $event_form = $ready_dom->at('form[data-template-event="search_changed"]');
my $event_path = $event_form->attr('action');
my %event_params = map {
    $_->attr('name') => $_->attr('value')
} $event_form->find('input[type="hidden"]')->each;
$event_params{value} = 'PO-200';

$t->post_ok(
    $event_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => \%event_params,
);
$t->status_is(200)
    ->header_is('X-Selecto-State-Revision' => 1)
    ->header_is('X-Selecto-Store-Revision' => 2)
    ->header_is('X-Selecto-Event-ID' => $event_params{event_id})
    ->element_exists('input[name="value"][value="PO-200"]')
    ->element_exists('form.selecto-template-source[data-selecto-template-source="orders"]')
    ->element_exists_not('[data-order-number]');
my $pending_source_form = $t->tx->res->dom->at('form.selecto-template-source');
my $pending_source_path = $pending_source_form->attr('action');
my $pending_source_csrf =
    $pending_source_form->at('input[name="csrf_token"]')->attr('value');

$t->post_ok(
    $event_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => \%event_params,
)->status_is(409)
    ->element_exists('[data-selecto-template-error="duplicate_event"]');
my %forged_event = (%event_params, tenant_id => 99, event_id => 'forged-event');
$t->post_ok(
    $event_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => \%forged_event,
)->status_is(422)
    ->element_exists('[data-selecto-template-error="invalid_event_params"]');
my %unsafe_event_id = (%event_params, event_id => "unsafe\nevent");
$t->post_ok(
    $event_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => \%unsafe_event_id,
)->status_is(422)
    ->element_exists('[data-selecto-template-error="invalid_event_params"]');

$t->post_ok(
    $pending_source_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => {csrf_token => $pending_source_csrf},
)->status_is(200)
    ->header_is('X-Selecto-State-Revision' => 1)
    ->header_is('X-Selecto-Store-Revision' => 3)
    ->header_is('X-Selecto-Source' => 'orders')
    ->header_is('X-Selecto-Source-Generation' => 2)
    ->element_exists('[data-order-number="PO-200"]');
is $source_context_calls, 2,
    'request authority is resolved again for a new source generation';
@worker_audit = _worker_audit($worker_audit_path);
is scalar(@worker_audit), 2, 'source authorization is reacquired in a fresh worker';
like $worker_audit[1], qr/:alice:orders:2\z/,
    'new generation reaches child authorization with its current effect data';

$t->get_ok('/templates/invalid_context' => {'X-Test-Actor' => 'alice'})
    ->status_is(200);
my $invalid_context_form = $t->tx->res->dom->at('form.selecto-template-source');
my $invalid_context_path = $invalid_context_form->attr('action');
my $invalid_context_csrf =
    $invalid_context_form->at('input[name="csrf_token"]')->attr('value');
for my $attempt (1 .. 2) {
    $t->post_ok(
        $invalid_context_path => {
            'X-Test-Actor' => 'alice', 'HX-Request' => 'true',
        } => form => {csrf_token => $invalid_context_csrf},
    )->status_is(503)
        ->element_exists('[data-selecto-template-error="invalid_source_job"]');
}
is scalar(_worker_audit($worker_audit_path)), 2,
    'invalid source context never reaches child authorization';

$t->get_ok('/templates/slow_orders' => {'X-Test-Actor' => 'alice'})
    ->status_is(200);
my $slow_form = $t->tx->res->dom->at('form.selecto-template-source');
my $slow_path = $slow_form->attr('action');
my $slow_csrf = $slow_form->at('input[name="csrf_token"]')->attr('value');
my (@completion_order, $slow_tx, $probe_tx);
my $slow_promise = $t->ua->post_p(
    $slow_path => {'X-Test-Actor' => 'alice', 'HX-Request' => 'true'} =>
        form => {csrf_token => $slow_csrf},
)->then(sub {
    ($slow_tx) = @_;
    push @completion_order, 'source';
});
my $probe_promise = $t->ua->get_p('/template-probe')->then(sub {
    ($probe_tx) = @_;
    push @completion_order, 'probe';
});
Mojo::Promise->all($slow_promise, $probe_promise)->wait;
is $probe_tx->res->code, 200, 'unrelated HTTP request completes during source work';
is $probe_tx->res->text, 'ready', 'unrelated route returns its normal response';
is_deeply \@completion_order, ['probe', 'source'],
    'slow DBI-shaped source work does not freeze the Mojolicious event loop';
is $slow_tx->res->code, 200, 'slow source request completes after the probe';
ok $slow_tx->res->dom->at('[data-order-number="PO-100"]'),
    'slow source result is committed and rendered';

$t->get_ok('/templates/orders' => {'X-Test-Actor' => 'alice'})->status_is(200);
my $ws_root = $t->tx->res->dom->at('main.selecto-template-instance');
my $ws_instance_id = $ws_root->attr('data-selecto-template-instance');
my $ws_form = $t->tx->res->dom->at('form[data-template-event="search_changed"]');
my %ws_event = map {
    $_->attr('name') => $_->attr('value')
} $ws_form->find('input[type="hidden"]')->each;
$ws_event{value} = 'PO-WS';
my $ws_path = "/template-instances/$ws_instance_id/ws";
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => encode_json({headers => {}, %ws_event})})
    ->message_ok;
my $ws_response = decode_json($t->message->[1]);
is $ws_response->{target}, '#' . $ws_root->attr('id'),
    'WebSocket event targets only the replaceable template root';
is $ws_response->{swap}, 'outerHTML', 'WebSocket event preserves the channel wrapper';
is $ws_response->{selecto}{state_revision}, 1,
    'WebSocket response carries the accepted state revision';
is $ws_response->{selecto}{event_id}, $ws_event{event_id},
    'WebSocket response identifies the accepted event';
like $ws_response->{content}, qr/value="PO-WS"/,
    'WebSocket response renders the accepted event state';
unlike $ws_response->{content}, qr/selecto-template-channel/,
    'WebSocket response does not replace its own connection element';

$t->send_ok({text => encode_json({headers => {}, %ws_event})})->message_ok;
my $ws_conflict = decode_json($t->message->[1]);
is $ws_conflict->{selecto}{status}, 409,
    'duplicate WebSocket event returns an explicit conflict envelope';
is $ws_conflict->{selecto}{code}, 'duplicate_event',
    'WebSocket conflict preserves the bounded reducer code';
$alice_revoked = 1;
$t->send_ok({text => encode_json({headers => {}, %ws_event})})
    ->finished_ok(1008);
$alice_revoked = 0;

$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => encode_json({headers => {}, %ws_event, csrf_token => 'forged'})})
    ->finished_ok(1008);
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => encode_json({headers => {}, %ws_event, query => 'select *'})})
    ->message_ok;
my $ws_invalid = decode_json($t->message->[1]);
is $ws_invalid->{selecto}{status}, 422,
    'forged WebSocket fields return a validation envelope';
is $ws_invalid->{selecto}{code}, 'invalid_event_params',
    'forged WebSocket fields never reach event dispatch';
$t->finish_ok;
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => encode_json({
        headers => {}, %ws_event, event_id => "unsafe\nevent",
    })})
    ->message_ok;
my $ws_unsafe_event_id = decode_json($t->message->[1]);
is $ws_unsafe_event_id->{selecto}{code}, 'invalid_event_params',
    'WebSocket event IDs exclude unsafe response-header characters';
$t->finish_ok;
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => '{invalid'})
    ->finished_ok(1003);
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => 'x' x 131_073})
    ->finished_ok(1009);
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'mallory'})
    ->finished_ok(1008);
$t->websocket_ok($ws_path => {
    'X-Test-Actor' => 'alice', Origin => 'https://evil.example',
})->finished_ok(1008);

$t->get_ok('/templates/orders' => {'X-Test-Actor' => 'alice'})->status_is(200);
my $expiring_dom = $t->tx->res->dom;
my $expiring_event = $expiring_dom->at('form[data-template-event="search_changed"]');
my %fallback_params = map {
    $_->attr('name') => $_->attr('value')
} $expiring_event->find('input[type="hidden"]')->each;
$fallback_params{value} = 'fallback';
$t->post_ok(
    $expiring_event->attr('action') => {'X-Test-Actor' => 'alice'} =>
        form => \%fallback_params,
)->status_is(200)
    ->element_exists('html')
    ->element_exists('script[src="/selecto-components/htmx.min.js?v=' .
        asset_revision() . '"]')
    ->element_exists('input[name="value"][value="fallback"]');
my $fallback_dom = $t->tx->res->dom;
my $expired_event = $fallback_dom->at('form[data-template-event="search_changed"]');
my %expired_params = map {
    $_->attr('name') => $_->attr('value')
} $expired_event->find('input[type="hidden"]')->each;
$expired_params{value} = 'late';
$now += 61;
$t->post_ok(
    $expired_event->attr('action') => {'X-Test-Actor' => 'alice'} =>
        form => \%expired_params,
)->status_is(410)
    ->element_exists('[data-selecto-template-error="template_expired"]');

done_testing;

sub _registry {
    return {
        components => {
            SearchInput => sub {
                my ($node) = @_;
                my $event = $node->{transport}{events}{change};
                my $fields = join '', map {
                    '<input type="hidden" name="' . html_escape($_) . '" value="' .
                        html_escape($event->{fields}{$_}) . '">'
                } sort keys %{$event->{fields}};
                return _safe('<form data-template-event="' .
                    html_escape($event->{fields}{event}) . '" method="post" action="' .
                    html_escape($event->{action}) . '" hx-ws:send>' . $fields .
                    '<input name="value" value="' .
                    html_escape($node->{props}{value}) . '"></form>');
            },
            OrderTable => sub {
                my ($node) = @_;
                my $rows = $node->{props}{rows} // [];
                return _safe(join '', map {
                    '<p data-order-number="' . html_escape($_->{order_number}) . '">' .
                        html_escape($_->{order_number}) . '</p>'
                } @$rows);
            },
        },
        elements => {},
        include => sub {
            my ($node) = @_;
            return _safe('<aside data-template-include="' .
                html_escape($node->{template}) . '"></aside>');
        },
    };
}

sub _safe {
    return Selecto::Components::Templates::Renderer->safe_html($_[0]);
}

sub _worker_audit {
    my ($path) = @_;
    open my $audit, '<', $path or die "worker audit unavailable\n";
    my @lines = <$audit>;
    close $audit;
    chomp @lines;
    return @lines;
}

package TemplateHTTPDBH;

sub new { return bless {}, $_[0] }
sub errstr { return undef }
