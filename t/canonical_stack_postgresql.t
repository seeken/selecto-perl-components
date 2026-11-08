use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(decode_json);
use lib 'examples/lib';
use CanonicalStack;

unless ($ENV{SELECTO_PERL_STACK_POSTGRES_URL}) {
    die "PostgreSQL stack verification requires its owned URL\n" if $ENV{SELECTO_REMOTE_REQUIRE_POSTGRES};
    plan skip_all => 'SELECTO_PERL_STACK_POSTGRES_URL not configured';
}
my $app = CanonicalStack->new;
my $anonymous = Test::Mojo->new($app);
$anonymous->get_ok('/api/items/catalog')->status_is(401)->json_is('/error/code' => 'authentication_required');
$anonymous->post_ok('/api/items/query' => json => {})->status_is(401);
$anonymous->get_ok('/api/items/console')->status_is(302)->header_is(Location => '/session');

sub login {
    my ($actor) = @_;
    my $t = Test::Mojo->new($app);
    $t->get_ok('/session')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
    $t->post_ok('/session' => form => {csrf_token => $csrf, actor => $actor})->status_is(302);
    return ($t, $csrf);
}
my ($alpha, $csrf) = login('alpha');
my ($beta, $beta_csrf) = login('beta');
$alpha->get_ok('/api/items')->status_is(200)->json_is('/profiles/0' => 'remote_query.v1');
my $manifest = $alpha->tx->res->json;
my $fingerprint = $manifest->{domain}{fingerprint};
for my $operation ([getDomainCatalog => '/api/items/catalog'], [getExplorerMetadata => '/api/items/explorer']) {
    ok scalar(grep { $_->{operation_id} eq $operation->[0] && $_->{method} eq 'GET'
        && $_->{path} eq $operation->[1] } @{$manifest->{routes}}), "$operation->[0] is discoverable";
}
$alpha->get_ok('/api/items/console')->status_is(200)
    ->element_exists('main[data-selecto-api-console][data-api-base="/api/items"][data-csrf-token]')
    ->header_like('Cache-Control' => qr/no-store/);
# Mojolicious masks the same session token afresh for each rendered page.
# Use the Console's token for the successful and rejected POST checks below.
$csrf = $alpha->tx->res->dom->at('main')->attr('data-csrf-token');
$alpha->get_ok('/api/items/domain')->status_is(200)->json_is('/domain_fingerprint' => $fingerprint);
$alpha->get_ok('/api/items/catalog')->status_is(200);
my $publication = $alpha->tx->res->json->{domains}[0]{publication};
$beta->get_ok('/api/items/catalog')->status_is(200);
isnt $beta->tx->res->json->{domains}[0]{publication}, $publication, 'publication changes with the signed-in principal';
$alpha->get_ok('/api/items/explorer')->status_is(200)->json_is('/domain/fingerprint' => $fingerprint)
    ->json_is('/domain/publication' => $publication)->json_is('/query/supports/aggregates' => Mojo::JSON::false);
my @ids = map { $_->{path} } @{$alpha->tx->res->json->{fields}};
is_deeply \@ids, [qw(id name amount active note large_integer due_on)], 'metadata omits hidden fields';
my $envelope = {format => 'selecto.remote-query', format_version => 1,
    domain => {fingerprint => $fingerprint}, query => {
        select => [qw(id name amount active note large_integer due_on)],
        order_by => [{field => 'id', direction => 'asc'}], limit => 2, offset => 0}};
$alpha->post_ok('/api/items/query' => json => $envelope)->status_is(403);
$alpha->post_ok('/api/items/query' => {'X-CSRF-Token' => $csrf, Origin => 'https://foreign.invalid'} => json => $envelope)
    ->status_is(403)->json_is('/error/code' => 'operation_forbidden');
my $reads = 0;
my $original = Selecto::PostgreSQL->can('stream_query');
{
    no warnings qw(redefine once);
    local *Selecto::PostgreSQL::stream_query = sub { ++$reads; return $original->(@_); };
    $alpha->post_ok('/api/items/query' => {'X-CSRF-Token' => $csrf} => json => $envelope)
        ->status_is(200)->json_is('/data/rows/0/1' => 'Alpha One')
        ->json_is('/data/rows/0/5' => '9007199254740993')->json_is('/data/page/has_more' => Mojo::JSON::true);
    is $reads, 1, 'canonical page is one native bounded read, with no total-count query';
    $beta->post_ok('/api/items/query' => {'X-CSRF-Token' => $beta_csrf} => json => $envelope)
        ->status_is(200)->json_is('/data/rows/0/1' => 'Beta One');
    is $reads, 2, 'fresh principal executes its own scoped query';
    my $hidden = decode_json(Mojo::JSON::encode_json($envelope)); $hidden->{query}{select} = ['secret'];
    $alpha->post_ok('/api/items/query' => {'X-CSRF-Token' => $csrf} => json => $hidden)
        ->status_is(403)->json_is('/error/code' => 'hidden_field');
    is $reads, 2, 'hidden selection refuses before native execution';
    my $unknown = decode_json(Mojo::JSON::encode_json($envelope)); $unknown->{query}{select} = ['__selecto_missing__'];
    $alpha->post_ok('/api/items/query' => {'X-CSRF-Token' => $csrf} => json => $unknown)
        ->status_is(422)->json_is('/error/code' => 'invalid_field');
    is $reads, 2, 'unknown selection refuses before native execution';
    my $stale = decode_json(Mojo::JSON::encode_json($envelope)); $stale->{domain}{fingerprint} = 'stale';
    $alpha->post_ok('/api/items/query' => {'X-CSRF-Token' => $csrf} => json => $stale)->status_is(409);
    is $reads, 2, 'stale publication refuses before native execution';
    $alpha->get_ok('/explore/items')->status_is(200)->content_like(qr/Alpha One/)->content_unlike(qr/Beta One|alpha-hidden-one/)
        ->element_exists('a[data-sc-api-console][href^="/api/items/console#request="]');
    is $reads, 4, 'native HTML uses the bounded reader for its page and explicit total';
    $alpha->get_ok('/explore/items?page=2')->status_is(200)->content_like(qr/Alpha Three/)
        ->content_like(qr/9007199254740993\.123456/)->content_like(qr/9007199254740995/);
    is $reads, 6, 'ordinary fallback page keeps exact scalars through the same bounded reader';
}
$alpha->get_ok('/spa-vue/index.html')->status_is(200)
    ->content_like(qr/<meta name="csrf-token" content="[^"]+">/)
    ->content_like(qr{/spa-vue/assets/});
$alpha->post_ok('/logout' => form => {csrf_token => $csrf})->status_is(302);
$alpha->get_ok('/api/items/catalog')->status_is(401);
$alpha->get_ok('/api/items/console')->status_is(302)->header_is(Location => '/session');
done_testing;
