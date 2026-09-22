use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Mojolicious;
use Mojo::JSON qw(decode_json encode_json);
use Test::More;
use Test::Mojo;
use TestSelectoComponents ();
use Selecto::Components::Templates::InstanceStore::Memory ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

my $instance_sequence = 0;
my $event_sequence = 0;
my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
    id_generator => sub { 'native-helper-' . ++$instance_sequence },
    claim_token_generator => sub { 'native-claim-' . $instance_sequence },
);
my $manifest = TestSelectoComponents::template_order_manifest();
my $catalog = TestSelectoComponents::template_domain_catalog();
my $app = Mojolicious->new;
$app->secrets(['native-template-helper-secret']);
$app->renderer->classes([__PACKAGE__]);
$app->plugin('Selecto::Components::Templates' => {
    store => $store,
    websocket_heartbeat_interval => 0,
    event_id_generator => sub { 'native-event-' . ++$event_sequence },
    resolve_owner => sub {
        my ($controller) = @_;
        my $actor = $controller->req->headers->header('X-Test-Actor') // '';
        return {status => 'unauthenticated'} unless length($actor);
        return {status => 'ok', owner_scope => {actor => "$actor", tenant_id => 7}};
    },
    templates => {
        orders => {
            title => 'Orders',
            release_id => 'native-helper-orders-v1',
            manifest => $manifest,
            registry => {
                components => {
                    SearchInput => sub { _safe('') },
                    OrderTable => sub { _safe('') },
                },
                elements => {},
                include => sub { _safe('') },
            },
            resolve_source_context => sub {
                my ($controller, $owner, $effect) = @_;
                return {
                    actor => $owner->{actor}, tenant_id => $owner->{tenant_id},
                    source => $effect->{source},
                };
            },
            source_authorizer => sub {
                my ($context, $source, $effect) = @_;
                die "invalid native source context\n"
                    unless ($context->{actor} // '') eq 'alice'
                    && ($context->{tenant_id} // 0) == 7
                    && ($context->{source} // '') eq 'orders'
                    && ($source->{id} // '') eq 'orders'
                    && ($effect->{source} // '') eq 'orders';
                my $domain = Selecto::Domain->parse(
                    $catalog->{domains}{orders}, strict => 1,
                )->with_required_predicate(
                    Selecto::Expression->eq('tenant_id', $context->{tenant_id}),
                );
                my $engine = Selecto::Engine->new(
                    domain => $domain,
                    adapter => Selecto::PostgreSQL->new(dbh => NativeHelperDBH->new),
                );
                return {status => 'ok', engine => $engine, query => $engine->query};
            },
            source_runner => sub {
                my ($engine, $query, $effect) = @_;
                my $number = $effect->{bindings}{state}{search} || 'PO-100';
                return {rows => [[1, $number, '2026-09-22T12:00:00Z', 'open', 44]]};
            },
        },
    },
});

my $native_options = sub {
    return (
        instance_path => '/native-template-instances',
        target => '#native-orders',
    );
};
$app->routes->get('/native/orders')->to(cb => sub {
    my ($controller) = @_;
    my $model = $controller->selecto_template_model(
        template => 'orders', $native_options->(),
    );
    return _render_native($controller, $model);
});
$app->routes->post('/native-template-instances/:instance/events')->to(cb => sub {
    my ($controller) = @_;
    my $model = $controller->selecto_template_dispatch_event(
        instance => $controller->stash('instance'), $native_options->(),
    );
    return _render_native($controller, $model);
});
$app->routes->post('/native-template-instances/:instance/sources/:source')->to(cb => sub {
    my ($controller) = @_;
    my $scheduled = $controller->selecto_template_dispatch_source(
        instance => $controller->stash('instance'),
        source => $controller->stash('source'),
        $native_options->(),
        on_finish => sub {
            my ($model) = @_;
            return _render_native($controller, $model);
        },
    );
    return _render_native($controller, $scheduled)
        unless ($scheduled->{status} // '') eq 'scheduled';
    $controller->render_later;
    return undef;
});
$app->routes->websocket('/native-template-instances/:instance/ws')->to(cb => sub {
    my ($controller) = @_;
    return $controller->selecto_template_websocket(
        instance => $controller->stash('instance'),
        $native_options->(),
        render => sub {
            my ($model) = @_;
            return $controller->render_to_string(template => 'native', model => $model);
        },
        render_error => sub {
            my ($error) = @_;
            return '<section id="native-orders" role="alert">' .
                ($error->{code} // 'native_template_error') . '</section>';
        },
    );
});

my $t = Test::Mojo->new($app);
$t->get_ok('/native/orders' => {'X-Test-Actor' => 'alice'})
    ->status_is(200)
    ->element_exists('#native-orders[data-native-template="orders"]',
        'ordinary EP template owns the page markup')
    ->element_exists('form[data-native-source="orders"][hx-trigger="load"]',
        'native model supplies a bounded source form')
    ->element_exists('form[data-native-event="search_changed"]',
        'native model supplies a compiled event form')
    ->content_unlike(qr/selecto\.template\.compile-manifest/, 'manifest stays server-side')
    ->content_unlike(qr/tenant_id|owner_scope|adapter/, 'authority internals stay out of the model');

my $source_form = $t->tx->res->dom->at('form[data-native-source="orders"]');
my %source_params = _hidden_fields($source_form);
$t->post_ok($source_form->attr('action') => {
    'X-Test-Actor' => 'alice', 'HX-Request' => 'true',
} => form => \%source_params)
    ->status_is(200)
    ->element_exists('#native-orders[data-native-template="orders"]')
    ->element_exists('[data-native-order="PO-100"]',
        'custom EP markup renders projected source rows')
    ->element_exists('form[data-native-event="search_changed"]')
    ->element_exists_not('form[data-native-source="orders"]');

my $event_form = $t->tx->res->dom->at('form[data-native-event="search_changed"]');
my %event_params = (_hidden_fields($event_form), value => 'PO-200');
$t->post_ok($event_form->attr('action') => {'X-Test-Actor' => 'alice'} => form => \%event_params)
    ->status_is(200)
    ->element_exists('#native-orders[data-state-revision="1"]',
        'ordinary POST fallback renders the accepted revision')
    ->element_exists('input[name="value"][value="PO-200"]',
        'native EP sees reducer-owned state')
    ->element_exists('form[data-native-source="orders"]',
        'event reload exposes the next source form');

$source_form = $t->tx->res->dom->at('form[data-native-source="orders"]');
%source_params = _hidden_fields($source_form);
$t->post_ok($source_form->attr('action') => {
    'X-Test-Actor' => 'alice', 'HX-Request' => 'true',
} => form => \%source_params)
    ->status_is(200)
    ->element_exists('[data-native-order="PO-200"]',
        'custom source route completes the same template-owned query workflow')
    ->element_exists_not('html', 'HTMX path remains an EP-rendered fragment');

my $ws_form = $t->tx->res->dom->at('form[data-native-event="search_changed"]');
my %ws_event = (_hidden_fields($ws_form), value => 'PO-WS');
my $ws_path = $ws_form->attr('action');
$ws_path =~ s{/events\z}{/ws};
$t->websocket_ok($ws_path => {'X-Test-Actor' => 'alice'})
    ->send_ok({text => encode_json({
        headers => {}, %ws_event, value => 'x' x 16_385, form_revision => 7,
    })})
    ->message_ok;
my $ws_error = decode_json($t->message->[1]);
is $ws_error->{target}, '#native-orders',
    'native helper WebSocket errors target the host-owned EP root';
is $ws_error->{selecto}{code}, 'event_value_too_large',
    'native helper WebSocket preserves bounded validation metadata';
like $ws_error->{content}, qr/event_value_too_large/,
    'native helper WebSocket uses the host error renderer';
$t->send_ok({text => encode_json({headers => {}, %ws_event})})
    ->message_ok;
my $ws_response = decode_json($t->message->[1]);
is $ws_response->{target}, '#native-orders',
    'native helper WebSocket targets the host-owned EP root';
is $ws_response->{swap}, 'outerHTML',
    'native helper WebSocket preserves the host swap contract';
is $ws_response->{selecto}{state_revision}, 2,
    'native helper WebSocket carries the accepted state revision';
like $ws_response->{content}, qr/data-native-template="orders"/,
    'native helper WebSocket renders custom EP markup';
like $ws_response->{content}, qr/value="PO-WS"/,
    'custom EP receives reducer-owned WebSocket state';
unlike $ws_response->{content}, qr/selecto-template-instance/,
    'native WebSocket response does not fall back to the generic renderer';
$t->finish_ok;

$t->get_ok('/native/orders')
    ->status_is(401, 'native helper resolves owner authority before mounting');

done_testing;

sub _render_native {
    my ($controller, $model) = @_;
    unless (($model->{status} // '') eq 'ok') {
        my $status = ($model->{status} // '') eq 'unauthenticated' ? 401 : 422;
        return $controller->render(
            text => $model->{code} // 'native_template_error', status => $status,
        );
    }
    return $controller->render(template => 'native', model => $model);
}

sub _hidden_fields {
    my ($form) = @_;
    return map {
        $_->attr('name') => $_->attr('value')
    } $form->find('input[type="hidden"]')->each;
}

sub _safe {
    return Selecto::Components::Templates::Renderer->safe_html($_[0]);
}

package NativeHelperDBH;

sub new { return bless {}, $_[0] }
sub errstr { return undef }

package main;

__DATA__
@@ native.html.ep
% my $source = $model->{sources}{orders};
% my $event = $model->{forms}{events}[0];
<section id="<%= $model->{root_id} %>" data-native-template="<%= $model->{template}{id} %>" data-state-revision="<%= $model->{state_revision} %>" data-native-websocket="<%= $model->{transport}{websocket_path} %>">
  <h1>Orders in native EP</h1>
  <form data-native-event="<%= $event->{event} %>" data-selecto-template-event="<%= $event->{event} %>" method="<%= $event->{method} %>" action="<%= $event->{action} %>" hx-post="<%= $event->{hx_post} %>" hx-target="<%= $event->{hx_target} %>" hx-swap="<%= $event->{hx_swap} %>"<%== $event->{hx_ws_send} ? ' hx-ws:send' : '' %>>
% for my $name (sort keys %{$event->{fields}}) {
    <input type="hidden" name="<%= $name %>" value="<%= $event->{fields}{$name} %>">
% }
    <input name="<%= $event->{input_name} %>" value="<%= $model->{state}{search} %>">
    <button type="submit">Search</button>
  </form>
% if (my $form = $model->{forms}{sources}{orders}) {
  <form data-native-source="orders" method="<%= $form->{method} %>" action="<%= $form->{action} %>" hx-post="<%= $form->{hx_post} %>" hx-trigger="<%= $form->{hx_trigger} %>" hx-target="<%= $form->{hx_target} %>" hx-swap="<%= $form->{hx_swap} %>">
% for my $name (sort keys %{$form->{fields}}) {
    <input type="hidden" name="<%= $name %>" value="<%= $form->{fields}{$name} %>">
% }
    <noscript><button type="submit">Load orders</button></noscript>
  </form>
% }
% for my $row (@{$source->{rows} // []}) {
  <p data-native-order="<%= $row->{order_number} %>"><%= $row->{order_number} %></p>
% }
</section>
