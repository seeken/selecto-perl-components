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
    ['root.children.7'],
    'selection event updates its conditional include region',
);

is_deeply(
    Selecto::Components::Templates::Regions->for_source($manifest, 'orders'),
    ['root.children.6'],
    'source completion updates only the region bound to its rows',
);

is_deeply(
    Selecto::Components::Templates::Regions->for_event($manifest, 'unknown'),
    [],
    'unknown event has no client-selected fallback regions',
);

done_testing;
