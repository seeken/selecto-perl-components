use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use TestSelectoComponents ();
use Selecto::Components::Templates::Regions ();

my $manifest = TestSelectoComponents::template_order_manifest();

is_deeply(
    Selecto::Components::Templates::Regions->for_event(
        $manifest, 'search_changed',
    ),
    ['root.children.5', 'root.children.6'],
    'search event updates only state- and source-dependent top-level regions',
);

is_deeply(
    Selecto::Components::Templates::Regions->for_event(
        $manifest, 'order_selected',
    ),
    ['root.children.5', 'root.children.6', 'root.children.7'],
    'selection event refreshes every form revision and its conditional include region',
);

is_deeply(
    Selecto::Components::Templates::Regions->for_source($manifest, 'orders'),
    ['root.children.5', 'root.children.6'],
    'source completion updates its data region and every event-form lifetime',
);

my $included = TestSelectoComponents::template_order_manifest();
push @{$included->{view}{nodes}}, {
    node_id => 'root.children.8', kind => 'include',
    template => 'customer_compact',
    bindings => {customer => {
        kind => 'binding', type => 'source', expression => 'orders.customer',
    }},
};
is_deeply(
    Selecto::Components::Templates::Regions->for_source($included, 'orders'),
    ['root.children.5', 'root.children.6', 'root.children.8'],
    'source completion refreshes a relationship include as well as row components',
);

push @{$included->{view}{nodes}}, {
    node_id => 'root.children.9', kind => 'include',
    template => 'order_quantity',
    bindings => {order => {
        kind => 'binding', type => 'source', expression => 'orders',
    }},
};
is_deeply(
    Selecto::Components::Templates::Regions->for_source($included, 'orders'),
    ['root.children.5', 'root.children.6', 'root.children.8', 'root.children.9'],
    'source completion refreshes a root-source include',
);

is_deeply(
    Selecto::Components::Templates::Regions->for_event($manifest, 'unknown'),
    [],
    'unknown event has no client-selected fallback regions',
);

done_testing;
