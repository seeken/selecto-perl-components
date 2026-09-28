use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::DOM;
use JSON::PP ();
use Storable qw(dclone);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Actions;
use Selecto::Components::Renderer::Results;

my $raw = TestSelectoComponents::domain()->contract;
delete $raw->{fingerprint};
$raw->{actions}{edit_one_product}{inputs} = {
    complete => {type => 'boolean', required => 1, discriminator => 1, default => JSON::PP::false},
    note => {type => 'string', required => 1, label => 'Base note'},
    timestamp => {type => 'utc_datetime', required => 1, default => ['system', 'now']},
};
$raw->{actions}{edit_one_product}{variants} = [
    {id => 'ready', label => 'Ready', when => {complete => JSON::PP::true}, inputs => {
        note => {type => 'string', required => 0, label => 'Optional note', default => 'Ready to go'},
        reviewer => {type => 'lookup', lookup_source => 'people'},
    }},
    {id => 'follow_up', label => 'Follow up', description => 'Explain the missing documents.',
        when => {complete => JSON::PP::false}, inputs => {
            reason => {type => 'string', required => 1, label => 'Reason'},
            documents => {type => 'collection', min_items => 1, max_items => 3, label => 'Documents'},
        }},
];
my $domain = Selecto::Domain->parse($raw, strict => 1);
my @executed;
my $denied = 0;
my $options = TestSelectoComponents::config();
$options->{engine_factory} = sub { Selecto::Engine->new(domain => $domain,
    adapter => TestSelectoComponents::Adapter->new(dbh => bless({}, 'TestSelectoComponents::DBH'))) };
$options->{action_handlers}{edit_one_product} = sub {
    my ($controller, $request) = @_;
    push @executed, $request;
    return {ok => 1, message => 'Saved'};
};
$options->{action_authorizer} = sub { return $denied ? 'hidden' : 'enabled' };
$options->{lookup_sources}{people} = sub { [{value => 7, label => 'Reviewer'}] };
my $config = Selecto::Components::Config->new(%$options, id => 'products');
my $action = Selecto::Components::Actions->definition($config, $domain, undef, 'edit_one_product');
is $action->{inputs}[0]{type}, 'boolean', 'boolean retains its type';
ok $action->{inputs}[0]{discriminator}, 'discriminator metadata retained';
is $action->{variants}[1]{inputs}[0]{type}, 'collection', 'variant inputs normalized';
my $request = sub { Selecto::Components::Actions->request($config, $action, [101], $_[0], $_[1]) };
my $result = $request->({complete => 'true'});
ok $result->{valid}, 'variant overrides required base input';
is $result->{variant}, 'ready', 'server returns selected variant';
is $result->{inputs}{note}, 'Ready to go', 'literal defaults applied';
ok JSON::PP::is_bool($result->{inputs}{complete}), 'handler receives typed boolean';
ok !exists($result->{inputs}{timestamp}), 'system default is left to the governed executor';
ok $request->({complete => 1, timestamp => ''})->{valid}, 'blank server-default field does not block submission';
ok $request->({complete => 1, timestamp => '2026-09-28T12:30:00Z'})->{valid}, 'explicit ISO timestamp accepted';
ok !$request->({complete => 1, timestamp => '2026-02-30T28:30:00Z'})->{valid}, 'invalid calendar/time rejected';
$result = $request->({note => 'n'});
ok !$result->{valid}, 'false default requires follow-up fields';
like join(' ', @{$result->{errors}}), qr/Reason is required/, 'missing variant field named';
$result = $request->({complete => 'false', note => 'n', reason => 'r', documents => '[{"name":"A"}]'}, {form_encoded => 1});
ok $result->{valid}, 'HTML collection JSON accepted';
is_deeply $result->{inputs}{documents}, [{name => 'A'}], 'collection decoded';
for my $bad ('bad JSON', 'null', '{}', '[]', '[1,2,3,4]') {
    ok !$request->({complete => 0, note => 'n', reason => 'r', documents => $bad}, {form_encoded => 1})->{valid},
        "invalid collection $bad rejected";
}
ok !$request->({complete => 1, reason => 'stale'})->{valid}, 'inactive variant field rejected';
ok !$request->({complete => 1, variant => 'follow_up'})->{valid}, 'variant id spoof rejected';
ok !$request->({complete => 1, note => {sql => 'bad'}})->{valid}, 'unexpected reference rejected';
ok !$request->({complete => 0, note => 'n', reason => 'r', documents => '[1]'})->{valid}, 'API requires typed arrays';
ok $request->({complete => JSON::PP::false, note => 'n', reason => 'r', documents => [1]})->{valid}, 'API native values accepted';
my $ambiguous = dclone($action);
$ambiguous->{variants}[1]{when} = $ambiguous->{variants}[0]{when};
like join(' ', @{Selecto::Components::Actions->input_form($ambiguous, {complete => 1})->{errors}}),
    qr/more than one/, 'ambiguity reported clearly';

