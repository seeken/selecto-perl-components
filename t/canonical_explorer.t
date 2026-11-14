use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojolicious ();
use Selecto;
use Selecto::Components::Canonical ();
use Selecto::Components::Config ();

# canonical_explorer adds remote_query.explorer.v1 (Selecto::API::Explorer) to
# the canonical base: the manifest advertises it, GET explorer-features and
# POST explorer-query answer, and the POST has the query route's CSRF and
# same-origin rules.
plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, secret TEXT)');
$dbh->do('INSERT INTO items VALUES (?, ?, ?, ?)', undef, @$_) for [1, 'Bolt', 'part', 's1'], [2, 'Nut', 'part', 's2'],
    [3, 'Drill', 'tool', 's3'];
my $domain = Selecto::Domain->parse({schema_version => 1, domain_version => '1.0.0', name => 'Items',
    domain_fingerprint => 'sha256:canonical-explorer-test',
    source => {source_table => 'items', primary_key => 'id', fields => [qw(id name kind secret)],
        columns => {id => {type => 'integer', nullable => 0}, name => {type => 'string', nullable => 0},
            kind => {type => 'string', nullable => 0}, secret => {type => 'string', internal => 1}},
        associations => {}},
    schemas => {}, joins => {}}, strict => 1);
my $config = Selecto::Components::Config->new(
    id => 'items', title => 'Items', path => '/explore/items', default_fields => [qw(id name)],
    engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh))) },
    canonical_api_path => '/api/items', canonical_authorizer => sub { 1 },
    canonical_publication => sub { 'publication-1' },
    canonical_explorer => {clock => '2026-03-15T03:30:00Z', count_exact => 1, limits => {max_groups => 20}},
);
my $app = Mojolicious->new;
$app->routes->get('/token' => sub { my $c = shift; $c->render(text => $c->csrf_token) });
Selecto::Components::Canonical->register($app->routes, $config, '/api/items');
my $t = Test::Mojo->new($app);
my $csrf = $t->get_ok('/token')->tx->res->text;

$t->get_ok('/api/items')->status_is(200)->json_is('/profiles/1' => 'remote_query.explorer.v1');
my %routes = map { ($_->{operation_id} => $_->{path}) } @{$t->tx->res->json->{routes}};
is $routes{getExplorerFeatures}, '/api/items/explorer-features';
is $routes{queryExplorer}, '/api/items/explorer-query';
ok $routes{getDomainCatalog}, 'the catalog route is still advertised';
$t->get_ok('/api/items/explorer-features')->status_is(200)->json_is('/format' => 'selecto.explorer-features')
    ->json_is('/domain/publication' => 'publication-1');
my $features = $t->tx->res->json;
is_deeply [map { $_->{id} } @{$features->{fields}}], [qw(id kind name)], 'withheld fields are not published';
my $envelope = {format => 'selecto.explorer-query', format_version => 1,
    domain => {fingerprint => $features->{domain}{fingerprint}}, features => {revision => $features->{revision}},
    request_id => 'c1', query => {group_by => ['kind'], select => ['kind', {aggregate => 'count', alias => 'n'}]}};
$t->post_ok('/api/items/explorer-query' => json => $envelope)->status_is(403)
    ->json_is('/error/code' => 'operation_forbidden');
$t->post_ok('/api/items/explorer-query' => {'X-CSRF-Token' => $csrf, Origin => 'https://foreign.invalid'} => json => $envelope)
    ->status_is(403);
$t->post_ok('/api/items/explorer-query' => {'X-CSRF-Token' => $csrf} => json => $envelope)->status_is(200)
    ->json_is('/data/rows' => [['part', 2], ['tool', 1]])->json_is('/meta/request_id' => 'c1');
my $hidden = {%$envelope, query => {select => ['id'], filters => [{any => [{field => 'kind', op => 'eq', value => 'x'},
    {field => 'secret', op => 'eq', value => 's1'}]}]}};
$t->post_ok('/api/items/explorer-query' => {'X-CSRF-Token' => $csrf} => json => $hidden)->status_is(403)
    ->json_is('/error/code' => 'hidden_field');
my $export = {%$envelope, query => {select => ['id', 'name'], order_by => [{field => 'id'}], export => {all_rows => \1}}};
$t->post_ok('/api/items/explorer-query' => {'X-CSRF-Token' => $csrf, Accept => 'text/csv'} => json => $export)
    ->status_is(200)->content_type_like(qr{\Atext/csv})->content_is("id,name\r\n1,Bolt\r\n2,Nut\r\n3,Drill\r\n")
    ->header_like('Content-Disposition' => qr/attachment/);

my $plain = Selecto::Components::Config->new(%$config, canonical_explorer => undef);
my $without = Mojolicious->new;
Selecto::Components::Canonical->register($without->routes, $plain, '/api/items');
my $w = Test::Mojo->new($without);
$w->get_ok('/api/items')->status_is(200)->json_is('/profiles' => ['remote_query.v1']);
$w->get_ok('/api/items/explorer-features')->status_is(404);

eval { Selecto::Components::Config->new(%$config, canonical_explorer => {colour => 1}) };
like $@, qr/unknown options: colour/, 'explorer options are closed';
done_testing;
