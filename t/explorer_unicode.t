use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::JSON qw(decode_json encode_json from_json to_json);
use Mojo::URL ();
use Mojolicious;
use Selecto;
use Selecto::Components;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# JSON the Explorer embeds in HTML attributes, permalinks, and text exports is
# a character string; the page and export encoders add the single UTF-8 layer.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
});
$dbh->do('CREATE TABLE places (id integer primary key, name text, city text)');
my $insert = $dbh->prepare('INSERT INTO places VALUES (?, ?, ?)');
$insert->execute(@$_) for [1, 'Espresso', 'Café'], [2, 'Watch', 'Zürich'],
    [3, 'Balloon', "Party \x{1F389}"], [4, 'Sign', 'Cafe'];

my $domain = Selecto::Domain->new(
    name => 'Places', table => 'places',
    fields => {id => 'integer', name => 'string', city => 'string'},
    components => {filter_choices => {name => {label => 'Name', choices => [
        {value => 'Watch', label => 'Zürich watch'}, {value => 'Balloon', label => "Party \x{1F389}"},
    ]}}},
);
my $app = Mojolicious->new;
$app->secrets(['explorer-unicode-test']);
$app->plugin('Selecto::Components' => {websocket_mode => 'public',explorers => {places => {
    path => '/places', title => 'Places',
    engine_factory => sub {
        Selecto::Engine->new(domain => $domain,
            adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    },
    default_fields => [qw(id name city)],
}}});
my $t = Test::Mojo->new($app);

my @membership = (q => 1, view => 'detail', field => [qw(id name city)],
    filter_field => 'city', filter_op => 'in', filter_value => '',
    # A browser submits the JSON text as characters.
    filter_values_json => to_json(['Café', "Party \x{1F389}"]), filter_value_end => '', filter_group => 0,
    filter_clause => '');

sub names {
    my ($html) = @_;
    return [grep { index($html, ">$_<") >= 0 } qw(Balloon Espresso Sign Watch)];
}

$t->get_ok('/places' => form => {@membership})->status_is(200)
    or diag $t->tx->res->dom->find('.sc-error, [role=alert], .sc-alert')->map('all_text')->join("; ");
is_deeply(names($t->tx->res->text), [qw(Balloon Espresso)],
    'a non-ASCII membership filter submitted as characters selects exactly those rows');
my $dom = $t->tx->res->dom;
my ($carried) = grep { length($_->attr('value') // $_->text) }
    $dom->find('[name=filter_values_json]')->each;
ok($carried, 'the membership filter is carried in the builder form') and
    is_deeply(from_json($carried->attr('value') // $carried->text),
        ['Café', "Party \x{1F389}"], 'carried membership JSON is a single encoding');
my $choices = $dom->at('[data-sc-filter-choices]');
ok($choices, 'the name filter advertises its choices') and
    like($choices->attr('data-sc-filter-choices'), qr/"Zürich watch"/,
        'filter-choice data attribute holds characters, not UTF-8 bytes');

my $permalink = $dom->find('a[href*="filter_values_json"]')->first;
ok($permalink, 'a permalink carries the membership filter') and do {
    my $url = Mojo::URL->new($permalink->attr('href'));
    is_deeply(from_json($url->query->param('filter_values_json')),
        ['Café', "Party \x{1F389}"], 'permalink JSON is a single encoding');
    $t->get_ok($url->to_string)->status_is(200);
    is_deeply(names($t->tx->res->text), [qw(Balloon Espresso)],
        'following the permalink selects the same rows');
};

$t->get_ok('/places' => form => {@membership, format => 'json'})->status_is(200);
my $export = decode_json($t->tx->res->body);
is_deeply([sort map { $_->{City} // $_->{city} } @{$export->{rows}}],
    ['Café', "Party \x{1F389}"], 'JSON export is UTF-8 encoded once');

$t->websocket_ok('/places/ws')->send_ok({text => encode_json({
    headers => {}, @membership, selecto_request_id => '5',
})})->message_ok;
my $message = decode_json($t->message->[1]);
my $content = join '', map { $_->{content} // '' }
    ref($message) eq 'ARRAY' ? @$message : ($message);
is_deeply(names($content), [qw(Balloon Espresso)],
    'a non-ASCII WebSocket submission selects exactly those rows')
    or diag substr(encode_json($message), 0, 400);
$t->finish_ok;

done_testing;
