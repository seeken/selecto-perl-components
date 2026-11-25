use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use lib 't/lib';
use DomainCatalogFixture;

my $app = DomainCatalogFixture::app();
my $t = Test::Mojo->new($app);
$t->get_ok('/catalog')->status_is(200)->header_is('Cache-Control', 'no-store')
    ->element_count_is('tbody tr', 3)->text_is('h1', 'Domain catalog')
    ->content_like(qr/Orders registry/)->content_like(qr/abc123/)->content_like(qr/Reference store/)
    ->content_like(qr/changed/)->content_like(qr/warning/)->content_like(qr/Published \/ 3 fields left out/)
    ->element_exists('a[data-sc-link-kind="explorer"][href="/inspect?domain=code_orders"]')
    ->element_exists('form[method="get"]')->element_count_is('form[method="post"]', 0);
$t->get_ok('/catalog?source=file')->status_is(200)->element_count_is('tbody tr', 1)->content_like(qr/File orders/);
$t->get_ok('/catalog?status=changed')->status_is(200)->element_count_is('tbody tr', 1)->content_like(qr/Stored orders/);
$t->get_ok('/catalog?status=warning')->status_is(200)->element_count_is('tbody tr', 1)->content_like(qr/File orders/);
$t->get_ok('/catalog?q=Code%20orders&source=code&status=ok')->status_is(200)->element_count_is('tbody tr', 1);
$t->get_ok('/catalog?q=absent')->status_is(200)->element_count_is('tbody tr', 0)->content_like(qr/No domains match/);
$t->get_ok('/catalog?domain=store_orders')->status_is(200)->text_is('h1', 'Stored orders')
    ->content_like(qr/Current identity and source/)->content_like(qr/Report checks/)->content_like(qr/\$\.query_library/)
    ->content_like(qr/priority/)->content_like(qr/customer.id/)->content_like(qr/Authorization surface/)
    ->content_like(qr/orders.finish/)->content_like(qr/Write operations/)->content_like(qr/Segments/)
    ->element_exists('[data-sc-catalog-copy]')->element_exists('#sc-catalog-json');
