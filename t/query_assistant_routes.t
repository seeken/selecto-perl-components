use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::QueryAssistant::Store;
use Selecto::Engine;

{
    package TestQueryAssistantRouteAdapter;
    use Mojo::Base 'TestSelectoComponents::Adapter', -signatures;
    our $EXECUTIONS = 0;
    sub execute_query ($self, @args) {
        $EXECUTIONS++;
        return $self->SUPER::execute_query(@args);
    }
}

{
    package TestQueryAssistantFailingStore;
    our @ISA = ('Selecto::Components::QueryAssistant::Store');
    our $FAIL = 0;
    sub compare_and_swap {
        die "private storage failure: UPDATE selecto_query_drafts with credential=secret\n" if $FAIL;
        return shift->SUPER::compare_and_swap(@_);
    }
}
my $store = TestQueryAssistantFailingStore->new;
my $spec = TestSelectoComponents::config();
my $route_domain = TestSelectoComponents::domain();
$spec->{path} = '/explore/assistant-products';
$spec->{engine_factory} = sub {
    return Selecto::Engine->new(
        domain => $route_domain,
        adapter => TestQueryAssistantRouteAdapter->new(
            dbh => bless({}, 'TestSelectoComponents::DBH'),
        ),
    );
};
$spec->{query_assistant} = {
    store => $store,
    actor => sub { return 'route-test-actor' },
    choice_fields => {'category.category_name' => 1},
    choice_resolver => sub {
        my ($controller, $request) = @_;
        return [{value => 'Beverages', label => 'Beverages'}];
    },
};
my $app = Mojolicious->new;
$app->secrets(['assistant-route-test']);
$app->plugin('Selecto::Components' => {explorers => {
    assistant_products => $spec,
    other_products => {%$spec, path => '/explore/other-products'},
}});
my $t = Test::Mojo->new($app);

$t->get_ok('/explore/assistant-products')->status_is(200)
    ->element_exists('[data-sc-query-assistant][data-sc-query-assistant-csrf]')
    ->element_exists('[data-sc-query-assistant-status]')
    ->element_exists('[data-sc-query-assistant-undo][hidden]');
my $csrf = $t->tx->res->dom->at('[data-sc-query-assistant]')->attr('data-sc-query-assistant-csrf');
ok $csrf, 'page publishes its session CSRF token only to the same-origin assistant adapter';
$TestQueryAssistantRouteAdapter::EXECUTIONS = 0;

$t->post_ok('/explore/assistant-products/assistant/drafts' =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} =>
        json => {input => {}})
    ->status_is(201)->json_is('/ok' => 1)->json_is('/revision' => 0);
is $TestQueryAssistantRouteAdapter::EXECUTIONS, 0,
    'draft bootstrap does not execute the report or count query';
my $bootstrap = $t->tx->res->json;
my $draft_id = $bootstrap->{draft_id};

$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/get_query_context" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} =>
        json => {draft_id => $draft_id})
    ->status_is(200)->json_is('/ok' => 1)->json_is('/active_target/view' => 'detail')
    ->json_is('/graph/point_limit/maximum' => 100);
is $TestQueryAssistantRouteAdapter::EXECUTIONS, 0, 'context lookup performs no report query';
my $context_version = $t->tx->res->json->{context_version};

my $target = {
    view => 'graph', filters => [],
    groups => [{field => 'category.category_name'}],
    measures => [{
        id => 'total_price', function => 'sum', alias => 'Revenue',
        null_handling => 'auto', series_id => 'revenue', chart_type => 'bar',
        axis => 'left', stack => undef, color => '#123456', transforms => [],
    }],
    graph => {chart_type => 'bar', show_table => 1}, limit => 100,
};
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/apply_query_draft" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, base_revision => 0, context_version => $context_version,
            request_id => 'route-apply-1', target => $target,
        })
    ->status_is(200)->json_is('/ok' => 1)->json_is('/revision' => 1)
    ->json_like('/builder_html' => qr/data-sc-builder/)
    ->json_like('/builder_html' => qr/name="measure_color" value="#123456"/)
    ->json_like('/builder_html' => qr/data-sc-builder-collapsed="false"/)
    ->json_like('/builder_html' => qr/name="saved_query_url" value="\/explore\/assistant-products\?/)
    ->json_like('/builder_html' => qr/type="submit"[^>]*>Run query/);
is $TestQueryAssistantRouteAdapter::EXECUTIONS, 0,
    'applying and rendering the draft executes no report query';

$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/apply_query_draft" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, base_revision => 0, context_version => $context_version,
            request_id => 'route-apply-stale', target => $target,
        })
    ->status_is(409)->json_is('/code' => 'revision_conflict');

