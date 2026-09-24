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
use Selecto::Components::Templates::RootCursor ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

my $fixture = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-root-page.compile.json";
open my $handle, '<:raw', $fixture or die "cannot read $fixture: $!";
my $manifest = JSON::PP->new->utf8->decode(do { local $/; <$handle> });
close $handle;
delete $manifest->{sources}[0]{query}{page};

my $now = 1_000;
my $owner = {actor_id => 'alice', tenant_id => 7};
my $scope = {
    tenant_id => '7', principal_id => 'alice',
    authorization_revision => 'acl-1', membership_revision => 'orders-1',
};
my $catalog = TestSelectoComponents::template_domain_catalog();
my $dbh = RootPageHTTPDBH->new;
my @queries;
my $authorization_calls = 0;
my $template = {
    title => 'Root pages', release_id => 'root-http-v1', manifest => $manifest,
    registry => {components => {}, elements => {}, include => sub {
        return Selecto::Components::Templates::Renderer->safe_html('');
    }},
    page_secret => 'r' x 32,
    root_cursor_sources => ['orders'],
    resolve_page_scope => sub { return $scope },
    source_authorizer => sub {
        my ($source_context, $source, $effect) = @_;
        $authorization_calls++;
        my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
            ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
        my $engine = Selecto::Engine->new(
            domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh),
        );
        return {
            status => 'ok', engine => $engine,
            query => $engine->query->where(Selecto::Expression->eq('status', 'open')),
            page_scope => $scope,
        };
    },
    source_runner => sub {
        my ($engine, $query) = @_;
        push @queries, $engine->compile($query);
        return @queries == 1
            ? {rows => [[1, 'PO-1'], [2, 'PO-2'], [3, 'PO-3']]}
            : {rows => [[3, 'PO-3'], [4, 'PO-4']]};
    },
};
my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
    clock => sub { $now }, id_generator => sub { 'root-http-1' },
);
my $scheduler = RootPageHTTPScheduler->new;
my $app = Mojolicious->new;
$app->secrets(['root-http-test-secret']);
$app->plugin('Selecto::Components::Templates' => {
    store => $store, clock => sub { $now },
    resolve_owner => sub {
        my ($controller) = @_;
        return {status => 'unauthenticated'}
            unless ($controller->req->headers->header('X-Test-Actor') // '') eq 'alice';
        return {status => 'ok', owner_scope => $owner};
    },
    source_scheduler => $scheduler,
    templates => {root_orders => $template},
    install_assets => 0,
});
my $transport = Selecto::Components::Templates::Transport->new(
    template_path => '/templates', instance_path => '/template-instances',
    event_id_generator => sub { 'root-event-1' }, clock => sub { $now },
);
$app->routes->get('/test/root-ready')->to(cb => sub {
    my ($controller) = @_;
    my $loaded = $store->load(owner_scope => $owner, instance_id => 'root-http-1');
    return $transport->respond_snapshot(
        $controller, template => $template,
        snapshot => $loaded->{snapshot}, store_revision => $loaded->{revision},
    );
});

my $t = Test::Mojo->new($app);
my $headers = {'X-Test-Actor' => 'alice'};
$t->get_ok('/templates/root_orders' => $headers)->status_is(200);
my $loaded = $store->load(owner_scope => $owner, instance_id => 'root-http-1');
is $loaded->{status}, 'ok', 'root-page test mounted an owner-scoped instance';
my $source_form = $t->tx->res->dom->at('form.selecto-template-source');
my $source_csrf = $source_form->at('input[name="csrf_token"]')->attr('value');
$t->post_ok('/template-instances/root-http-1/sources/orders' => $headers => form => {
    csrf_token => $source_csrf,
})->status_is(200);
my $ready = $store->load(owner_scope => $owner, instance_id => 'root-http-1')
    ->{snapshot};
is_deeply [map { $_->{id} } @{$ready->{sources}{orders}{result}{rows}}],
    [1, 2], 'normal source route loaded the first bounded root page';
ok $ready->{sources}{orders}{result}{root_page}{has_more},
    'first source result contains a continuation';
is scalar(@queries), 1, 'first root page used one native query';
my $initial_cursor = Selecto::Components::Templates::RootCursor->issue(
    snapshot => $ready, source_id => 'orders',
    source_plan => $manifest->{sources}[0], scope => $scope,
    secret => $template->{page_secret}, now => $now,
);
my $initial_projection = Selecto::Templates->project_root_cursor_page(
    $ready->{sources}{orders}{result}{root_page}{config},
    $ready->{sources}{orders}{result}{rows},
);
is $initial_projection->{status} // 'ok', 'ok',
    'stored first root rows retain their ordering field types';
is $initial_cursor->{status}, 'ok',
    'first source result can issue a typed root cursor';

$t->get_ok('/test/root-ready' => $headers)->status_is(200)
    ->element_exists('form.selecto-template-root-page button');
my $form = $t->tx->res->dom->at('form.selecto-template-root-page');
my $csrf = $form->at('input[name="csrf_token"]')->attr('value');
my $cursor = $form->at('input[name="root_cursor"]')->attr('value');
like $cursor, qr/\Arc1\.[0-9]+\.[0-9a-f]{64}\z/,
    'rendered root control contains only an opaque cursor';
unlike $t->tx->res->body, qr/after_values|order_types|primary_key/,
    'private root position and order metadata are absent from browser HTML';

my $path = '/template-instances/root-http-1/root-pages/orders';
$t->post_ok($path => $headers => form => {
    csrf_token => 'forged', root_cursor => $cursor,
})->status_is(403)->element_exists('[data-selecto-template-error="invalid_csrf"]');
$t->post_ok($path => $headers => form => {
    csrf_token => $csrf, root_cursor => $cursor, after_values => 999,
})->status_is(422)->element_exists('[data-selecto-template-error="invalid_root_page_params"]');
$t->post_ok($path => {'X-Test-Actor' => 'bob'} => form => {
    csrf_token => $csrf, root_cursor => $cursor,
})->status_is(401);
$t->post_ok($path => $headers => form => {
    csrf_token => $csrf, root_cursor => "$cursor-forged",
})->status_is(422)->element_exists('[data-selecto-template-error="invalid_root_cursor"]');
is scalar(@queries), 1, 'forged root token reaches no additional native query';

$t->post_ok($path => $headers => form => {
    csrf_token => $csrf, root_cursor => $cursor,
})->status_is(200)->header_is('X-Selecto-Source' => 'orders');
my $advanced = $store->load(owner_scope => $owner, instance_id => 'root-http-1');
is $advanced->{snapshot}{sources}{orders}{page}, 2,
    'root POST committed through the guarded runtime';
is_deeply [map { $_->{id} } @{$advanced->{snapshot}{sources}{orders}{result}{rows}}],
    [3, 4], 'root POST replaced the visible roots';
is scalar(@queries), 2, 'valid root continuation executed one further native query';
is $authorization_calls, 3, 'initial, forged, and valid reads received fresh authorization';
$t->get_ok('/test/root-ready' => $headers)->status_is(200);
is $t->tx->res->dom->find('form.selecto-template-root-page')->size, 0,
    'terminal root page renders no continuation control';
$t->post_ok($path => $headers => form => {
    csrf_token => $csrf, root_cursor => $cursor,
})->status_is(422)->element_exists('[data-selecto-template-error="invalid_root_cursor"]');

my $latest = $store->load(owner_scope => $owner, instance_id => 'root-http-1');
my $retryable = dclone($latest->{snapshot});
$retryable->{sources}{orders} = $ready->{sources}{orders};
is $store->compare_and_set(
    owner_scope => $owner, instance_id => 'root-http-1',
    revision => $latest->{revision}, next_snapshot => $retryable,
)->{status}, 'ok', 'a fresh root-page snapshot was stored';
$t->get_ok('/test/root-ready' => $headers)->status_is(200);
my $stale_form = $t->tx->res->dom->at('form.selecto-template-root-page');
my $stale_csrf = $stale_form->at('input[name="csrf_token"]')->attr('value');
my $stale_cursor = $stale_form->at('input[name="root_cursor"]')->attr('value');
$scheduler->{before_finish} = sub {
    my $current = $store->load(
        owner_scope => $owner, instance_id => 'root-http-1',
    );
    my $newer = dclone($current->{snapshot});
    $newer->{sources}{orders}{page}++;
    my $saved = $store->compare_and_set(
        owner_scope => $owner, instance_id => 'root-http-1',
        revision => $current->{revision}, next_snapshot => $newer,
    );
    die 'concurrent root page update failed' unless $saved->{status} eq 'ok';
};
$t->post_ok($path => $headers => form => {
    csrf_token => $stale_csrf, root_cursor => $stale_cursor,
})->status_is(409)->element_exists('[data-selecto-template-error="stale_root_page_commit"]');
is $store->load(owner_scope => $owner, instance_id => 'root-http-1')
    ->{snapshot}{sources}{orders}{page}, 2,
    'stale root response leaves the newer store page intact';

done_testing;

package RootPageHTTPScheduler;

sub new { return bless {}, $_[0] }

sub execute {
    my ($self, %args) = @_;
    Mojo::IOLoop->next_tick(sub {
        my $result = $args{work}->($args{payload});
        $self->{before_finish}->() if $self->{before_finish};
        $args{on_finish}->($result);
    });
    return {status => 'scheduled'};
}

package RootPageHTTPDBH;

sub new { return bless {}, $_[0] }
sub prepare { die 'root-page HTTP test must use the governed source runner' }
sub errstr { return undef }
