use 5.034;
use strict;
use warnings;

use Test::More;
use Selecto::Components::Graph::AxisPlanner ();

my $compatible = Selecto::Components::Graph::AxisPlanner->plan([
    {id => 'revenue', axis => 'auto', unit => {kind => 'currency', code => 'USD'}},
    {id => 'average', axis => 'auto', unit => {kind => 'currency', code => 'USD'}},
]);
is_deeply $compatible->{errors}, [], 'compatible measures share an axis without errors';
is_deeply [map { $_->{resolved_axis} } @{$compatible->{series}}],
    ['left', 'left'], 'compatible automatic measures share the left axis';

my $dual = Selecto::Components::Graph::AxisPlanner->plan([
    {id => 'revenue', axis => 'auto', unit => {kind => 'currency', code => 'USD'}},
    {id => 'volume', axis => 'right', unit => {kind => 'count'}},
]);
is_deeply $dual->{errors}, [], 'manual axis reservation is valid';
is_deeply [map { $_->{resolved_axis} } @{$dual->{series}}],
    ['left', 'right'], 'explicit axes are reserved before automatic assignment';

my $too_many = Selecto::Components::Graph::AxisPlanner->plan([
    {id => 'revenue', axis => 'auto', unit => {kind => 'currency', code => 'USD'}},
    {id => 'volume', axis => 'auto', unit => {kind => 'count'}},
    {id => 'miles', axis => 'auto', unit => {kind => 'distance', code => 'mile'}},
]);
like join(' ', @{$too_many->{errors}}), qr/at most two incompatible Y-axis units/,
    'a third incompatible unit requires normalization or removal';

my $conflict = Selecto::Components::Graph::AxisPlanner->plan([
    {id => 'revenue', axis => 'left', unit => {kind => 'currency', code => 'USD'}},
    {id => 'volume', axis => 'left', unit => {kind => 'count'}},
]);
like join(' ', @{$conflict->{errors}}), qr/Left graph axis.*incompatible units/,
    'manual placement cannot mix incompatible units on one axis';

done_testing;