$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/search_choices" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, field => 'category.category_name', text => 'Bev', limit => 5,
        })
    ->status_is(200)->json_is('/items/0/value' => 'Beverages');
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/search_choices" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, field => 'product_name', text => 'Test', limit => 5,
        })
    ->status_is(422)->json_is('/code' => 'choice_unavailable');

my $choice_target = {
    view => 'detail', fields => [{field => 'product_name'}], orders => [], limit => 25,
    filters => [{field => 'category.category_name', operator => 'eq', value => 'Revoked'}],
};
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/validate_query_target" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, base_revision => 1, context_version => $context_version,
            target => $choice_target,
        })
    ->status_is(422)->json_is('/code' => 'choice_unavailable');

$t->post_ok('/explore/assistant-products/assistant/drafts' =>
        {'Content-Type' => 'application/json'} => json => {input => {}})
    ->status_is(403)->json_is('/code' => 'csrf_failed');
$t->post_ok('/explore/assistant-products/assistant/drafts' =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf,
         Origin => 'https://attacker.example'} => json => {input => {}})
    ->status_is(403)->json_is('/code' => 'origin_not_allowed');


$t->post_ok("/explore/other-products/assistant/drafts/$draft_id/sync" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            base_revision => 1, input => {},
        })
    ->status_is(403)->json_is('/code' => 'forbidden');
is $store->get($draft_id)->{revision}, 1, 'another explorer cannot synchronize this draft';

for my $bad (0.5, -1, 'revision') {
    $t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/validate_query_target" =>
            {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
                draft_id => $draft_id, base_revision => $bad, context_version => $context_version,
                target => $target,
            })
        ->status_is(400)->json_is('/code' => 'invalid_arguments');
}
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/search_choices" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, field => 'category.category_name', text => '', limit => 0,
        })
    ->status_is(400)->json_is('/code' => 'invalid_arguments');

# Storage exceptions stay behind the generic JSON error boundary for every mutation.
$TestQueryAssistantFailingStore::FAIL = 1;
for my $tool (qw(apply_query_draft undo_query_draft)) {
    my $payload = $tool eq 'apply_query_draft' ? {
        draft_id => $draft_id, base_revision => 1, context_version => $context_version,
        request_id => 'failing-storage', target => {
            view => 'detail', fields => [{field => 'product_name'}], orders => [], filters => [], limit => 25,
        },
    } : {
        draft_id => $draft_id, base_revision => 1, undo_token => $store->get($draft_id)->{undo}{token},
    };
    $t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/$tool" =>
            {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => $payload)
        ->status_is(503)->json_is('/code' => 'temporarily_unavailable')
        ->content_unlike(qr/private storage|UPDATE selecto_query_drafts|credential=secret/);
}
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/sync" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            base_revision => 1, input => {},
        })
    ->status_is(503)->json_is('/code' => 'temporarily_unavailable')
    ->content_unlike(qr/private storage|UPDATE selecto_query_drafts|credential=secret/);
$TestQueryAssistantFailingStore::FAIL = 0;
is $store->get($draft_id)->{revision}, 1, 'storage failures leave the draft revision unchanged';

# A new trusted required predicate is a different authorization context even
# for the same actor and explorer. It invalidates the old draft for every path.
$route_domain = $route_domain->with_required_predicate(Selecto::Expression->gt('id', 100));
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/sync" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            base_revision => 1, input => {},
        })
    ->status_is(409)->json_is('/code' => 'context_changed');
$t->post_ok("/explore/assistant-products/assistant/drafts/$draft_id/tools/undo_query_draft" =>
        {'Content-Type' => 'application/json', 'X-CSRF-Token' => $csrf} => json => {
            draft_id => $draft_id, base_revision => 1, undo_token => $store->get($draft_id)->{undo}{token},
        })
    ->status_is(409)->json_is('/code' => 'context_changed');
is $store->get($draft_id)->{revision}, 1, 'rejected scope changes leave the draft intact';

done_testing;
