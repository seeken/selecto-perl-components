use 5.034;
use strict;
use warnings;
use utf8;

use FindBin ();
use JSON::PP ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Storable qw(dclone);
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
my $page_snapshot = dclone($dispatched->{snapshot});
$page_snapshot->{sources}{orders}{result} = {
    rows => [{id => 1}],
    pages => [{private_position => 'must-not-render'}],
    identities => [{row_keys => ['private-row-key']}],
};
my $page_html = Selecto::Components::Templates::Renderer->render(
    manifest => $order_manifest,
    snapshot => $page_snapshot,
    registry => $registry,
);
like $page_html, qr/data-row-count="1"/,
    'paged source envelope renders public rows';
unlike $page_html, qr/must-not-render/,
    'internal page position is not passed to the renderer';
unlike $page_html, qr/private-row-key/,
    'private row identities are not passed to the renderer';
$page_snapshot->{sources}{orders}{result} = {
    rows => [{id => 1}], totals => {order_count => 2},
    identities => [{row_keys => ['private-row-key']}],
};
my $total_html = Selecto::Components::Templates::Renderer->render(
    manifest => $order_manifest,
    snapshot => $page_snapshot,
    registry => $registry,
);
like $total_html, qr/data-row-count="1"/,
    'filtered-total source envelope still renders public rows';
unlike $total_html, qr/private-row-key/,
    'filtered-total envelope keeps private identities out of rendering';
like $order_html,
    qr/data-selecto-template-node="root\.children\.7"/,
    'top-level conditional keeps a stable fragment boundary';

my $regions = Selecto::Components::Templates::Renderer->render_regions(
    manifest => $order_manifest,
    snapshot => $dispatched->{snapshot},
    registry => $registry,
    node_ids => ['root.children.7'],
);
is scalar(@$regions), 1, 'renderer returns only requested server-owned regions';
is $regions->[0]{node_id}, 'root.children.7', 'fragment preserves its compiled node ID';
like $regions->[0]{target}, qr/\A#selecto-template-orders-2D1-.*-region\z/,
    'fragment target is derived from instance and compiled node identity';
like $regions->[0]{html}, qr/data-order-id="17"/,
    'fragment uses the same rendering pipeline as the full view';

my $unknown_region;
eval {
    Selecto::Components::Templates::Renderer->render_regions(
        manifest => $order_manifest,
        snapshot => $dispatched->{snapshot},
        registry => $registry,
        node_ids => ['client.chosen'],
    );
    1;
} or $unknown_region = $@;
like $unknown_region, qr/\Aunknown_render_region:/,
    'renderer rejects a region absent from the compiled top-level view';

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

