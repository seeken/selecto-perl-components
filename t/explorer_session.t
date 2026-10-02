use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(encode_json decode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::ExplorerSession;

my $now = 100;
my $session = Selecto::Components::ExplorerSession->new(
    clock => sub { $now }, ttl => 10, max_bytes => 200, max_entries => 2,
);
$session->bind_scope('alice:tenant-one');
my $input = $session->prepare({field => ['id'], page => 1});
is $session->commit($input), 1, 'successful state has a revision';
my $patched = $session->prepare({}, {revision => 1, set => {page => 2}, remove => []});
is_deeply $patched, {field => ['id'], page => 2}, 'page change keeps existing selections';
ok !defined $session->prepare({}, {revision => 0, set => {}, remove => []}),
    'stale revisions require a full snapshot';
my $removed = $session->prepare({}, {revision => 1, set => {}, remove => ['field']});
ok !exists $removed->{field}, 'removed fields are not retained';
my $raw = {columns => ['id'], rows => [[42]]};
$session->store(one => $raw);
$session->fetch('one')->{result}{rows}[0][0] = 99;
is $session->fetch('one')->{result}{rows}[0][0], 42, 'rendering cannot mutate retained results';
$session->store(two => $raw);
$session->store(three => $raw);
ok !defined $session->fetch('one'), 'oldest entry is evicted at entry limit';
$now += 10;
ok !defined $session->fetch('two'), 'expired results are not reused';
$session->store(large => {columns => ['x'], rows => [['x' x 201]]});
ok !defined $session->fetch('large'), 'oversized results are not retained';
$session->bind_scope('bob:tenant-two');
ok !defined $session->input, 'identity changes discard saved state';
is $session->bytes, 0, 'identity changes discard results';
$session->store(one => $raw);
$session->bind_domain('new-domain');
is $session->bytes, 0, 'domain changes invalidate results';

my ($allowed, $actor, $checks) = (1, 'alice', 0);
my $app = Mojolicious->new;
$app->secrets(['explorer-session-test']);
my $config = TestSelectoComponents::config();
$config->{websocket_mode} = 'protected';
$config->{websocket_context} = sub { $checks++; return $allowed ? $actor : undef };
$app->plugin('Selecto::Components' => {explorers => {products => $config}});
my $t = Test::Mojo->new($app);
my $full = {headers => {}, selecto_request_id => 'one', q => 1,
    view => 'graph', field => ['product_name'], group => ['category.category_name'],
    measure => 'total_price', limit => 25, page => 1};
$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json($full)})->message_ok;
my $first = decode_json($t->message->[1]);
is $first->{selecto}{session}{revision}, 1, 'socket acknowledges initial full state';
my $executions = $TestSelectoComponents::Adapter::COUNT_EXECUTIONS;
$t->send_ok({text => encode_json({headers => {}, selecto_request_id => 'two',
    selecto_session => {revision => 1, set => {measure_color => '#aa0000'}, remove => []}})})->message_ok;
my $second = decode_json($t->message->[1]);
is $second->{selecto}{session}{revision}, 2, 'socket accepts presentation patch';
is $second->{selecto}{session}{cache_hit}, 1, 'presentation change reuses compiled results';
is $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, $executions, 'count did not execute again';
is $checks, 2, 'authorization runs even on cache hit';
$t->send_ok({text => encode_json({headers => {}, selecto_request_id => 'invalid',
    selecto_session => {revision => 2, set => {field => ['does_not_exist']}, remove => []}})})->message_ok;
my $invalid = decode_json($t->message->[1]);
is $invalid->{selecto}{session}{accepted}, 0, 'invalid selections do not replace saved state';
is $invalid->{selecto}{session}{revision}, 2, 'invalid selections do not advance the revision';
$t->send_ok({text => encode_json({headers => {}, selecto_request_id => 'stale',
    selecto_session => {revision => 1, set => {page => 2}, remove => []}})})->message_ok;
ok decode_json($t->message->[1])->{selecto}{session}{resync}, 'stale patch requests resynchronization';
is $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, $executions, 'stale patch executes no query';
$t->send_ok({text => encode_json({%$full, selecto_refresh => 1})})->message_ok;
cmp_ok $TestSelectoComponents::Adapter::COUNT_EXECUTIONS, '>', $executions, 'refresh executes fresh SQL';
$actor = 'bob';
$t->send_ok({text => encode_json({headers => {},
    selecto_session => {revision => 3, set => {page => 2}, remove => []}})})->message_ok;
ok decode_json($t->message->[1])->{selecto}{session}{resync}, 'changed identity cannot reuse prior state';
$allowed = 0;
$t->send_ok({text => encode_json($full)})->finished_ok(1008);
$allowed = 1;
$t->websocket_ok('/explore/products/ws')->send_ok({text => encode_json({headers => {},
    selecto_session => {revision => 3, set => {}, remove => []}})})->message_ok;
ok decode_json($t->message->[1])->{selecto}{session}{resync}, 'reconnect requests the complete view';
$t->send_ok({text => encode_json($full)})->message_ok;
is decode_json($t->message->[1])->{selecto}{session}{revision}, 1, 'full snapshot restores reconnected view';
$t->finish_ok;
done_testing;