my $json = $t->tx->res->dom->at('#sc-catalog-json')->text;
is($json, $app->defaults->{catalog_fixture}{catalog}->document('store_orders'), 'JSON is the canonical served pin');
unlike($json, qr/priority/, 'pin still serves earlier fields while diff describes current');
$t->get_ok('/catalog?domain=store_orders&against=first')->status_is(200)->content_like(qr/priority/);
my $fingerprint = Selecto::Domain->parse($app->defaults->{catalog_fixture}{before})->fingerprint;
$t->get_ok('/catalog?domain=store_orders&against=' . $fingerprint)->status_is(200)->content_like(qr/priority/);
$t->get_ok('/catalog?domain=code_orders&against=missing')->status_is(400);
$t->get_ok('/catalog?domain=code_orders&against=' . ('a' x 64))->status_is(400)->content_unlike(qr/catalog_baseline_missing/);
$t->get_ok('/catalog?domain=unknown')->status_is(404);
for my $method (qw(POST PUT PATCH DELETE OPTIONS HEAD TRACE CONNECT)) {
    for my $target ('/catalog', '/catalog?domain=code_orders', '/catalog/write') {
        my $tx = $t->ua->build_tx($method => $target);
        $t->request_ok($tx);
        ok($t->tx->res->code == 404 || $t->tx->res->code == 405, "$method $target has no write route");
    }
}
{
    my $unsafe = Test::Mojo->new(DomainCatalogFixture::app(
        domain_links_resolver => sub { [{label => '<img src=x>', href => '/safe?x=%22&y=1', kind => 'api'}] },
        domain_columns_resolver => sub { [{id => 'extra', label => '<b>Extra</b>', value => sub { '<script>bad()</script>' }}] },
    ));
    $unsafe->get_ok('/catalog')->status_is(200)->content_like(qr/&lt;img src=x&gt;/)
        ->content_like(qr/&lt;b&gt;Extra&lt;\/b&gt;/)->content_like(qr/&lt;script&gt;bad\(\)&lt;\/script&gt;/)
        ->element_count_is('img', 0)->element_exists('a[href="/safe?x=%22&y=1"]');
    $unsafe->get_ok('/catalog?domain=file_orders')->status_is(200)->content_like(qr/Review &lt;label&gt;/);
}
for my $href ('javascript:alert(1)', '//invalid.example', '/\\invalid', "/bad\nvalue", 'https://invalid.example') {
    my $unsafe = Test::Mojo->new(DomainCatalogFixture::app(domain_links_resolver => sub { [{label => 'Unsafe', href => $href}] }));
    $unsafe->get_ok('/catalog')->status_is(500)->element_count_is('a[href^="javascript:"]', 0);
}
{
    my $localized = Test::Mojo->new(DomainCatalogFixture::app(localizer => sub {
        my ($key, $default) = @_;
        return '<Chercher>' if $key eq 'orders.catalog.search';
        return '<Champs>' if $key eq 'orders.catalog.fields';
        return '<Identite>' if $key eq 'orders.fields.id.label';
        return $default;
    }));
    $localized->get_ok('/catalog')->status_is(200)->content_like(qr/&lt;Chercher&gt;/);
    $localized->get_ok('/catalog?domain=code_orders&scheme=dark')->status_is(200)
        ->content_like(qr/&lt;Champs&gt;/)->content_like(qr/&lt;Identite&gt;/)->element_exists('html[data-sc-color-scheme="dark"]');
}
{
    my $fixture = DomainCatalogFixture::fixture();
    my $auth = Mojolicious->new;
    $auth->log->level('fatal');
    my $bridge = $auth->routes->under('/private')->to(cb => sub { my $c = shift;
        return 1 if ($c->req->headers->header('X-Catalog-Access') // '') eq 'allowed';
        $c->render(text => 'Denied', status => 403); return undef;
    });
    my $resolved = 0;
    Selecto::Components::DomainCatalog->mount($auth, routes => $bridge, path => '/domains',
        catalog_resolver => sub { ++$resolved; $fixture->{catalog} });
    my $a = Test::Mojo->new($auth);
    $a->get_ok('/private/domains')->status_is(403);
    is($resolved, 0, 'catalog resolution follows host authentication');
    $a->get_ok('/private/domains' => {'X-Catalog-Access' => 'allowed'})->status_is(200)
        ->element_exists('a[href="/private/domains?domain=code_orders"]');
    is($resolved, 1, 'catalog resolved once per authorized request');
    $a->get_ok('/domains')->status_is(404);
}
{
    no warnings 'redefine';
    my $admit = Selecto::Engine->can('admit_domain');
    my $construct = Selecto::Engine->can('new');
    our $static_admission;
    local *Selecto::Engine::admit_domain = sub {
        local $static_admission = 1;
        return $admit->(@_);
    };
    local *Selecto::Engine::new = sub {
        die 'page constructed an engine outside static admission' unless $static_admission;
        return $construct->(@_);
    };
    local *Selecto::Engine::all = sub { die 'page ran a query' };
    $t->get_ok('/catalog')->status_is(200);
    $t->get_ok('/catalog?domain=code_orders')->element_exists('#sc-catalog-json');
}
{
    my $catalog = Selecto::DomainCatalog->new(adapter => 'unavailable', sources => [
        Selecto::DomainCatalog::Source::Code->new(domains => {
            refused_orders => sub {
                my $document = DomainCatalogFixture::contract('refused_orders', 'Refused orders');
                $document->{extensions}{catalog}{adapter} = 'unavailable';
                return $document;
            }
        })]);
    my $refused = Test::Mojo->new(DomainCatalogFixture::app(catalog => $catalog));
    $refused->get_ok('/catalog?status=refused')->status_is(200)->element_count_is('tbody tr', 1);
    $refused->get_ok('/catalog?domain=refused_orders')->status_is(200)
        ->content_like(qr/unknown_adapter/)->content_like(qr/The served contract is unavailable/)
        ->element_count_is('#sc-catalog-json', 0);
}
done_testing;