my $region_path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-customer-region.compile.json";
open my $region_handle, '<:raw', $region_path or die "cannot read region manifest: $!";
my $region_manifest = JSON::PP->new->utf8->decode(do { local $/; <$region_handle> });
close $region_handle;
my $region_mounted = Selecto::Templates->mount_runtime(
    $region_manifest,
    instance_id => 'region-orders', release_id => 'region-v1', inputs => {},
);
my $region_snapshot = dclone($region_mounted->{snapshot});
$region_snapshot->{sources}{orders}{result} = [
    {id => 1, customer => {region => {name => 'West & North'}}},
    {id => 2, customer => undef},
    {id => 3, customer => {region => undef}},
];
my $region_registry = {
    components => {}, elements => {},
    include => sub {
        my ($node) = @_;
        my $customer = $node->{bindings}{customer};
        my $region = ref($customer) eq 'HASH' ? $customer->{region} : undef;
        my $name = ref($region) eq 'HASH' ? $region->{name} : undef;
        return _safe('<article id="' . html_escape($node->{dom_id}) .
            '" data-region-card="' . html_escape($node->{template}) .
            '" data-customer-presence="' .
            (ref($customer) eq 'HASH' ? 'present' : 'absent') . '">' .
            html_escape($name // '') . '</article>');
    },
};
my $region_html = Selecto::Components::Templates::Renderer->render(
    manifest => $region_manifest, snapshot => $region_snapshot,
    registry => $region_registry,
);
is scalar(() = $region_html =~ /data-region-card=/g), 3,
    'source-bound include renders once per public row';
like $region_html, qr/West &amp; North/,
    'repeated include output escapes nested relationship text';
like $region_html, qr/data-customer-presence="absent"/,
    'repeated include passes an absent optional relationship';
like $region_html,
    qr/id="selecto-template-region-2Dorders-root-2Echildren-2E1-2Erow-2E0"/,
    'repeated include uses a row-specific DOM identity';
unlike $region_html, qr/West & North/,
    'repeated include never emits unescaped relationship text';

my $root_manifest = dclone($region_manifest);
$root_manifest->{view}{nodes}[0]{bindings} = {
    orders => {kind => 'binding', type => 'source', expression => 'orders'},
};
$root_manifest->{view}{nodes}[0]{template} = 'order_totals_badge';
my $root_snapshot = dclone($region_snapshot);
$root_snapshot->{sources}{orders}{result} = [
    {id => 1, order_number => 'PO<&>'},
    {id => 2, order_number => 'PO-2'},
];
my $root_html = Selecto::Components::Templates::Renderer->render(
    manifest => $root_manifest, snapshot => $root_snapshot,
    registry => {include => sub {
        my ($node) = @_;
        return _safe('<article id="' . html_escape($node->{dom_id}) .
            '" data-root-order="' . html_escape($node->{template}) . '">' .
            html_escape($node->{bindings}{orders}{order_number}) . '</article>');
    }},
);
is scalar(() = $root_html =~ /data-root-order=/g), 2,
    'root-source include renders once per public source row';
like $root_html, qr/PO&lt;&amp;&gt;/,
    'root-source include escapes each row before rendering';
unlike $root_html, qr/PO<&>/,
    'root-source include cannot emit raw row markup';

my $child_path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/customer-region-card.valid.selecto";
open my $child_handle, '<:raw', $child_path or die "cannot read customer card: $!";
my $child_source = do { local $/; <$child_handle> };
close $child_handle;
my $caps_path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/capabilities.json";
open my $caps_handle, '<:raw', $caps_path or die "cannot read template capabilities: $!";
my $capabilities = JSON::PP->new->utf8->decode(do { local $/; <$caps_handle> });
close $caps_handle;
my $child_manifest = Selecto::Templates->compile(
    Selecto::Templates->parse($child_source),
    domains => {}, capabilities => $capabilities,
);
my $recursive_registry = {
    include => sub {
        my ($node) = @_;
        my $child_snapshot = {
            instance_id => $node->{dom_id}, inputs => $node->{bindings},
            state => {}, sources => {},
        };
        my $nested = Selecto::Components::Templates::Renderer->render(
            manifest => $child_manifest, snapshot => $child_snapshot,
            registry => {include => sub {
                my ($leaf) = @_;
                my $region = $leaf->{bindings}{region};
                my $name = ref($region) eq 'HASH' ? $region->{name} : undef;
                return _safe('<span id="' . html_escape($leaf->{dom_id}) .
                    '" data-region-leaf="' . html_escape($leaf->{template}) .
                    '">' . html_escape($name // '') . '</span>');
            }},
        );
        return _safe($nested);
    },
};
my $recursive_html = Selecto::Components::Templates::Renderer->render(
    manifest => $region_manifest, snapshot => $region_snapshot,
    registry => $recursive_registry,
);
is scalar(() = $recursive_html =~ /data-region-leaf=/g), 3,
    'nested included template renders once per source row';
like $recursive_html, qr/West &amp; North/,
    'nested included template receives the selected region data';

my $invalid_region = dclone($region_snapshot);
$invalid_region->{sources}{orders}{result}[0]{customer} = 7;
my $region_error;
eval {
    Selecto::Components::Templates::Renderer->render(
        manifest => $region_manifest, snapshot => $invalid_region,
        registry => $region_registry,
    );
    1;
} or $region_error = $@;
like $region_error, qr/\Arender_type_mismatch:/,
    'source-bound include rejects a non-object relationship';

my $reset_path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-state-reset.compile.json";
open my $reset_handle, '<:raw', $reset_path or die "cannot read reset manifest: $!";
my $reset_manifest = JSON::PP->new->utf8->decode(do { local $/; <$reset_handle> });
my $reset_mount = Selecto::Templates->mount_runtime(
    $reset_manifest, instance_id => 'count-view', release_id => 'release-1', inputs => {},
);
my $reset_registry = _registry();
$reset_registry->{components}{RootPager} = sub {
    my ($node) = @_;
    my $total = defined($node->{props}{total}) ? $node->{props}{total} : 'pending';
    return _safe('<span data-count="' . html_escape($total) .
        '" data-page-size="' . html_escape($node->{props}{page_size}) . '"></span>');
};
my $loading_count = Selecto::Components::Templates::Renderer->render(
    manifest => $reset_manifest, snapshot => $reset_mount->{snapshot},
    registry => $reset_registry,
);
like $loading_count, qr/data-count="pending"/,
    'unloaded declared count reaches the component as absent';
like $loading_count, qr/data-page-size="2"/,
    'compiled source page size reaches the component before source loading';
my $ready_count = dclone($reset_mount->{snapshot});
$ready_count->{sources}{orders}{status} = 'ready';
$ready_count->{sources}{orders}{result} = {rows => [], totals => {order_count => 3}};
my $rendered_count = Selecto::Components::Templates::Renderer->render(
    manifest => $reset_manifest, snapshot => $ready_count,
    registry => $reset_registry,
);
like $rendered_count, qr/data-count="3"/,
    'declared filtered count reaches the portable component';
my $missing_count = dclone($ready_count);
$missing_count->{sources}{orders}{result}{totals} = {};
my $missing_count_error;
eval {
    Selecto::Components::Templates::Renderer->render(
        manifest => $reset_manifest, snapshot => $missing_count,
        registry => $reset_registry,
    );
    1;
} or $missing_count_error = $@;
like $missing_count_error, qr/\Aunsupported_expression:/,
    'ready source missing a declared total fails closed';

my $ready_manifest = _slot_fixture(
    "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/source-ready.compile.json"
);
my $ready_mount = Selecto::Templates->mount_runtime(
    $ready_manifest, instance_id => 'source-ready',
    release_id => 'release-1', inputs => {},
);
my $pending_html = Selecto::Components::Templates::Renderer->render(
    manifest => $ready_manifest, snapshot => $ready_mount->{snapshot},
    registry => _registry(),
);
like $pending_html, qr/Source is pending\./,
    'unloaded source selects the pending branch';
my $failed_ready = dclone($ready_mount->{snapshot});
$failed_ready->{sources}{orders}{status} = 'error';
$failed_ready->{sources}{orders}{result} = {rows => [{id => 7}]};
my $failed_html = Selecto::Components::Templates::Renderer->render(
    manifest => $ready_manifest, snapshot => $failed_ready,
    registry => _registry(),
);
like $failed_html, qr/Source is pending\./,
    'failed source cannot show the ready branch even with stale rows';
$failed_ready->{sources}{orders}{status} = 'ready';
my $completed_html = Selecto::Components::Templates::Renderer->render(
    manifest => $ready_manifest, snapshot => $failed_ready,
    registry => _registry(),
);
like $completed_html, qr/Source is ready\./,
    'successful source completion selects the ready branch';
unlike $completed_html, qr/Source is pending\./,
    'successful source completion removes the pending branch';

my $slot_fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $slot_parent = _slot_fixture("$slot_fixtures/slot-page.compile.json");
my $slot_child = _slot_fixture("$slot_fixtures/slot-card.compile.json");
my $slot_mounted = Selecto::Templates->mount_runtime(
    $slot_parent, instance_id => 'slot-parent', release_id => 'slot-release',
    inputs => {title => '<script>unsafe</script>'},
);
my $slot_registry = _registry();
$slot_registry->{include} = sub {
    my ($node) = @_;
    my $child_html = Selecto::Components::Templates::Renderer->render(
        manifest => $slot_child,
        snapshot => {
            instance_id => $node->{dom_id}, inputs => {}, state => {}, sources => {},
        },
        registry => _registry(), slots => $node->{slots},
    );
    return _safe($child_html);
};
my $slot_html = Selecto::Components::Templates::Renderer->render(
    manifest => $slot_parent, snapshot => $slot_mounted->{snapshot},
    registry => $slot_registry,
);
like $slot_html, qr/&lt;script&gt;unsafe&lt;\/script&gt;/,
    'caller slot binding is escaped in its parent context';
like $slot_html, qr/Caller body/, 'caller body replaces the child slot';
unlike $slot_html, qr/Default heading|Default body/,
    'filled slots do not render their fallback';
unlike $slot_html, qr/<script>/, 'slot cannot inject raw markup';

my $fallback_html = Selecto::Components::Templates::Renderer->render(
    manifest => $slot_child,
    snapshot => {instance_id => 'slot-child', inputs => {}, state => {}, sources => {}},
    registry => _registry(),
);
like $fallback_html, qr/Default heading/, 'unfilled heading renders its fallback';
like $fallback_html, qr/Default body/, 'unfilled body renders its fallback';

my $invalid_slot_error;
eval {
    Selecto::Components::Templates::Renderer->render(
        manifest => $slot_child,
        snapshot => {instance_id => 'slot-child', inputs => {}, state => {}, sources => {}},
        registry => _registry(), slots => {heading => '<script>raw</script>'},
    );
    1;
} or $invalid_slot_error = $@;
like "$invalid_slot_error", qr/invalid_render_input/,
    'renderer rejects an untrusted slot string';

my $slot_capabilities = _slot_fixture("$slot_fixtures/capabilities.json");
my $middle_source = <<'SELECTO';
<template name="slot_middle" version="1">
  <include template="slot_card">
    <fill name="heading"><slot name="heading"><h2>Middle heading</h2></slot></fill>
  </include>
</template>
SELECTO
my $outer_source = <<'SELECTO';
<template name="slot_outer" version="1">
  <include template="slot_middle">
    <fill name="heading"><h2>Caller heading</h2></fill>
  </include>
</template>
SELECTO
my $middle_manifest = Selecto::Templates->compile(
    Selecto::Templates->parse($middle_source),
    domains => {}, capabilities => $slot_capabilities,
);
my $outer_manifest = Selecto::Templates->compile(
    Selecto::Templates->parse($outer_source),
    domains => {}, capabilities => $slot_capabilities,
);
my $card_include = sub {
    my ($node) = @_;
    return _safe(Selecto::Components::Templates::Renderer->render(
        manifest => $slot_child,
        snapshot => {instance_id => $node->{dom_id}, inputs => {}, state => {}, sources => {}},
        registry => _registry(), slots => $node->{slots},
    ));
};
my $middle_include = sub {
    my ($node) = @_;
    my $middle_registry = _registry();
    $middle_registry->{include} = $card_include;
    return _safe(Selecto::Components::Templates::Renderer->render(
        manifest => $middle_manifest,
        snapshot => {instance_id => $node->{dom_id}, inputs => {}, state => {}, sources => {}},
        registry => $middle_registry, slots => $node->{slots},
    ));
};
my $outer_registry = _registry();
$outer_registry->{include} = $middle_include;
my $forwarded_html = Selecto::Components::Templates::Renderer->render(
    manifest => $outer_manifest,
    snapshot => {instance_id => 'slot-outer', inputs => {}, state => {}, sources => {}},
    registry => $outer_registry,
);
like $forwarded_html, qr/Caller heading/, 'filled slot forwards through two included views';
like $forwarded_html, qr/Default body/, 'unfilled sibling slot keeps its fallback';
unlike $forwarded_html, qr/Middle heading|Default heading/,
    'forwarded fill replaces intermediate and final fallbacks';

my $safe_link_path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/render-safe-link.valid.selecto";
open my $safe_link_handle, '<:raw', $safe_link_path
    or die "cannot read safe link template: $!";
my $safe_link_source = do { local $/; <$safe_link_handle> };
close $safe_link_handle;
my $safe_link_capabilities = dclone($capabilities);
$safe_link_capabilities->{renderer}{elements}{a} = {
    attributes => {href => 'string'}, children => JSON::PP::true,
};
my $safe_link_manifest = Selecto::Templates->compile(
    Selecto::Templates->parse($safe_link_source),
    domains => {}, capabilities => $safe_link_capabilities,
);
my $safe_link_called = 0;
my $safe_link_registry = {elements => {a => sub {
    my ($node) = @_;
    $safe_link_called++;
    return _safe('<a href="' . html_escape($node->{attributes}{href}) . '">' .
        $node->{children} . '</a>');
}}};
my $safe_link_mounted = Selecto::Templates->mount_runtime(
    $safe_link_manifest,
    instance_id => 'safe-link', release_id => 'release-1',
    inputs => {target => '/orders/42?tab=a&next=b'},
);
my $safe_link_html = Selecto::Components::Templates::Renderer->render(
    manifest => $safe_link_manifest,
    snapshot => $safe_link_mounted->{snapshot},
    registry => $safe_link_registry,
);
like $safe_link_html, qr/href="\/orders\/42\?tab=a&amp;next=b"/,
    'text-declared safe URL reaches the registered renderer with HTML escaping';
is $safe_link_called, 1, 'safe text-declared link calls its host renderer';
my $unsafe_link_mounted = Selecto::Templates->mount_runtime(
    $safe_link_manifest,
    instance_id => 'unsafe-link', release_id => 'release-1',
    inputs => {target => 'javascript:alert(1)'},
);
my $unsafe_link_error;
eval {
    Selecto::Components::Templates::Renderer->render(
        manifest => $safe_link_manifest,
        snapshot => $unsafe_link_mounted->{snapshot},
        registry => $safe_link_registry,
    );
    1;
} or $unsafe_link_error = $@;
like $unsafe_link_error, qr/\Ainvalid_url_attribute:/,
    'text-declared unsafe URL is rejected';
is $safe_link_called, 1, 'unsafe text-declared link never calls its host renderer';

my $component_link_path = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/render-link-component.valid.selecto";
open my $component_link_handle, '<:raw', $component_link_path
    or die "cannot read link component template: $!";
my $component_link_source = do { local $/; <$component_link_handle> };
close $component_link_handle;
my $component_link_capabilities = dclone($capabilities);
$component_link_capabilities->{renderer}{components}{Link} = {
    props => {destination => 'string'}, required_props => ['destination'],
    events => {}, children => JSON::PP::true,
};
my $component_link_manifest = Selecto::Templates->compile(
    Selecto::Templates->parse($component_link_source),
    domains => {}, capabilities => $component_link_capabilities,
);
my $component_link_called = 0;
my $component_link_registry = {
    components => {Link => sub {
        my ($node) = @_;
        $component_link_called++;
        return _safe('<a href="' . html_escape($node->{props}{destination}) . '">' .
            $node->{children} . '</a>');
    }},
    url_props => {Link => {destination => 'href'}},
};
my $component_link_mounted = Selecto::Templates->mount_runtime(
    $component_link_manifest,
    instance_id => 'component-link', release_id => 'release-1',
    inputs => {target => '/orders/42?tab=a&next=b'},
);
my $component_link_html = Selecto::Components::Templates::Renderer->render(
    manifest => $component_link_manifest,
    snapshot => $component_link_mounted->{snapshot},
    registry => $component_link_registry,
);
like $component_link_html, qr/href="\/orders\/42\?tab=a&amp;next=b"/,
    'text-declared component URL is escaped';
is $component_link_called, 1, 'safe component URL calls native renderer';
my $unsafe_component_link = Selecto::Templates->mount_runtime(
    $component_link_manifest,
    instance_id => 'unsafe-component-link', release_id => 'release-1',
    inputs => {target => 'javascript:alert(1)'},
);
my $component_link_error;
eval {
    Selecto::Components::Templates::Renderer->render(
        manifest => $component_link_manifest,
        snapshot => $unsafe_component_link->{snapshot},
        registry => $component_link_registry,
    );
    1;
} or $component_link_error = $@;
like $component_link_error, qr/\Ainvalid_url_attribute:/,
    'unsafe component URL is rejected before native rendering';
is $component_link_called, 1, 'unsafe component URL never calls native renderer';

my $url_cases = TestSelectoComponents::template_render_url_fixture();
is $url_cases->{schema}, 'selecto.template.render-url-cases.v1',
    'shared render URL cases use the expected schema';
for my $case (@{$url_cases->{cases}}) {
    my $attribute = $case->{attribute};
    my $value = exists($case->{repeat})
        ? $case->{prefix} . ($case->{value} x $case->{repeat})
        : $case->{value};
    my $called = 0;
    my $manifest = {
        sources => [],
        view => {
            schema => 'selecto.template.view.v1',
            nodes => [{
                kind => 'element', node_id => 'root.children.0', name => 'a',
                attributes => {$attribute => {
                    kind => 'binding', type => 'string', expression => 'state.url',
                }},
                children => [],
            }],
        },
    };
    my $registry = {
        elements => {a => sub {
            my ($node) = @_;
            $called++;
            return _safe('<a ' . html_escape($attribute) . '="' .
                html_escape($node->{attributes}{$attribute}) . '"></a>');
        }},
    };
    my ($rendered, $error);
    eval {
        $rendered = Selecto::Components::Templates::Renderer->render(
            manifest => $manifest,
            snapshot => {
                instance_id => 'url-case', inputs => {},
                state => {url => $value}, sources => {},
            },
            registry => $registry,
        );
        1;
    } or $error = $@;

    if ($case->{valid}) {
        ok !$error && $rendered =~ /<a /, "$case->{name}: safe URL renders";
        is $called, 1, "$case->{name}: host renderer is called";
    } else {
        like $error, qr/\Ainvalid_url_attribute:/,
            "$case->{name}: unsafe URL is rejected";
        is $called, 0, "$case->{name}: host renderer is not called";
    }
}

done_testing;

sub _slot_fixture {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return JSON::PP->new->utf8(1)->decode(<$handle>);
}

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
