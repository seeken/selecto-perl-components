use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::DOM;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Actions;

my $raw = TestSelectoComponents::domain()->contract;
delete $raw->{domain_fingerprint};
$raw->{actions}{edit_one_product}{inputs} = {operation => {
    type => 'select', required => 1, options => [
        {value => 'hold', label => 'Place on hold'}, {value => 'release', label => 'Release hold'},
    ],
}};
$raw->{actions}{edit_one_product}{variants} = [
    {id => 'hold', when => {operation => 'hold'}, inputs => {reason => {type => 'string', required => 1}}},
    {id => 'release', when => {operation => 'release'}, inputs => {comment => {type => 'string'}}},
];
my $domain = Selecto::Domain->parse($raw, strict => 1);
my $options = TestSelectoComponents::config();
$options->{action_eligibility_resolvers} = {};
$options->{engine_factory} = sub { Selecto::Engine->new(domain => $domain,
    adapter => TestSelectoComponents::Adapter->new(dbh => bless({}, 'TestSelectoComponents::DBH'))) };
my (%held, @resolved, @executed);
my $deny = 0;
$options->{action_form_resolvers} = {edit_one_product => sub {
    my ($c, $request) = @_;
    push @resolved, $request->{ids}[0];
    return {fixed_inputs => {operation => $held{$request->{ids}[0]} ? 'release' : 'hold'}};
}};
$options->{action_authorizer} = sub { $deny ? 'hidden' : 'enabled' };
$options->{action_handlers}{edit_one_product} = sub {
    push @executed, $_[1]; return {ok => 1, message => 'Applied'};
};
my $app = Mojolicious->new;
$app->secrets(['target-form-test-only']);
$app->plugin('Selecto::Components' => {explorers => {products => $options}});
my $t = Test::Mojo->new($app);
$t->get_ok('/explore/products?q=1&view=detail&field=id&field=action%3Aedit_one_product')->status_is(200)
    ->element_exists('[data-sc-action-form-url="/explore/products/actions/edit_one_product/form"]')
    ->element_exists('[data-sc-action-fields]:empty');
is scalar(@resolved), 0, 'no per-row form queries while rendering results';
my $csrf = $t->tx->res->dom->at('[name="csrf_token"]')->attr('value');
my $path = '/explore/products/actions/edit_one_product/form';
$t->get_ok("$path?selected_id=101")->status_is(200)->header_is('Cache-Control' => 'private, no-store');
my $dom = Mojo::DOM->new($t->tx->res->json->{html});
ok $dom->at('input[type="hidden"][name="action_input_operation"][value="hold"]'), 'nonheld row fixes hold operation';
ok !$dom->at('select[name="action_input_operation"]'), 'no user choice of invalid operation';
$held{102} = 1;
$t->get_ok("$path?selected_id=102")->status_is(200);
$dom = Mojo::DOM->new($t->tx->res->json->{html});
ok $dom->at('input[name="action_input_operation"][value="release"]'), 'held row fixes release operation';
$t->get_ok("$path?selected_id=101")->status_is(200);
like $t->tx->res->json->{html}, qr/value="hold"/, 'different rows do not share fixed defaults';

sub post {
    my ($id, %input) = @_;
    $t->post_ok('/explore/products/actions/edit_one_product' => {Accept => 'application/json'} =>
        form => {selected_id => $id, csrf_token => $csrf, %input});
}
post(101, action_input_operation => 'release')->status_is(422);
post(101, action_input_operation => 'hold', action_input_reason => 'Investigate')->status_is(200);
is $executed[-1]{variant}, 'hold', 'valid fixed operation dispatches variant';
post(102, action_input_operation => 'hold', action_input_reason => 'Forged')->status_is(422);
post(102, action_input_operation => 'release')->status_is(200);
is $executed[-1]{variant}, 'release', 'release needs no hold reason';
$held{101} = 1;
post(101, action_input_operation => 'hold', action_input_reason => 'Stale')->status_is(422);
is scalar(@executed), 2, 'forged and stale forms never execute';
my $calls = @resolved;
$deny = 1;
$t->get_ok("$path?selected_id=101")->status_is(403);
is scalar(@resolved), $calls, 'target form lookup is not called before authorization';
$t->get_ok($path)->status_is(422);
$t->get_ok("$path?selected_id=101&selected_id=102")->status_is(422);
$t->get_ok('/explore/products/actions/missing/form?selected_id=101')->status_is(404);
$deny = 0;
$options->{action_form_resolvers}{edit_one_product} = sub { {fixed_inputs => {operation => 'forged'}} };
$t->get_ok("$path?selected_id=101")->status_is(500);
is scalar(@executed), 2, 'bad resolver result fails closed';
done_testing;
