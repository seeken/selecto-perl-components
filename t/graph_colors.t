use 5.034;
use strict;
use warnings;
use Test::More;
use Mojo::DOM;
use Mojo::JSON qw(decode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::Graph::Colors;
use Selecto::Components::QueryAssistant::Store;
use Selecto::Components::QueryAssistant::Target;
use Selecto::Components::QueryBuilder;
use Selecto::Components::Renderer::Results;
use Selecto::Components::State;

my $store = Selecto::Components::QueryAssistant::Store->new;
my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'products',
    query_assistant => {
        store => $store,
        palettes => {brand => ['#112233', '#445566', '#778899']},
    },
);
my $domain = TestSelectoComponents::domain();

is(Selecto::Components::Graph::Colors->normalize_hex('#A1B2C3'), '#a1b2c3',
    'custom colors normalize to lowercase');
ok(!defined(Selecto::Components::Graph::Colors->normalize_hex('red;url(x)')),
    'arbitrary CSS is rejected');
is(Selecto::Components::Graph::Colors->resolve_series(
    palette => 'brand', palettes => {brand => ['#112233', '#445566']}, series_id => 'revenue',
), Selecto::Components::Graph::Colors->resolve_series(
    palette => 'brand', palettes => {brand => ['#112233', '#445566']}, series_id => 'revenue',
), 'automatic palette assignment is stable by series identity');

my $state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', chart_type => 'pie', field => 'product_name',
    group => 'category.category_name', measure => 'total_price', measure_function => 'sum',
    measure_series_id => 'revenue', measure_chart_type => 'auto', measure_axis => 'left',
    measure_color => '', measure_fill_opacity => '0.35', measure_ignore_nulls => 'auto',
    measure_transform => '', graph_palette => 'brand', graph_show_table => 1,
    graph_category_field => 'category.category_name', graph_category_value => 'Value 1',
    graph_category_format => '', graph_category_color => '#AA0000', limit => 100, page => 1,
});
ok $state->valid, 'palette, opacity, and category color produce valid ordinary state'
    or diag explain $state->errors;
is $state->graph_palette, 'brand', 'named palette survives normalization';
is $state->measure_config_list->[0]{fill_opacity}, 0.35, 'fill opacity survives normalization';
is_deeply $state->graph_category_colors, [{
    field => 'category.category_name', value => 'Value 1', format => '', color => '#aa0000',
}], 'category override is normalized as a field/value/format tuple';

my $target = Selecto::Components::QueryAssistant::Target->from_state($state);
is $target->{graph}{palette}, 'brand', 'assistant target reuses ordinary palette state';
is $target->{measures}[0]{fill_opacity}, 0.35, 'assistant target reuses ordinary opacity state';
is $target->{graph}{category_colors}[0]{color}, '#aa0000',
    'assistant target reuses ordinary category override state';

my $built = Selecto::Components::QueryBuilder->build($config, $domain, $state);
my ($dimension) = grep { !$_->{measure} } @{$built->{columns}};
my ($measure) = grep { $_->{measure} } @{$built->{columns}};
my $result = {
    %$built,
    records => [
        {$dimension->{key} => 'Value 1', $measure->{key} => 10},
        {$dimension->{key} => 'Value 2', $measure->{key} => 20},
    ],
    drilldowns => [[], []], total_count => 2, total_pages => 1,
};
my $html = Selecto::Components::Renderer::Results->_graph($result, {
    config => $config, domain => $domain, state => $state, result => $result,
});
my $chart = decode_json(Mojo::DOM->new($html)->at('[data-sc-chart]')->attr('data-chart-data'));
is $chart->{datasets}[0]{backgroundColor}[0], '#aa0000',
    'typed category override wins for the matching pie-style category slot';
is $chart->{datasets}[0]{fillOpacity}, 0.35,
    'renderer carries fill opacity into the chart dataset';
is $chart->{datasets}[0]{colorAuto}, 0,
    'a requested palette takes precedence over the host theme';

my %detail_input;
my $pairs = $state->query_pairs;
for (my $index = 0; $index < @$pairs; $index += 2) {
    my ($name, $value) = @$pairs[$index, $index + 1];
    if (exists $detail_input{$name}) {
        $detail_input{$name} = [$detail_input{$name}]
            unless ref($detail_input{$name}) eq 'ARRAY';
        push @{$detail_input{$name}}, $value;
    } else {
        $detail_input{$name} = $value;
    }
}
$detail_input{view} = 'detail';
my $inactive = Selecto::Components::State->from_input($config, $domain, \%detail_input);
ok $inactive->valid, 'switching away from Graph retains valid inactive graph state';
is $inactive->graph_palette, 'brand', 'inactive palette survives a view switch';
ok $inactive->graph_show_table, 'inactive raw-table preference survives a view switch';
is $inactive->measure_config_list->[0]{fill_opacity}, 0.35,
    'inactive series opacity survives a view switch';
is $inactive->measure_config_list->[0]{stack}, '',
    'empty inactive stack remains explicit';
is $inactive->graph_category_colors->[0]{color}, '#aa0000',
    'inactive category colors survive a view switch';

done_testing;
