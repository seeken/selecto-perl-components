use 5.034;
use strict;
use warnings;
use Mojolicious;
use DBI;
use Selecto;
use Selecto::Components;

# Synthetic dimension keys and labels, with two cells per category. All data
# lives in memory; this app is also used by the Perl HTTP regression tests.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1});
$dbh->do('CREATE TABLE customers (id integer primary key, co_name text)');
$dbh->do('CREATE TABLE sales (id integer primary key, customer_id integer, channel text, revenue integer)');
for my $id (1 .. 146) {
    my $label = $id == 146 ? 'Customer 146 with a very long company name for the axis tooltip'
        : sprintf('Customer %03d', $id == 2 ? 1 : $id);
    $dbh->do('INSERT INTO customers VALUES (?, ?)', undef, $id, $label);
    for my $channel (0, 1) {
        $dbh->do('INSERT INTO sales VALUES (?, ?, ?, ?)', undef,
            $id * 2 + $channel, $id, $channel ? 'B' : 'A', $id * 10 + $channel);
    }
}
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Sales',
    source => {source_table => 'sales', primary_key => 'id', fields => [qw(id customer_id channel revenue)],
        columns => {id => {type => 'integer'}, customer_id => {type => 'integer'}, channel => {type => 'string'},
            revenue => {type => 'integer', unit => {kind => 'currency', code => 'USD'}, behavior => 'flow'}},
        associations => {customer => {queryable => 'customers', owner_key => 'customer_id', related_key => 'id'}}},
    schemas => {customers => {source_table => 'customers', primary_key => 'id', fields => [qw(id co_name)],
        columns => {id => {type => 'integer'}, co_name => {type => 'string'}}, associations => {}}},
    joins => {customer => {type => 'star_dimension', name => 'Customer', display_field => 'co_name', dimension_key => 'customer_id'}},
}, strict => 1);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
my $app = Mojolicious->new;
$app->secrets(['hbar-browser']);
$app->log->level('fatal');
$app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {sales => {
    path => '/sales', default_fields => ['id'], max_limit => 500,
    engine_factory => sub { $engine },
    measures => [{id => 'revenue', label => 'Revenue', aggregate => 'sum', field => 'revenue'},
        {id => 'volume', label => 'Volume', aggregate => 'count'}],
}, sales_capped => {
    path => '/sales-capped', default_fields => ['id'], max_limit => 500, max_grid_result_cells => 100,
    engine_factory => sub { $engine },
    measures => [{id => 'revenue', label => 'Revenue', aggregate => 'sum', field => 'revenue'}],
}}});
$app->start unless caller;
$app;
