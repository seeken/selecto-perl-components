use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojolicious;
use Selecto;
use Selecto::Components;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# A measure's series settings (style, axis, stack, colour, opacity) draw a
# graph and nothing else. They show only in the graph view, and stay in the
# form elsewhere so they survive a change of view.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE sales (id integer primary key, region text, amount integer)');
$dbh->do(q{INSERT INTO sales VALUES (1,'east',10), (2,'west',20)});
my $domain = Selecto::Domain->new(name => 'Sales', table => 'sales',
    fields => {id => 'integer', region => 'string', amount => 'integer'});
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

done_testing;
