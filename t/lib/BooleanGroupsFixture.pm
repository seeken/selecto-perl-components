package BooleanGroupsFixture;
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
    $dbh->do('CREATE TEMP TABLE boolean_groups (id integer primary key, region varchar(8), rush boolean, invoiced boolean, reverse_flag boolean)');
    $dbh->do('INSERT INTO boolean_groups VALUES (?, ?, ?, ?, ?)', undef, @$_) for
        [1, 'East', 1, 1, 1], [2, 'East', 0, 0, 0], [3, 'West', 1, 1, 1], [4, 'West', undef, 0, undef];
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Booleans',
        source => {source_table => 'boolean_groups', primary_key => 'id', fields => [qw(id region rush invoiced reverse_flag)],
            columns => {id => {type => 'integer'}, region => {type => 'string'}, rush => {type => 'boolean'},
                invoiced => {type => 'boolean', display => {true => 'Invoiced', false => 'Not invoiced'}},
                reverse_flag => {type => 'boolean', value_order => ['true', 'false']}}, associations => {}},
        schemas => {}, joins => {}, extensions => {i18n => {namespace => 'booleans'}}}, strict => 1);
    my $adapter = Selecto->adapter($backend => (dbh => $dbh));
    my %settings = (default_fields => [qw(id rush)], default_group => ['rush'],
        engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
        measures => [{id => 'count', label => 'Count', aggregate => 'count'}]);
    my $app = Mojolicious->new;
    $app->secrets(['boolean-groups-synthetic-fixture']);
    $app->log->level('fatal');
    $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {
        flags => {%settings, path => '/flags'},
        localized => {%settings, path => '/localized', localizer => sub {
            my ($key, $default) = @_;
            return 'Oui' if $key eq 'booleans.fields.rush.display.true';
            return 'Non' if $key eq 'booleans.fields.rush.display.false';
            return $default;
        }},
    }});
    return $app;
}
1;
