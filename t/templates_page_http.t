use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Mojo::IOLoop;
use Mojolicious;
use Storable qw(dclone);
use Test::More;
use Test::Mojo;
use TestSelectoComponents ();
use Selecto::Components::Templates::InstanceStore::Memory ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Templates::Transport ();

my $now = 1_000;
my $owner = {actor_id => 'alice', tenant_id => 7};
my $scope = {
    tenant_id => '7', principal_id => 'alice',
    authorization_revision => 'acl-1', membership_revision => 'orders-1',
};
my $manifest = dclone(TestSelectoComponents::template_order_manifest());
$manifest->{sources}[0]{query}{collections} = [{
    id => 'lines', page_size => 1, max_items => 2,
    collections => [],
}];
my $registry = {
    components => {
        SearchInput => sub {
            return Selecto::Components::Templates::Renderer->safe_html('<div>Search</div>');
        },
        OrderTable => sub {
            return Selecto::Components::Templates::Renderer->safe_html('<div>Orders</div>');
        },
    },
    elements => {},
    include => sub {
        return Selecto::Components::Templates::Renderer->safe_html('<div>Editor</div>');
    },
};
my $secret = 'p' x 32;
my $template = {
    title => 'Paged orders', release_id => 'page-http-v1',
    manifest => $manifest, registry => $registry,
    page_secret => $secret,
    resolve_page_scope => sub { return $scope },
    source_authorizer => sub { die 'fake worker must not authorize' },
};
my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
    clock => sub { $now }, id_generator => sub { 'page-http-1' },
);
my $scheduler = PageHTTPScheduler->new;
my $app = Mojolicious->new;
$app->secrets(['page-http-test-secret']);
$app->plugin('Selecto::Components::Templates' => {
    store => $store, clock => sub { $now },
    resolve_owner => sub {
        my ($controller) = @_;
        return {status => 'unauthenticated'}
            unless ($controller->req->headers->header('X-Test-Actor') // '') eq 'alice';
        return {status => 'ok', owner_scope => $owner};
    },
    source_scheduler => $scheduler,
    templates => {paged_orders => $template},
    install_assets => 0,
});
my $transport = Selecto::Components::Templates::Transport->new(
    template_path => '/templates', instance_path => '/template-instances',
    event_id_generator => sub { 'page-event-1' }, clock => sub { $now },
);
$app->routes->get('/test/page-ready')->to(cb => sub {
    my ($controller) = @_;
    my $loaded = $store->load(owner_scope => $owner, instance_id => 'page-http-1');
    return $transport->respond_snapshot(
        $controller, template => $template,
        snapshot => $loaded->{snapshot}, store_revision => $loaded->{revision},
    );
});

my $t = Test::Mojo->new($app);
my $headers = {'X-Test-Actor' => 'alice'};
$t->get_ok('/templates/paged_orders' => $headers)->status_is(200);
my $loaded = $store->load(owner_scope => $owner, instance_id => 'page-http-1');
is $loaded->{status}, 'ok', 'page test mounted an owner-scoped instance';
my $ready = dclone($loaded->{snapshot});
$ready->{sources}{orders} = {
    status => 'ready', generation => 1, page => 1,
    result => {
        rows => [], identities => [],
        pages => [{
            collection_path => ['lines'], parent_path => [1],
            has_more => JSON::PP::true, after_values => [11],
        }],
    },
    error => undef,
};
my $stored = $store->compare_and_set(
    owner_scope => $owner, instance_id => 'page-http-1',
    revision => $loaded->{revision}, next_snapshot => $ready,
);
is $stored->{status}, 'ok', 'ready page result was stored';

$t->get_ok('/test/page-ready' => $headers)->status_is(200)
    ->element_exists('form.selecto-template-page button');
my $form = $t->tx->res->dom->at('form.selecto-template-page');
my $csrf = $form->at('input[name="csrf_token"]')->attr('value');
my $cursor = $form->at('input[name="page_cursor"]')->attr('value');
like $cursor, qr/\Apc1\.[0-9]+\.[0-9a-f]{64}\z/,
    'rendered page control contains only an opaque cursor';
unlike $t->tx->res->body, qr/after_values|parent_path|row_keys/,
    'private page positions are absent from browser HTML';

my $path = '/template-instances/page-http-1/pages/orders';
$t->post_ok($path => $headers => form => {
    csrf_token => 'forged', page_cursor => $cursor,
})->status_is(403)->element_exists('[data-selecto-template-error="invalid_csrf"]');
$t->post_ok($path => $headers => form => {
    csrf_token => $csrf, page_cursor => $cursor, query => 'select *',
})->status_is(422)->element_exists('[data-selecto-template-error="invalid_page_params"]');
$t->post_ok($path => {'X-Test-Actor' => 'bob'} => form => {
    csrf_token => $csrf, page_cursor => $cursor,
})->status_is(401);

$t->post_ok($path => $headers => form => {
    csrf_token => $csrf, page_cursor => $cursor,
})->status_is(200)->header_is('X-Selecto-Source' => 'orders');
my $advanced = $store->load(owner_scope => $owner, instance_id => 'page-http-1');
is $advanced->{snapshot}{sources}{orders}{page}, 2,
    'page POST committed the next page through the guarded runtime';
is $advanced->{snapshot}{sources}{orders}{result}{rows}[0]{id}, 1,
    'page POST stored the executor result';
$t->get_ok('/test/page-ready' => $headers)->status_is(200);
my $next_form = $t->tx->res->dom->at('form.selecto-template-page');
my $next_csrf = $next_form->at('input[name="csrf_token"]')->attr('value');
my $next_cursor = $next_form->at('input[name="page_cursor"]')->attr('value');
$scheduler->{before_finish} = sub {
    my $current = $store->load(
        owner_scope => $owner, instance_id => 'page-http-1',
    );
    my $newer = dclone($current->{snapshot});
    $newer->{sources}{orders}{page}++;
    my $saved = $store->compare_and_set(
        owner_scope => $owner, instance_id => 'page-http-1',
        revision => $current->{revision}, next_snapshot => $newer,
    );
    die 'concurrent page update failed' unless $saved->{status} eq 'ok';
};
$t->post_ok($path => $headers => form => {
    csrf_token => $next_csrf, page_cursor => $next_cursor,
})->status_is(409)->element_exists('[data-selecto-template-error="stale_page_commit"]');
is $store->load(owner_scope => $owner, instance_id => 'page-http-1')
    ->{snapshot}{sources}{orders}{page}, 3,
    'stale page POST leaves the newer page intact';

$scheduler->{before_finish} = undef;
my $latest = $store->load(owner_scope => $owner, instance_id => 'page-http-1');
my $two_parent = dclone($latest->{snapshot});
$two_parent->{sources}{orders}{page} = 1;
$two_parent->{sources}{orders}{result} = {
    rows => [
        {id => 1, order_number => 'PO-1', lines => [{id => 11}]},
        {id => 2, order_number => 'PO-2', lines => [{id => 21}]},
    ],
    identities => [],
    pages => [
        {collection_path => ['lines'], parent_path => [1],
            has_more => JSON::PP::true, after_values => [11]},
        {collection_path => ['lines'], parent_path => [2],
            has_more => JSON::PP::true, after_values => [21]},
    ],
};
is $store->compare_and_set(
    owner_scope => $owner, instance_id => 'page-http-1',
    revision => $latest->{revision}, next_snapshot => $two_parent,
)->{status}, 'ok', 'two-parent page snapshot was stored';

$t->get_ok('/test/page-ready' => $headers)->status_is(200);
my $two_forms = $t->tx->res->dom->find('form.selecto-template-page');
is $two_forms->size, 2, 'both parent page controls are rendered';
my $first_parent_cursor = $two_forms->[0]->at('input[name="page_cursor"]')->attr('value');
my $second_parent_cursor = $two_forms->[1]->at('input[name="page_cursor"]')->attr('value');
my $page_csrf = $two_forms->[0]->at('input[name="csrf_token"]')->attr('value');
isnt $first_parent_cursor, $second_parent_cursor,
    'different parents receive different opaque cursors';
$scheduler->{make_result} = sub {
    my ($payload) = @_;
    my $result = dclone($payload->{page_snapshot}{sources}{orders}{result});
    my $parent = $payload->{page_cursor} eq $first_parent_cursor ? 0
        : $payload->{page_cursor} eq $second_parent_cursor ? 1 : die 'unexpected cursor';
    push @{$result->{rows}[$parent]{lines}}, {id => $parent ? 22 : 12};
    $result->{pages}[$parent]{has_more} = JSON::PP::false;
    $result->{pages}[$parent]{after_values} = undef;
    return $result;
};
$t->post_ok($path => $headers => form => {
    csrf_token => $page_csrf, page_cursor => $first_parent_cursor,
})->status_is(200);
my $after_first_parent = $store->load(
    owner_scope => $owner, instance_id => 'page-http-1',
)->{snapshot}{sources}{orders};
is_deeply [map { $_->{id} } @{$after_first_parent->{result}{rows}[0]{lines}}],
    [11, 12], 'first parent gained its requested row';
is_deeply [map { $_->{id} } @{$after_first_parent->{result}{rows}[1]{lines}}],
    [21], 'second parent retained its first page';
is $after_first_parent->{page}, 2, 'first parent page committed';

$t->get_ok('/test/page-ready' => $headers)->status_is(200);
my $remaining_forms = $t->tx->res->dom->find('form.selecto-template-page');
is $remaining_forms->size, 1, 'only the second parent retains a page control';
my $remaining_cursor = $remaining_forms->[0]->at('input[name="page_cursor"]')->attr('value');
is $remaining_cursor, $second_parent_cursor,
    'the untouched parent cursor remains valid after another parent advances';
my $remaining_csrf = $remaining_forms->[0]->at('input[name="csrf_token"]')->attr('value');
$t->post_ok($path => $headers => form => {
    csrf_token => $remaining_csrf, page_cursor => $remaining_cursor,
})->status_is(200);
my $after_both_parents = $store->load(
    owner_scope => $owner, instance_id => 'page-http-1',
)->{snapshot}{sources}{orders};
is_deeply [map { $_->{id} } @{$after_both_parents->{result}{rows}[0]{lines}}],
    [11, 12], 'second parent advance retained the first parent rows';
is_deeply [map { $_->{id} } @{$after_both_parents->{result}{rows}[1]{lines}}],
    [21, 22], 'second parent gained its requested row';
is $after_both_parents->{page}, 3, 'second parent page committed';
$t->get_ok('/test/page-ready' => $headers)->status_is(200);
is $t->tx->res->dom->find('form.selecto-template-page')->size, 0,
    'no further page controls are rendered after both parents finish';

done_testing;

package PageHTTPScheduler;

sub new { return bless {}, $_[0] }

sub execute {
    my ($self, %args) = @_;
    Mojo::IOLoop->next_tick(sub {
        my $result = $self->{make_result}
            ? $self->{make_result}->($args{payload})
            : Storable::dclone(
                $args{payload}{page_snapshot}{sources}{orders}{result},
            );
        unless ($self->{make_result}) {
            $result->{rows} = [{id => 1, order_number => 'PO-1'}];
            $result->{pages}[0]{after_values} = [12];
        }
        $self->{before_finish}->() if $self->{before_finish};
        $args{on_finish}->({status => 'ok', result => $result});
    });
    return {status => 'scheduled'};
}
