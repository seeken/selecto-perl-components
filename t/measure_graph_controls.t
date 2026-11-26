use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojolicious;
use Mojo::JSON qw(decode_json);
use Mojo::URL ();
use Selecto;
use Selecto::Components;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# A measure's series settings (style, axis, stack, colour, opacity) draw a
# graph and nothing else. They show only in the graph view, and stay in the
# form elsewhere so they survive a change of view.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE sales (id integer primary key, region text, amount integer)');
$dbh->do(q{INSERT INTO sales VALUES (1,'east',10), (2,'north',20), (3,'west',30)});
my $domain = Selecto::Domain->parse({name => 'Sales', source => {
    source_table => 'sales', primary_key => 'id', fields => [qw(id region amount)], associations => {},
    columns => {id => {type => 'integer'}, region => {type => 'string'},
        amount => {type => 'integer', unit => {kind => 'count'}, behavior => 'flow'}},
}});
my $app = Mojolicious->new;
$app->secrets(['measure-graph-controls-test']);
$app->log->level('fatal');
$app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {sales => {
    path => '/sales', title => 'Sales', default_fields => [qw(id region)],
    engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh))) },
    measures => [{id => 'total', label => 'Total', aggregate => 'sum', field => 'amount'}],
}}});
my $t = Test::Mojo->new($app);

my %query = (q => 1, field => 'id', group => 'region', group_alias => '', group_format => '',
    measure => 'total', measure_alias => '', measure_function => 'sum', measure_series_id => 'revenue',
    measure_chart_type => 'line', measure_axis => 'right', measure_stack => 'money', measure_color => '#112233',
    measure_fill_opacity => '0.5', measure_transform => '', measure_transform_window => '', limit => 25, page => 1);
my @graph_only = ('select[name="measure_chart_type"]', 'select[name="measure_axis"]', 'input[name="measure_stack"]',
    'input[name="measure_color"]', 'input[name="measure_fill_opacity"]');
my @both = ('select[name="measure_function"]', 'input[name="measure_bucket_ranges"]',
    'select[name="measure_ignore_nulls"]', 'select[name="measure_transform"]');
my $measure = '[data-sc-picker-kind="measure"] [data-sc-picker-set-item]';

for my $view (qw(aggregate graph)) {
    $t->get_ok('/sales' => form => {%query, view => $view})->status_is(200);
    my $dom = $t->tx->res->dom;
    my $item = $dom->at($measure) or BAIL_OUT("no measure item in the $view view");
    is $item->find('[data-sc-measure-graph]')->size, 5, "$view: five series controls are marked";
    my $hidden = $item->find('[data-sc-measure-graph][hidden]')->size;
    is $hidden, $view eq 'graph' ? 0 : 5, $view eq 'graph' ? 'graph: they are shown' : 'aggregate: they are hidden';
    for my $control (@graph_only) {
        ok $item->at("[data-sc-measure-graph] $control"), "$view: $control is inside a marked element and still in the form";
    }
    for my $control (@both) {
        my $node = $item->at($control);
        ok $node && !$node->ancestors('[data-sc-measure-graph]')->size, "$view: $control is not a series control";
    }
    is $item->at('select[name="measure_chart_type"] option[selected]')->attr('value'), 'line', "$view: the series style is kept";
    is $item->at('select[name="measure_axis"] option[selected]')->attr('value'), 'right', "$view: the axis is kept";
    is $item->at('input[name="measure_stack"]')->attr('value'), 'money', "$view: the stack group is kept";
    is $item->at('input[name="measure_color"]')->attr('value'), '#112233', "$view: the colour is kept";
    is $item->at('input[name="measure_fill_opacity"]')->attr('value'), '0.5', "$view: the opacity is kept";

    my $choice = $dom->at('[data-sc-picker-kind="group"] [data-sc-picker-set-item] [data-sc-group-grid-column]');
    ok $choice, "$view: a group has the Show as columns choice";
    is $dom->find('[data-sc-picker-kind="group"] [data-sc-group-grid-column][hidden]')->size, $view eq 'aggregate' ? 0 : 1,
        $view eq 'aggregate' ? 'aggregate: it is shown' : 'graph: it is hidden';
    is $choice->at('input[type="checkbox"][name="pivot_column"]')->attr('value'), 'region', "$view: it names its group";
}

