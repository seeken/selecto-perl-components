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
$dbh->do('CREATE TABLE parties (id integer primary key, party_name text)');
$dbh->do('CREATE TABLE orders (id integer primary key, billto_party_id integer, channel text, quoted_amount integer)');
for my $id (1 .. 146) {
    my $label = $id == 146 ? 'Party 146 with a very long company name for the axis tooltip'
        : sprintf('Party %03d', $id == 2 ? 1 : $id);
    $dbh->do('INSERT INTO parties VALUES (?, ?)', undef, $id, $label);
    for my $channel (0, 1) {
        $dbh->do('INSERT INTO orders VALUES (?, ?, ?, ?)', undef,
            $id * 2 + $channel, $id, $channel ? 'B' : 'A', $id * 10 + $channel);
    }
}
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Orders',
    source => {source_table => 'orders', primary_key => 'id', fields => [qw(id billto_party_id channel quoted_amount)],
        columns => {id => {type => 'integer'}, billto_party_id => {type => 'integer'}, channel => {type => 'string'},
            quoted_amount => {type => 'integer', unit => {kind => 'currency', code => 'USD'}, behavior => 'flow'}},
        associations => {billto => {queryable => 'parties', owner_key => 'billto_party_id', related_key => 'id'}}},
    schemas => {parties => {source_table => 'parties', primary_key => 'id', fields => [qw(id party_name)],
        columns => {id => {type => 'integer'}, party_name => {type => 'string'}}, associations => {}}},
    joins => {billto => {type => 'star_dimension', name => 'Party', display_field => 'party_name', dimension_key => 'billto_party_id'}},
}, strict => 1);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
my $app = Mojolicious->new;
$app->secrets(['hbar-browser']);
$app->log->level('fatal');
$app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {orders => {
    path => '/orders', default_fields => ['id'], max_limit => 500,
    engine_factory => sub { $engine },
    measures => [{id => 'quoted_amount', label => 'Quoted Amount', aggregate => 'sum', field => 'quoted_amount'},
        {id => 'volume', label => 'Volume', aggregate => 'count'}],
}, orders_capped => {
    path => '/orders-capped', default_fields => ['id'], max_limit => 500, max_grid_result_cells => 100,
    engine_factory => sub { $engine },
    measures => [{id => 'quoted_amount', label => 'Quoted Amount', aggregate => 'sum', field => 'quoted_amount'}],
}}});
$app->start unless caller;
$app;
