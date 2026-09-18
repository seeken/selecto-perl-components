use 5.034;
use strict;
use warnings;
use Test::More;
use Mojo::DOM;
use Mojo::JSON qw(decode_json encode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::QueryAssistant::Store;
use Selecto::Components::QueryBuilder;
use Selecto::Components::Renderer;
use Selecto::Components::State;

my $domain = TestSelectoComponents::domain();
my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'products', lazy_view_controls => 1,
    query_assistant => {
        store => Selecto::Components::QueryAssistant::Store->new,
        palettes => {brand => ['#112233', '#445566', '#778899']},
    },
);
my $state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'graph', chart_type => 'area', field => 'product_name',
    group => ['category.category_name', 'product_name'],
    graph_series_group => 'product_name', graph_palette => 'brand',
    measure => 'total_price', measure_function => 'sum',
    measure_series_id => 'revenue', measure_fill_opacity => '0.35',
});
ok $state->valid, 'breakout graphs accept an assistant palette and series opacity'
    or diag explain $state->errors;
my $built = Selecto::Components::QueryBuilder->build($config, $domain, $state);
my ($category) = grep { ($_->{field} // '') eq 'category.category_name' } @{$built->{columns}};
my ($product) = grep { ($_->{field} // '') eq 'product_name' } @{$built->{columns}};
my ($measure) = grep { $_->{measure} } @{$built->{columns}};
my $result = {
    %$built, records => [
        {$category->{key} => 'Food', $product->{key} => 'Chai', $measure->{key} => 10},
        {$category->{key} => 'Food', $product->{key} => 'Chang', $measure->{key} => 20},
        {$category->{key} => 'Drink', $product->{key} => 'Chang', $measure->{key} => 30},
    ], drilldowns => [[], [], []], graph_axis_drilldowns => [[], [], []],
};
my $model = {
    config => $config, domain => $domain, state => $state,
    canonical_url => '/explore/products?q=1', loaded_saved_query => {id => 7},
    csrf_token => 'renderer-token',
};
my $html = Selecto::Components::Renderer::Results->_graph($result, $model);
my $chart = decode_json(Mojo::DOM->new($html)->at('[data-sc-chart]')->attr('data-chart-data'));
is_deeply $chart->{labels}, ['Food', 'Drink'], 'breakout values stay separate from axis labels';
is_deeply $chart->{datasets}[0]{data}, [10, undef], 'a missing breakout point remains a gap';
is_deeply $chart->{datasets}[1]{data}, [20, 30], 'the second breakout retains its aligned values';
is_deeply $chart->{datasets}[0]{drilldownIndices}, [0, undef],
    'sparse breakout point drilldowns keep original record indices';
is_deeply $chart->{axisDrilldownIndices}, [3, 4],
    'axis drilldowns remain independent of the selected breakout';
is $chart->{datasets}[0]{fillOpacity}, 0.35, 'breakout series retain the requested fill opacity';
ok !grep({ $_->{colorAuto} } @{$chart->{datasets}}), 'a named palette takes priority over the host theme';
my %colors = map { $_->{label} => $_->{borderColor} } @{$chart->{datasets}};
my %reordered = (%$result, records => [reverse @{$result->{records}}]);
my $reordered_html = Selecto::Components::Renderer::Results->_graph(\%reordered, $model);
my $reordered_chart = decode_json(Mojo::DOM->new($reordered_html)->at('[data-sc-chart]')->attr('data-chart-data'));
is_deeply {map { $_->{label} => $_->{borderColor} } @{$reordered_chart->{datasets}}}, \%colors,
    'breakout palette colors stay attached to values when result order changes';
unlike $html, qr/\sstyle=|<style/, 'assistant graph rendering retains strict CSP markup';

my $surface = Mojo::DOM->new(Selecto::Components::Renderer->surface($model));
ok $surface->at('input[name="saved_query_id"][value="7"]'),
    'assistant-enabled builders retain the loaded saved-query identity';
ok $surface->at('[data-sc-query-assistant-status]'), 'assistant status renders beside ordinary query controls';
ok $surface->at('[data-sc-result-view-panel="detail"][data-sc-view-lazy]'),
    'the inactive detail panel retains lazy loading';
ok $surface->at('[data-sc-graph-options] select[name="graph_series_group"] option[value="product_name"][selected]'),
    'the graph picker retains the selected breakout field';
ok $surface->at('[data-sc-graph-options] select[name="graph_palette"] option[value="brand"][selected]'),
    'the same graph picker exposes the selected assistant palette';
ok !$surface->at('[data-sc-inactive-graph-state]'),
    'an active graph submits one set of graph controls';

my $membership = ['North,West', 'South'];
my $filter_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => 'product_name',
    filter_field => ['unit_price', 'product_name'], filter_op => ['gte', 'in'],
    filter_value => ['5', ''], filter_values_json => ['', encode_json($membership)],
    filter_promote_index => 2, graph_palette => 'brand', graph_show_table => 1,
});
ok $filter_state->valid, 'exact membership values are valid beside an ordinary scalar filter'
    or diag explain $filter_state->errors;
my $filter_model = {%$model, state => $filter_state};
my $filter_html = Selecto::Components::Renderer->surface($filter_model);
my $filter_dom = Mojo::DOM->new($filter_html);
my $json_input = $filter_dom->at('[data-sc-filter-set-item][data-field="product_name"] textarea[name="filter_values_json"]');
ok $json_input, 'exact membership remains editable in the ordinary Filters tab';
is_deeply decode_json($json_input->text), $membership,
    'a comma inside one membership value survives rendering';
my $promoted_json = $filter_dom->at('[data-sc-promoted-filter] textarea[data-sc-promoted-filter-input="values_json"]');
ok $promoted_json, 'the promoted editor keeps an exact JSON membership control';
is_deeply decode_json($promoted_json->text), $membership,
    'the promoted editor preserves the same exact values';
is $filter_dom->find('[data-sc-builder] [name="filter_values_json"]')->size,
    $filter_dom->find('[data-sc-builder] [name="filter_field"]')->size,
    'scalar and exact filters keep their positional form fields aligned';
ok $filter_dom->at('[data-sc-inactive-graph-state] input[name="graph_palette"][value="brand"]'),
    'a lazy detail view carries the inactive graph palette';
ok $filter_dom->at('[data-sc-inactive-graph-state] input[name="graph_show_table"][value="1"]'),
    'a lazy detail view carries the inactive graph-table preference';
unlike $filter_html, qr/\sstyle=|<style/, 'assistant controls retain strict CSP markup';

done_testing;
