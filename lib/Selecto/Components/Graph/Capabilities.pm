package Selecto::Components::Graph::Capabilities;

use 5.034;
use strict;
use warnings;

use Selecto::Analytics::TransformRegistry ();
use Selecto::Components::Graph::Colors ();

my @TRANSFORMS = qw(percent_of_total percent_change index_to_first cumulative moving_average);

sub for_config {
    my ($class, $config, $domain) = @_;
    my $maximum = 0 + $config->max_limit;
    my $minimum = $maximum < 250 ? $maximum : 250;
    my $default = $maximum < 500 ? $maximum : 500;
    my $assistant = $config->query_assistant // {};
    my $palettes = Selecto::Components::Graph::Colors->palettes($assistant->{palettes});
    return {
        chart_types => [qw(bar horizontal_bar stacked_bar line area pie doughnut scatter)],
        mixed_series_global_types => [qw(bar line area)],
        series_types => [qw(auto bar line area)],
        axes => [qw(auto left right)],
        maximum_incompatible_y_units => 2,
        named_stacks => {pattern => '^[a-z][a-z0-9_]{0,31}$', compatible_units_and_axis => 1},
        null_handling => [qw(auto sql zero)],
        show_raw_table => 1,
        point_limit => {minimum => $minimum, default => $default, maximum => $maximum, page => 1},
        transform_scope => 'displayed_points',
        transforms => [map {
            my $definition = Selecto::Analytics::TransformRegistry->definition($_);
            $definition ? $definition : ()
        } @TRANSFORMS],
        colors => {
            format => '#RRGGBB', normalized_case => 'lowercase', auto_reset => 1,
            palettes => [map { +{id => $_, colors => [@{$palettes->{$_}}]} } sort keys %$palettes],
            fill_opacity => {minimum => 0, maximum => 1},
        },
    };
}

1;
