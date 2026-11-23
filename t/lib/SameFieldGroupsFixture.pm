package SameFieldGroupsFixture;
use strict;
use warnings;
use DBI;
use Mojo::URL;
use Mojolicious;
use Selecto;
use Selecto::Components;

sub app {
    my ($backend) = @_;
    $backend //= 'sqlite';
    my $dbh;
    if ($backend eq 'postgresql') {
        my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // die 'PostgreSQL URL required');
        $dbh = DBI->connect('dbi:Pg:dbname=' . substr($url->path, 1) . ';host=' . $url->host . ';port=' . $url->port,
            $url->username, $url->password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    } else {
        $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    }
    $dbh->do('CREATE TEMP TABLE same_field_groups (id integer primary key, created_on timestamp, title varchar(80), days integer)');
    my $insert = $dbh->prepare('INSERT INTO same_field_groups VALUES (?, ?, ?, ?)');
    my $id = 0;
    for my $year (2024, 2025) {
        for my $month (1 .. 12) {
            for my $day ($month == 3 ? (3, 15) : (3)) {
                $insert->execute(++$id, sprintf('%04d-%02d-%02d 12:00:00', $year, $month, $day),
                    $month % 2 ? 'The Apple' : 'An Orange', $month);
            }
        }
    }
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Seasonality',
        source => {source_table => 'same_field_groups', primary_key => 'id', fields => [qw(id created_on title days)],
            columns => {id => {type => 'integer'}, created_on => {type => 'datetime', label => 'Created'},
                title => {type => 'string'}, days => {type => 'integer'}}, associations => {}},
        schemas => {}, joins => {}}, strict => 1);
    my $adapter = Selecto->adapter($backend => (dbh => $dbh));
    my $app = Mojolicious->new;
    $app->secrets(['same-field-groups-synthetic-fixture']);
    $app->log->level('fatal');
    $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {seasonality => {
        path => '/seasonality', default_fields => [qw(id created_on)], default_group => ['created_on'],
        engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
        measures => [{id => 'count', label => 'Count', aggregate => 'count'}],
    }}});
    return ($app, $domain);
}
1;
