use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::JSON qw(encode_json decode_json);
use URI::Escape qw(uri_escape);
use Mojolicious;
use Selecto;
use Selecto::Components;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do('CREATE TABLE canned_products (id integer primary key, name text, brand text, category text, price integer, visible integer)');
$dbh->do(q{INSERT INTO canned_products VALUES
    (1,'Alpha shoe','Acme','shoes',20,1),
    (2,'Beta shoe','North','shoes',40,1),
    (3,'Gamma hat','North','hats',10,1),
    (4,'Hidden shoe','Secret','shoes',20,0)});

sub page_spec {
    my ($private) = @_;
    my $domain = Selecto::Domain->new(
        name => 'Canned products', table => 'canned_products',
        fields => {id => 'integer', name => 'string', brand => 'string',
            category => 'string', price => 'integer', visible => 'integer'},
        components => {query_params => $private ? 0 : 1},
    );
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    return {
        domain => $domain,
        engine_factory => sub { $engine },
        path => '/products', title => 'Product Search',
        dataset => {query => $engine->query->where(Selecto::Expression->eq('visible', 1)),
            entity_key => ['id']},
        views => [
            {id => 'list', kind => 'detail', label => 'Products',
                query => $engine->query->select('id', 'name', 'brand')->order_by('id')},
            {id => 'by_category', kind => 'aggregate', label => 'By category',
                query => $engine->query->select('category',
                    Selecto::Expression->count_distinct('id')->as('items'))
                    ->group_by('category')->order_by('category')},
        ],
        controls => [
            {id => 'brand', label => 'Brand', field => 'brand', kind => 'facet',
                values => {limit => 10}},
            {id => 'price', label => 'Price', field => 'price', kind => 'range'},
            {id => 'search', label => 'Name', field => 'name', kind => 'text'},
        ],
        initial_state => {view => 'list', filters => {brand => ['Acme']}},
    };
}

my $app = Mojolicious->new;
$app->secrets(['canned-page-test']);
my $public_spec = page_spec(0);
$public_spec->{record_link} = {field => 'id', url_prefix => '/products/view?id='};
$app->plugin('Selecto::Components' => {pages => {products => $public_spec}});
my $t = Test::Mojo->new($app);
$t->get_ok('/products')->status_is(200)
    ->content_like(qr/Alpha shoe/)
    ->content_unlike(qr/Beta shoe/)
    ->content_like(qr{[12]</strong> rows? matched});
$t->element_exists('main.sc-page .sc-shell .sc-surface.selecto-canned-page',
    'canned page uses the Explorer page shell');
$t->element_exists('.sc-workspace > .sc-builder.selecto-canned-controls',
    'only promoted controls occupy the Explorer builder position');
$t->element_exists('.sc-results .sc-table-wrap table',
    'canned results use the Explorer table renderer');
$t->element_exists('a[href="/products/view?id=1"]',
    'a governed selected ID can open a local record URL');
$t->element_exists('.sc-results td:first-child > a.sc-object-link[href="/products/view?id=1"]',
    'record ID itself links to the record');
$t->content_unlike(qr{<th scope="col">Open</th>},
    'no separate Open column is added');
$t->element_exists('link[href^="/selecto-components/selecto-components.css"]',
    'canned page loads the shared Explorer theme');
$t->element_exists_not('script[src^="/selecto-components/selecto-components.js"]',
    'Explorer query-builder transport does not intercept canned-page replies');
$t->element_exists('select[name=view]', 'authored views remain selectable');
$t->element_exists('input[name=f_brand]', 'promoted facet remains editable');
$t->element_exists('input[name=f_price_min]', 'promoted range remains editable');
$t->element_exists('input[name=f_search]', 'promoted text filter remains editable');
$t->element_exists_not('input[name=field]', 'arbitrary Explorer field selection is unavailable');
$t->get_ok('/products?submitted=1&view=list&f_brand=North&f_price_min=20')
    ->status_is(200)->content_like(qr/Beta shoe/)
    ->content_unlike(qr/Alpha shoe/)
    ->content_unlike(qr/Hidden shoe/);
$t->get_ok('/products?submitted=1&view=by_category&f_brand=North')
    ->status_is(200)->content_like(qr/By category/)
    ->content_like(qr/hats/)->content_like(qr/shoes/)
    ->content_like(qr/drilldown_select/);
my $drilldown = uri_escape(encode_json({view => 'by_category', values => ['shoes']}));
$t->get_ok('/products?submitted=1&view=by_category&f_brand=North&drilldown_select=' . $drilldown)
    ->status_is(200)->content_like(qr/Beta shoe/)
    ->content_unlike(qr/Gamma hat/)
    ->content_like(qr/Clear drilldown/);
$t->get_ok('/products?submitted=1&view=bogus')->status_is(422);
$t->get_ok('/products?submitted=1&view=list')->status_is(200)
    ->content_like(qr{3</strong> rows matched});
$t->get_ok('/products?submitted=1&view=list&limit=1&page=2')->status_is(200)
    ->content_like(qr/Page 2 of 3/)
    ->element_exists('.sc-pagination-top button[name=page][value="1"]')
    ->element_exists('.sc-pagination-bottom button[name=page][value="3"]');
