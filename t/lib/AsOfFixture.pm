package AsOfFixture;
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
        die 'PostgreSQL must use the disposable RAM fixture' unless
            $dbh->selectrow_array("SELECT current_setting('selecto.perf_storage', true)") eq 'ram';
    } else {
        $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    }
    $dbh->do('CREATE TEMP TABLE asof_events (id integer primary key, day date, region varchar(8))');
    $dbh->do('INSERT INTO asof_events VALUES (?, ?, ?)', undef, @$_) for
        [1, '2026-03-15', 'East'], [2, '2026-03-14', 'East'], [3, '2026-03-09', 'West'],
        [4, '2026-03-08', 'West'], [5, '2026-02-15', 'East'];
    $dbh->do('INSERT INTO asof_events VALUES (6, CURRENT_DATE, ?)', undef, 'Now');
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'As of events',
        source => {source_table => 'asof_events', primary_key => 'id', fields => [qw(id day region)],
            columns => {id => {type => 'integer'}, day => {type => 'date'}, region => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {},
        query_library => {segments => {today => {filters => [['eq', 'region', 'East']]}},
            views => {today => {segments => ['today']}}},
        extensions => {i18n => {namespace => 'asof'}}}, strict => 1);
    my $adapter = Selecto->adapter($backend => (dbh => $dbh));
    my %settings = (default_fields => [qw(id day region)], default_group => ['region'],
        engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
        defer_count => 0, measures => [{id => 'count', label => 'Count', aggregate => 'count'}]);
    my $app = Mojolicious->new;
    $app->secrets(['asof-synthetic-fixture']);
    $app->log->level('fatal');
    $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {
        events => {%settings, path => '/events', saved_query_store => AsOfFixture::Store->new},
        seeded => {%settings, path => '/seeded', default_as_of => '2026-03-15'},
        hidden => {%settings, path => '/hidden', default_as_of => '2026-03-15', as_of_control => 0},
        localized => {%settings, path => '/localized', localizer => sub {
            my ($key, $default) = @_;
            return 'Au' if $key eq 'asof.explorer.as_of';
            return 'mars' if $key eq 'asof.dates.months.03';
            return $default;
        }},
    }});
    return $app;
}

package AsOfFixture::Store;
sub new { bless {queries => []}, shift }
sub list { $_[0]{queries} }
sub delete { $_[0]{queries} = []; return 1 }
sub save {
    my ($self, $controller, $config, $request) = @_;
    push @{$self->{queries}}, {%$request};
    return 1;
}
1;
