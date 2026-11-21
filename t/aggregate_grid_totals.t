use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::Explorer ();

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# The aggregate grid groups with CUBE on adapters that support it, and shows a
# total for each row, each column and the whole grid.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do('CREATE TABLE grid_orders (id integer primary key, state text, region text, total integer)');
$dbh->do(q{INSERT INTO grid_orders VALUES
    (1,'open','east',10), (2,'open','west',20), (3,'done','east',5), (4,'done','east',7)});

my $domain = Selecto::Domain->new(
    name => 'Grid orders', table => 'grid_orders',
    fields => {id => 'integer', state => 'string', region => 'string', total => 'integer'},
);
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
plan skip_all => 'this selecto-perl has no cube support' unless $adapter->supports('cube');

my $app = Mojolicious->new;
$app->secrets(['aggregate-grid-totals-test']);
$app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {orders => {
    path => '/orders', title => 'Orders',
    engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
    default_fields => [qw(id state region total)],
    measures => [
        {id => 'count', label => 'Orders', aggregate => 'count'},
        {id => 'avg_total', label => 'Average total', aggregate => 'avg', field => 'total'},
    ],
}}});
my $t = Test::Mojo->new($app);

my @grid = (q => 1, view => 'aggregate', aggregate_grid => 1, field => 'id',
    group => [qw(state region)], limit => 25, page => 1);

sub cell_texts {
    my ($dom, $selector) = @_;
    return [map { my $text = $_->all_text; $text =~ s/[\s\x{2713}]+//g; $text } @{$dom->find($selector)}];
}

$t->get_ok('/orders' => form => {@grid, measure => 'count'})->status_is(200)
    ->element_exists('.sc-aggregate-grid')
    or diag $t->tx->res->dom->find('.sc-error, [role=alert], .sc-grid-warning')->map('all_text')->join('; ');
my $dom = $t->tx->res->dom;
is_deeply(cell_texts($dom, '.sc-aggregate-grid thead th'), ['State/Region', 'east', 'west', 'Total'],
    'a Total column follows the column values');
is_deeply(cell_texts($dom, '.sc-aggregate-grid tbody tr:nth-child(1) > *'), ['done', '2', '—', '2'],
    'a row ends with its total, and an empty cell stays empty');
is_deeply(cell_texts($dom, '.sc-aggregate-grid tbody tr:nth-child(2) > *'), ['open', '1', '1', '2'],
    'second row and its total');
is_deeply(cell_texts($dom, '.sc-aggregate-grid tbody tr.sc-grid-total-row > *'), ['Total', '3', '1', '4'],
    'the last row holds the column totals and the grand total');
is($dom->find('.sc-aggregate-grid td.sc-grid-total input')->size, 0, 'totals are not selectable cells');
is($dom->find('.sc-aggregate-grid td.sc-grid-cell input[name="grid_cell"]')->size, 4,
    'the four value cells remain selectable');

$t->get_ok('/orders' => form => {@grid, measure => 'avg_total'})->status_is(200);
my $averages = cell_texts($t->tx->res->dom, '.sc-aggregate-grid tbody tr.sc-grid-total-row > *');
like($averages->[-1], qr/\A10\.5/, 'a total is the database aggregate (42 / 4), not a sum of the cells');
like($averages->[1], qr/\A7\.3/, 'and so is a column total (22 / 3)');

$t->get_ok('/orders' => form => {@grid, measure => 'count', filter_field => 'region', filter_op => 'eq',
    filter_value => 'east', filter_value_end => '', filter_group => 0, filter_clause => ''})->status_is(200);
is_deeply(cell_texts($t->tx->res->dom, '.sc-aggregate-grid tbody tr.sc-grid-total-row > *'), ['Total', '3', '3'],
    'totals follow the filter');

subtest 'cube rows that drop an earlier dimension have no prefix drilldown' => sub {
    my $built = {rollup => 1, cube => 1, group_count => 2, rollup_key => 'g',
        columns => [{key => 'state', field => 'state'}, {key => 'region', field => 'region'}, {key => 'n', measure => 1}]};
    my @records = ({state => undef, region => 'east', n => 3, g => 2}, {state => 'open', region => undef, n => 2, g => 1});
    Selecto::Components::Explorer::_prepare_rollup_records($built, \@records);
    is($records[0]{__selecto_rollup_level}, 1, 'one dimension kept');
    is($records[0]{__selecto_grouping_mask}, 2, 'the mask says which');
    ok(!eval { Selecto::Components::Explorer::_prepare_rollup_records({%$built, cube => 0}, [{g => 2}]); 1 },
        'a rollup still rejects a mask that is not a prefix');
};

done_testing;
