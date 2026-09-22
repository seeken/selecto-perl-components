use 5.034;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use TestSelectoComponents ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Templates ();

my $customer_manifest = TestSelectoComponents::template_customer_manifest();
my $order_manifest = TestSelectoComponents::template_order_manifest();
my $registry = _registry();

my $mounted = Selecto::Templates->mount_runtime(
    $customer_manifest,
    instance_id => 'customer:7', release_id => 'release-1',
    inputs => {customer => {
        company_name => '<script>alert(1)</script>',
        address => {city => 'Salt & Lake', region => 'UT'},
    }},
);
my $html = Selecto::Components::Templates::Renderer->render(
    manifest => $customer_manifest,
    snapshot => $mounted->{snapshot},
    registry => $registry,
);
like $html, qr/id="selecto-template-customer-3A7-root-2Echildren-2E2"/,
    'renderer derives a stable DOM ID from server-owned instance and node identity';
like $html, qr/&lt;script&gt;alert\(1\)&lt;\/script&gt;/,
    'bound template text is HTML escaped';
like $html, qr/Salt &amp; Lake/, 'nested input text is HTML escaped';
unlike $html, qr/<script>/, 'bound input cannot become raw markup';
unlike $html, qr/No customer is assigned/, 'present input selects the then branch';

my $absent = Selecto::Templates->mount_runtime(
    $customer_manifest,
    instance_id => 'customer-empty', release_id => 'release-1', inputs => {},
);
my $empty_html = Selecto::Components::Templates::Renderer->render(
    manifest => $customer_manifest,
    snapshot => $absent->{snapshot},
    registry => $registry,
);
like $empty_html, qr/No customer is assigned/, 'absent optional input selects else';

my $orders = Selecto::Templates->mount_runtime(
    $order_manifest,
    instance_id => 'orders-1', release_id => 'release-1', inputs => {},
);
my $dispatched = Selecto::Templates->dispatch_runtime(
    $order_manifest,
    $orders->{snapshot},
    {
        schema => 'selecto.template.runtime-event.v1',
        instance_id => 'orders-1',
        release_id => 'release-1',
        event_id => 'select-1',
        name => 'order_selected',
        expected_state_revision => 0,
        payload => {value => 17},
    },
);
my $order_html = Selecto::Components::Templates::Renderer->render(
    manifest => $order_manifest,
    snapshot => $dispatched->{snapshot},
    registry => $registry,
);
like $order_html, qr{hx-post="/template-events/search_changed"},
    'component receives the declared event for htmx transport rendering';
like $order_html, qr/data-select-event="order_selected"/,
    'selection component receives its declared event';
like $order_html, qr/data-order-id="17"/,
    'include renderer receives the resolved typed binding';

my $missing_renderer;
eval {
    Selecto::Components::Templates::Renderer->render(
        manifest => $customer_manifest,
        snapshot => $absent->{snapshot},
        registry => {components => {}, elements => {}},
    );
    1;
} or $missing_renderer = $@;
like $missing_renderer, qr/\Aunavailable_renderer:/,
    'renderer fails closed when a host component is unavailable';

done_testing;

sub _registry {
    return {
        components => {
            Card => sub {
                my ($node) = @_;
                return _safe('<section id="' . html_escape($node->{dom_id}) .
                    '" class="' . html_escape($node->{props}{class}) . '">' .
                    $node->{children} . '</section>');
            },
            EmptyState => sub {
                my ($node) = @_;
                return _safe('<div id="' . html_escape($node->{dom_id}) .
                    '" class="selecto-template-empty">' . $node->{children} . '</div>');
            },
            SearchInput => sub {
                my ($node) = @_;
                my $event = html_escape($node->{events}{change});
                return _safe('<input id="' . html_escape($node->{dom_id}) .
                    '" name="value" value="' . html_escape($node->{props}{value}) .
                    '" hx-post="/template-events/' . $event . '" />');
            },
            OrderTable => sub {
                my ($node) = @_;
                my $rows = $node->{props}{rows} // [];
                return _safe('<div id="' . html_escape($node->{dom_id}) .
                    '" data-select-event="' . html_escape($node->{events}{select}) .
                    '" data-row-count="' . scalar(@$rows) . '"></div>');
            },
        },
        elements => {
            h2 => sub {
                my ($node) = @_;
                return _safe('<h2 id="' . html_escape($node->{dom_id}) . '">' .
                    $node->{children} . '</h2>');
            },
            p => sub {
                my ($node) = @_;
                return _safe('<p id="' . html_escape($node->{dom_id}) . '">' .
                    $node->{children} . '</p>');
            },
        },
        include => sub {
            my ($node) = @_;
            return _safe('<div id="' . html_escape($node->{dom_id}) .
                '" data-template="' . html_escape($node->{template}) .
                '" data-order-id="' . html_escape($node->{bindings}{order_id}) . '"></div>');
        },
    };
}

sub _safe {
    return Selecto::Components::Templates::Renderer->safe_html($_[0]);
}
