use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::QueryLibrary;

my $domain = TestSelectoComponents::domain();

my $views = Selecto::Components::QueryLibrary->entries($domain, 'views');
is_deeply $views, [{
    id => 'low_stock_products',
    label => 'Low stock products',
    description => 'Reusable inventory review preset.',
    capability => '',
}], 'named-view entries retain presentation metadata without inventing missing values';

my $segments = Selecto::Components::QueryLibrary->entries($domain, 'segments');
is_deeply [map { $_->{label} } @$segments], ['Low stock', 'Premium products'],
    'named segments sort alphabetically by their display labels';

my $active = Selecto::Components::QueryLibrary->active_segment_entries(
    $domain, 'low_stock_products', [qw(low_stock premium)],
);
is_deeply [map { $_->{id} } @$active], [qw(low_stock premium)],
    'view-governed and additional segments are summarized once in stable order';

my $parameters = Selecto::Components::QueryLibrary->parameter_entries(
    $domain, 'low_stock_products', ['premium'],
);
is_deeply [map { $_->{label} } @$parameters], ['Minimum Price', 'Stock threshold'],
    'typed parameters sort by their humanized or explicit label';
is_deeply [map { $_->{type} } @$parameters], [qw(decimal integer)],
    'component parameter entries retain portable types';
is(Selecto::Components::QueryLibrary->input_type('decimal'), 'number',
    'numeric portable types use numeric controls');
is(Selecto::Components::QueryLibrary->input_type('application/status'), 'text',
    'application-specific types fall back to text controls');

done_testing;