my $html = Selecto::Components::Renderer::Results::_action_inputs($action);
my $dom = Mojo::DOM->new($html);
ok $dom->at('[data-sc-action-variants]'), 'renderer publishes variant metadata';
is $dom->find('fieldset[data-sc-action-variant][hidden][disabled]')->size, 2, 'inactive fields initially inert';
ok $dom->at('[name="action_input_complete"] option[value="false"][selected]'), 'false default shown as No';
ok $dom->at('[data-sc-action-variant="follow_up"] [name="action_input_reason"][required]'), 'required variant marked';
ok $dom->at('[data-sc-action-variant-status][role="status"]'), 'accessible form status';
ok $dom->at('textarea[name="action_input_documents"]'), 'collection uses JSON editor';
ok !$dom->at('[name="action_input_timestamp"][required]'), 'server-owned default is not required in browser';

my $app = Mojolicious->new;
$app->secrets(['variant-test-only']);
$app->plugin('Selecto::Components' => {explorers => {products => $options}});
my $t = Test::Mojo->new($app);
$t->get_ok('/explore/products?q=1&view=detail&field=id&field=action%3Aedit_one_product')->status_is(200);
my $csrf = $t->tx->res->dom->at('[name="csrf_token"]')->attr('value');
$t->get_ok('/explore/products/records/101/edit?editor=product_profile')->status_is(200)
    ->element_exists('[data-sc-record-editor-action-form] [data-sc-action-variants]')
    ->element_exists('[data-sc-record-editor-action-form] [data-sc-action-variant="follow_up"] [name="action_input_reason"][required]');
my $inline = Mojo::DOM->new(Selecto::Components::Renderer::Results::_row_inline_action(
    {config => $config, canonical_url => '/explore/products'}, $action, 101, 1,
));
ok $inline->at('[data-sc-action-variants]'), 'inline row forms share variant rendering';
sub post_action {
    my ($fields) = @_;
    return $t->post_ok('/explore/products/actions/edit_one_product' => {Accept => 'application/json'} =>
        form => {csrf_token => $csrf, selected_id => 101, %$fields});
}
post_action({action_input_complete => 'true'})->status_is(200);
is $executed[-1]{variant}, 'ready', 'HTTP action dispatch receives selected variant';
post_action({action_input_complete => 'false', action_input_note => 'n'})->status_is(422)
    ->json_like('/message' => qr/Reason is required/);
post_action({action_input_complete => 'false', action_input_note => 'n', action_input_reason => 'r', action_input_documents => '[1]'})
    ->status_is(200);
is_deeply $executed[-1]{inputs}{documents}, [1], 'HTTP form collection decoded';
post_action({action_input_complete => 'true', action_input_reason => 'stale'})->status_is(422);
post_action({action_input_complete => ['true', 'false']})->status_is(422);
my $lookup = '/explore/products/actions/edit_one_product/lookups/reviewer?q=review&action_input_complete=';
$t->get_ok($lookup . 'true')->status_is(200)->json_is('/results/0/value' => '7');
$t->get_ok($lookup . 'false')->status_is(404);
$denied = 1;
post_action({action_input_complete => 'true'})->status_is(403);
$t->get_ok($lookup . 'true')->status_is(404);
is scalar(@executed), 2, 'only valid and authorized actions reach the handler';
done_testing;
