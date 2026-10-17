use 5.034;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 't/lib';
use TestSelectoComponents;
use Selecto;
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Components::Config;
use Selecto::Components::Explorer;

# Selecto::PostgreSQL returns the driver's values unless canonical values are
# asked for. The Explorer grid and its exports ask for them, so an adapter
# built with the defaults still shows 2.5 (not 2.50) and ISO timestamps.

my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && length $url;
plan skip_all => 'DBI, DBD::Pg and Mojo::URL are required'
    unless eval { require DBI; require DBD::Pg; require Mojo::URL; require Test::Mojo; 1 };
my $parsed = Mojo::URL->new($url);
my $dbh = DBI->connect('dbi:Pg:dbname=' . substr($parsed->path, 1) . ';host=' . ($parsed->host // 'localhost')
    . ';port=' . ($parsed->port // 5432), $parsed->username, $parsed->password,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do(q{SET TimeZone = 'UTC'});
$dbh->do('DROP TABLE IF EXISTS selecto_components_canonical_rows');
$dbh->do('CREATE TABLE selecto_components_canonical_rows (id integer primary key, amount numeric(10,2),
    happened_at timestamp)');
$dbh->do(q{INSERT INTO selecto_components_canonical_rows VALUES
    (1, 2.50, '2024-01-01 10:00:00'), (2, 7152.00, '2024-06-01 12:34:56.5')});

my $domain = Selecto::Domain->new(name => 'CanonicalRows', table => 'selecto_components_canonical_rows',
    fields => {id => 'integer', amount => 'decimal', happened_at => 'naive_datetime'});
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
ok(!$adapter->canonical_values, 'the adapter returns driver values by default');
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
is_deeply($engine->all($engine->query->select(qw(amount happened_at))->order_by('id'))->{rows}[0],
    ['2.50', '2024-01-01 10:00:00'], 'which keep the numeric scale and the server timestamp text');

my $dir = tempdir(CLEANUP => 1);
my $config = Selecto::Components::Config->new(id => 'rows', title => 'Rows', path => '/rows',
    export_lock_dir => $dir, engine_factory => sub { $engine });
my $view = Selecto::Components::Explorer->new(config => $config);

subtest 'the grid shows canonical values' => sub {
    my $app = Mojolicious->new;
    $app->secrets(['canonical-values-test']);
    $app->plugin('Selecto::Components' => {websocket_mode => 'public',
        explorers => {rows => {path => '/rows', title => 'Rows', engine_factory => sub { $engine },
            default_fields => [qw(id amount happened_at)]}}});
    my $t = Test::Mojo->new($app);
    $t->get_ok('/rows' => form => {q => 1, field => [qw(id amount happened_at)], order => 'id'})
        ->status_is(200)
        ->content_like(qr/>\s*2\.5\s*</, 'a decimal without trailing zeros')
        ->content_unlike(qr/>\s*2\.50\s*</, 'not the driver text')
        ->content_like(qr/2024-01-01T10:00:00/, 'an ISO timestamp')
        ->content_like(qr/2024-06-01T12:34:56\.5/, 'with its fraction');
};

subtest 'exports stream canonical values' => sub {
    my $request = TestSelectoComponents::Controller->new(params => {q => 1, field => [qw(id amount happened_at)],
        order => 'id'});
    my $export = $view->stream_export($request, 'csv');
    my $output = '';
    while (defined(my $chunk = $export->{next_chunk}->())) { $output .= $chunk }
    $export->{close}->();
    my @lines = grep { length } split /\r\n/, $output;
    is($lines[1], '"1","2.5","2024-01-01T10:00:00"', 'CSV row one');
    is($lines[2], '"2","7152","2024-06-01T12:34:56.5"', 'CSV row two');
    $request = TestSelectoComponents::Controller->new(params => {q => 1, field => [qw(id amount happened_at)],
        order => 'id'});
    $export = $view->stream_export($request, 'json');
    $output = '';
    while (defined(my $chunk = $export->{next_chunk}->())) { $output .= $chunk }
    $export->{close}->();
    like($output, qr/"2\.5"/, 'JSON carries the canonical decimal');
    like($output, qr/"2024-06-01T12:34:56\.5"/, 'and the ISO timestamp');
    unlike($output, qr/2\.50|7152\.00|2024-01-01 10:00:00/, 'and no driver text');
};

$dbh->do('DROP TABLE selecto_components_canonical_rows');
$dbh->disconnect;
done_testing;
