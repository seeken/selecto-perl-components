use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Limits;
use Selecto::Components::State;
use Selecto::Components::QueryAssistant::Store;
use Selecto::Components::QueryAssistant::Store::SQLite;
use Selecto::Components::BucketParser;

my $domain = TestSelectoComponents::domain();
my $config = Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products', title => 'Products',
    limits => Selecto::Limits->new(max_fields => 3, max_filter_values => 2, max_value_bytes => 4));
for my $input (
    {q => 1, field => [('id') x 4]},
    {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_values_json => '["a","b","c"]'},
    {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_values_json => '["abcde"]'},
    {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_value => 'a,b,c'},
) {
    ok !Selecto::Components::State->from_input($config, $domain, $input)->valid, 'over-budget state is refused';
}
is_deeply(Selecto::Components::BucketParser->parse(join(',', (1) x 101)), [], 'bucket count bounded before expansion');
is_deeply(Selecto::Components::BucketParser->parse('9' x 16), [], 'bucket digits bounded before numeric coercion');

ok(Selecto::Components::State->from_input($config, $domain, {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_values_json => '["a","b"]'})->valid, 'membership at configured ceiling remains usable');

my $options = TestSelectoComponents::config();
delete $options->{websocket_mode};
my $bad = eval { Mojolicious->new->plugin('Selecto::Components' => {explorers => {products => $options}}); 1 };
ok !$bad, 'default protected sockets require explicit live authorization';
like $@, qr/protected Explorer/, 'startup failure identifies migration';
$options->{websocket_enabled} = 0;
my $off = Mojolicious->new;
$off->plugin('Selecto::Components' => {explorers => {products => $options}});
Test::Mojo->new($off)->get_ok('/explore/products')->status_is(200)->element_exists_not('[hx-ws\\:connect]');

my $dir = tempdir(CLEANUP => 1);
for my $class ('Selecto::Components::QueryAssistant::Store', 'Selecto::Components::QueryAssistant::Store::SQLite') {
    my $store = $class->new(($class =~ /SQLite/ ? (path => "$dir/quotas.sqlite") : ()), max_total_drafts => 2, max_owner_bytes => 400, max_total_bytes => 800);
    my $one = $store->create({owner => 'one'});
    $store->create({owner => 'two'});
    ok !eval { $store->create({owner => 'three'}); 1 }, "$class bounds total owners";
    my $change = $store->compare_and_swap($one->{id}, 0, {%$one, extra => 'x' x 400});
    is $change->{code}, 'limit_exceeded', "$class bounds replacement owner bytes";
    is $store->get($one->{id})->{revision}, 0, "$class rejected growth preserves revision";
    is $store->compare_and_swap($one->{id}, 0, {%$one, owner => 'another'})->{code}, 'invalid_owner', 'replacement cannot move quota ownership';
}

# A real Mojolicious receiving transaction parses HTTP chunk framing, limiting
# body retention before JSON is called. Missing embedded ingress fails closed.
my $app = Mojolicious->new;
my $spec = TestSelectoComponents::config();
my $store = Selecto::Components::QueryAssistant::Store->new;
$spec->{query_assistant} = {store => $store, actor => sub { 'actor' }};
$app->plugin('Selecto::Components' => {explorers => {products => $spec}});
my $t = Test::Mojo->new($app);
$t->ua->request_timeout(3);
$t->get_ok('/explore/products')->status_is(200);
my $csrf = $t->tx->res->dom->at('[data-sc-query-assistant]')->attr('data-sc-query-assistant-csrf');
for my $suffix ('', '/draft/sync', '/draft/tools/get_query_context') {
    my $request = $t->ua->build_tx(POST => '/explore/products/assistant/drafts'.$suffix => {
        'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf,
    });
    $request->req->content->write_chunk((' ' x 65_535).'{}')->write_chunk('');
    $t->request_ok($request)->status_is(413);
}
is scalar(keys %{$store->{records}}), 0, 'oversized raw bodies reach no draft store';
my $tx = $app->build_tx;
$tx->req->parse("POST /explore/products/assistant/drafts HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n10001\r\n" . (' ' x 65_535).'{}' . "\r\n0\r\n\r\n");
ok $tx->req->{selecto_assistant_too_large}, 'actual chunked parser rejects raw-byte excess';
cmp_ok $tx->req->body_size, '<=', 65_536, 'ingress never retains the excess chunk';
my $exact = $t->ua->build_tx(POST => '/explore/products/assistant/drafts' => {
    'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf,
});
$exact->req->content->write_chunk((' ' x 65_524).'{"input":{}}')->write_chunk('');
$t->request_ok($exact)->status_is(201);
my $encoded = $app->build_tx;
$encoded->req->parse("POST /explore/products/assistant/drafts HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}");
ok $encoded->req->{selecto_assistant_too_large}, 'compressed assistant bodies fail closed';
my $unknown = $app->build_tx;
$unknown->req->parse("POST /explore/products/assistant/drafts HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65537\r\n\r\n");
ok $unknown->req->{selecto_assistant_too_large}, 'declared excess refused before body arrives';
my $escaped_path = $app->build_tx;
$escaped_path->req->parse("POST /explore/products/%61ssistant/drafts HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65537\r\n\r\n");
ok $escaped_path->req->{selecto_assistant_too_large}, 'route-equivalent encoded paths retain the receive cap';
done_testing;