$t->websocket_ok('/products/ws')->send_ok({text => encode_json({
    headers => {}, submitted => 1, view => 'list', f_brand => 'North',
    selecto_request_id => '7',
})})->message_ok;
my $message = decode_json($t->message->[1]);
is($message->{selecto}{request_id}, '7', 'WebSocket response preserves the revision id');
is($message->{target}, '#selecto-page-products', 'WebSocket replaces the page surface');
like($message->{content}, qr/Beta shoe/, 'WebSocket result uses the same governed query');
unlike($message->{content}, qr/Alpha shoe/, 'WebSocket filter excludes other brands');
$t->finish_ok;

my $private = Mojolicious->new;
$private->secrets(['canned-private-test']);
$private->plugin('Selecto::Components' => {pages => {products => page_spec(1)}});
my $p = Test::Mojo->new($private);
$p->get_ok('/products')->status_is(200)
    ->header_is('Cache-Control', 'no-store')
    ->element_exists('form[method=post]')
    ->content_unlike(qr/Beta shoe/);
$p->get_ok('/products?submitted=1&f_brand=North')->status_is(302)
    ->header_is('Location', '/products');
$p->post_ok('/products' => form => {submitted => 1, view => 'list', f_brand => 'North'})
    ->status_is(200)->content_like(qr/Beta shoe/)
    ->content_unlike(qr/Alpha shoe/);
$p->websocket_ok('/products/ws')->send_ok({text => encode_json({
    headers => {}, submitted => 1, view => 'list', f_brand => 'North',
    selecto_request_id => '1',
})})->message_ok;
my $private_message = decode_json($p->message->[1]);
like($private_message->{content}, qr/method="post"/, 'private WebSocket result retains POST fallback');
unlike($private_message->{content}, qr/\?submitted=/, 'private response does not expose query state');
$p->finish_ok;

my $scoped_app = Mojolicious->new;
$scoped_app->secrets(['canned-scoped-test']);
my $scoped_spec = page_spec(0);
$scoped_spec->{scope_factory} = sub {
    my ($controller) = @_;
    die "synthetic scope failure\n"
        if ($controller->req->headers->header('X-Test-Brand') // '') eq 'broken';
    my $brand = ($controller->req->headers->header('X-Test-Brand') // '') eq 'North'
        ? 'North' : 'Acme';
    return Selecto::Expression->eq('brand', $brand);
};
$scoped_app->plugin('Selecto::Components' => {pages => {products => $scoped_spec}});
my $s = Test::Mojo->new($scoped_app);
$s->get_ok('/products?submitted=1&view=list&f_brand=Acme'
    => {'X-Test-Brand' => 'North'})
    ->status_is(200)->content_like(qr/0 matching items/)
    ->content_unlike(qr/Alpha shoe/)
    ->content_like(qr/North/);
$s->get_ok('/products' => {'X-Test-Brand' => 'broken'})
    ->status_is(500)->content_is('Page data is unavailable');

my $guarded = Mojolicious->new;
$guarded->secrets(['canned-guarded-test']);
my $routes = $guarded->routes->under('/secured')->to(cb => sub {
    my ($controller) = @_;
    return 1 if ($controller->req->headers->header('X-Test-Authorized') // '') eq 'yes';
    $controller->render(text => 'Denied by host', status => 401);
    return undef;
});
my $guarded_spec = page_spec(0);
$guarded_spec->{path} = '/secured/products';
$guarded->plugin('Selecto::Components' => {
    route_bridge => {routes => $routes, prefix => '/secured'},
    pages => {products => $guarded_spec},
});
my $g = Test::Mojo->new($guarded);
$g->get_ok('/secured/products')->status_is(401)->content_is('Denied by host');
$g->get_ok('/secured/products' => {'X-Test-Authorized' => 'yes'})
    ->status_is(200)->content_like(qr/Alpha shoe/);
$g->get_ok('/products')->status_is(404);

# limit and page are always attribute/text escaped, even if a future state
# normalizer lets a non-numeric value through.
{
    no warnings qw(redefine numeric);
    my $original_run = \&Selecto::CannedPage::run;
    local *Selecto::CannedPage::run = sub {
        my $result = $original_run->(@_);
        $result->{state}{limit} = '25"><script>alert("limit")</script>';
        $result->{state}{page} = '2"><img src=x onerror=alert("page")>';
        $result->{has_more} = 1;
        return $result;
    };
    my $escaped_app = Mojolicious->new;
    $escaped_app->secrets(['canned-escaping-test']);
    $escaped_app->plugin('Selecto::Components' => {pages => {products => page_spec(0)}});
    my $e = Test::Mojo->new($escaped_app);
    $e->get_ok('/products?submitted=1&view=list')->status_is(200);
    my $body = $e->tx->res->body;
    unlike $body, qr/<script>alert\("limit"\)/, 'limit is escaped in the controls form';
    unlike $body, qr/<img src=x/, 'page is escaped in pagination text and buttons';
    like $body, qr/name="limit" value="25&quot;&gt;&lt;script&gt;/,
        'limit hidden input carries the escaped value';
    like $body, qr/<span>Page 2&quot;&gt;&lt;img/, 'current page label is escaped';
}

done_testing;