# Execute the real analytics pipeline over SQLite aggregate rows, not a stub.
for my $alpha (undef, '', '0.2') {
    my %ema_query = (%query, view => 'graph', order => 'region', direction => 'asc',
        measure_transform => 'exponential_moving_average',
        (defined($alpha) ? (measure_transform_alpha => $alpha) : ()));
    $t->get_ok('/sales' => form => \%ema_query)->status_is(200);
    my $dom = $t->tx->res->dom;
    my $chart = decode_json($dom->at('[data-chart-data]')->attr('data-chart-data'));
    is_deeply $chart->{labels}, [qw(east north west)], 'EMA uses ordered aggregate points';
    is_deeply $chart->{datasets}[0]{rawData}, [10, 20, 30], 'EMA retains raw aggregates';
    is_deeply $chart->{datasets}[0]{data}, defined($alpha) && length($alpha)
        ? [10, 12, 15.6] : [10, 15, 22.5], 'EMA matches the hand-computed series';
    is_deeply $chart->{datasets}[0]{transforms}, ['exponential_moving_average'], 'graph names its transform';
    my $item = $dom->at($measure);
    ok $item->at('[data-sc-measure-transform-alpha]:not([hidden])'), 'EMA shows smoothing control';
    ok $item->at('[data-sc-measure-transform-window][hidden]'), 'EMA hides moving window';
    ok $item->at('input[name="measure_transform_alpha"][min="0.01"][max="1"][step="0.01"]'),
        'smoothing input has decimal browser bounds';
    is $item->at('input[name="measure_transform_alpha"]')->attr('value'),
        defined($alpha) && length($alpha) ? $alpha : '0.5', 'smoothing input restores alpha';
    like $item->all_text, qr/Higher follows recent values more closely\./, 'smoothing hint is present';
    my $hidden = $dom->at('[data-sc-result-view-panel="detail"] input[type="hidden"][name="measure_transform_alpha"]');
    ok $hidden, 'Detail carries alpha as hidden measure state';
    is $hidden->attr('value'), defined($alpha) && length($alpha) ? $alpha : '0.5',
        'hidden state retains the normalized alpha';
    my $permalink = $dom->find('a')->first(sub { $_->text eq 'Permalink' })->attr('href');
    $t->get_ok($permalink)->status_is(200);
    is_deeply decode_json($t->tx->res->dom->at('[data-chart-data]')->attr('data-chart-data')),
        $chart, 'permalink restores transformed graph data';
    $t->get_ok('/sales' => form => {%ema_query, format => 'json'})->status_is(200);
    my $export = decode_json($t->tx->res->body);
    is_deeply [map { $_->{Total} } @{$export->{rows}}], [10, 20, 30],
        'graph export retains underlying aggregate values';
    my $csrf = $dom->at('form[data-sc-builder]')->attr('data-sc-column-values-csrf');
    $t->post_ok('/sales/controls' => form => {%ema_query, csrf_token => $csrf})->status_is(200);
    like $t->tx->res->json->{html}, qr/name="measure_transform_alpha" value="(?:0\.5|0\.2)"/,
        'view-controls API restores alpha';
}
$t->get_ok('/sales' => form => {%query, view => 'graph',
    measure_transform => 'exponential_moving_average', measure_transform_alpha => '0.0000001'})
    ->status_is(200)
    ->element_exists('input[name="measure_transform_alpha"][value="0.0000001"]');
is_deeply [map { $_->attr('value') } @{$t->tx->res->dom->find('form[data-sc-builder] input[name="measure_transform_alpha"]')}],
    ['0.0000001', '0.0000001'], 'small decimal alpha stays plain in live and hidden inputs';

for my $transform ('', 'moving_average') {
    $t->get_ok('/sales' => form => {%query, view => 'graph', measure_transform => $transform,
        measure_transform_alpha => 'abc'})->status_is(200)
        ->element_exists("$measure [data-sc-measure-transform-alpha][hidden]");
}
for my $alpha ('0', '-0.1', '1.01', '1.5', 'abc', '1e-3') {
    $t->get_ok('/sales' => form => {%query, view => 'graph',
        measure_transform => 'exponential_moving_average', measure_transform_alpha => $alpha})
        ->status_is(422)
        ->content_like(qr/An exponential-moving-average alpha must be greater than 0 and at most 1\./)
        ->content_unlike(qr/alpha must be a bounded number/)
        ->element_exists_not('[data-chart-data]');
}

done_testing;
