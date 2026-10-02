use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::JSON qw(encode_json decode_json from_json);
use Mojolicious;
use Selecto;
use Selecto::Components;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# Drilldown buttons and the carried drilldown state embed JSON in HTML
# attributes. Non-ASCII facet values must survive render -> submit -> select.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
});
$dbh->do('CREATE TABLE unicode_products (id integer primary key, name text, category text)');
my $insert = $dbh->prepare('INSERT INTO unicode_products VALUES (?, ?, ?)');
$insert->execute(@$_) for
    [1, 'Espresso', 'Café'], [2, 'Watch', 'Zürich'], [3, 'Balloon', "Party \x{1F389}"],
    [4, 'Cafe sign', 'Cafe'], [5, 'Plain', 'a/b'];

sub page_spec {
    my ($private) = @_;
    my $domain = Selecto::Domain->new(
        name => 'Unicode products', table => 'unicode_products',
        fields => {id => 'integer', name => 'string', category => 'string'},
        components => {query_params => $private ? 0 : 1},
    );
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    return {
        domain => $domain, engine_factory => sub { $engine },
        path => '/products', title => 'Product Search',
        dataset => {query => $engine->query, entity_key => ['id']},
        views => [
            {id => 'list', kind => 'detail', label => 'Products',
                query => $engine->query->select('id', 'name', 'category')->order_by('id')},
            {id => 'by_category', kind => 'aggregate', label => 'By category',
                query => $engine->query->select('category',
                    Selecto::Expression->count_distinct('id')->as('items'))
                    ->group_by('category')->order_by('category')},
        ],
        controls => [],
        initial_state => {view => 'by_category'},
    };
}

sub buttons {
    my ($dom) = @_;
    return {map {
        my $value = $_->attr('value');
        (from_json($value)->{values}[0] => $value)
    } $dom->find('button[name=drilldown_select]')->each};
}

my @expected = (['Café', 'Espresso'], ['Zürich', 'Watch'],
    ["Party \x{1F389}", 'Balloon'], ['a/b', 'Plain']);
my %all_names = map { $_->[1] => 1 } @expected, ['Cafe', 'Cafe sign'];

sub only_name {
    my ($body, $name, $label) = @_;
    my @present = grep { index($body, ">$_<") >= 0 } sort keys %all_names;
    is_deeply(\@present, [$name], "$label selects exactly that value");
}

my $app = Mojolicious->new;
$app->secrets(['canned-unicode-test']);
$app->plugin('Selecto::Components' => {pages => {products => page_spec(0)}});
my $t = Test::Mojo->new($app);
$t->get_ok('/products')->status_is(200)
    ->content_type_like(qr/charset=UTF-8/i)->content_like(qr/Zürich/);
my $buttons = buttons($t->tx->res->dom);
for my $case (@expected) {
    my ($category, $name) = @$case;
    ok(exists $buttons->{$category}, "drilldown button carries $category as characters")
        or diag explain [keys %$buttons];
    my $value = $buttons->{$category} // next;
    is_deeply(from_json($value), {view => 'by_category', values => [$category]},
        "attribute JSON for $category is a single encoding");

    $t->get_ok('/products' => form => {submitted => 1, view => 'by_category',
        drilldown_select => $value})->status_is(200)
        ->content_like(qr/Clear drilldown/);
    only_name($t->tx->res->text, $name, "GET drilldown for $category");

    # The detail page carries the drilldown forward in a hidden field; paging
    # or refiltering resubmits it.
    my $carried = $t->tx->res->dom->at('input[name=drilldown]');
    ok($carried, "drilldown for $category is carried in the form") or next;
    is_deeply(from_json($carried->attr('value')),
        {view => 'by_category', values => [$category]},
        "carried drilldown for $category is a single encoding");
    $t->get_ok('/products' => form => {submitted => 1, view => 'list',
        drilldown => $carried->attr('value')})->status_is(200);
    only_name($t->tx->res->text, $name, "resubmitted drilldown for $category");

    $t->websocket_ok('/products/ws')->send_ok({text => encode_json({
        headers => {}, submitted => 1, view => 'by_category',
        drilldown_select => $value, selecto_request_id => '3',
    })})->message_ok;
    my $message = decode_json($t->message->[1]);
    only_name($message->{content}, $name, "WebSocket drilldown for $category");
    $t->finish_ok;
}

my $private = Mojolicious->new;
$private->secrets(['canned-unicode-private']);
$private->plugin('Selecto::Components' => {pages => {products => page_spec(1)}});
my $p = Test::Mojo->new($private);
$p->get_ok('/products')->status_is(200);
my $private_buttons = buttons($p->tx->res->dom);
ok(exists $private_buttons->{'Zürich'}, 'private mode renders the same characters');
$p->post_ok('/products' => form => {submitted => 1, view => 'by_category',
    drilldown_select => $private_buttons->{'Zürich'} // ''})->status_is(200);
only_name($p->tx->res->text, 'Watch', 'POST drilldown for Zürich');

done_testing;
