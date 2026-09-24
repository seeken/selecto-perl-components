use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Mojo::IOLoop;
use Mojolicious;
use Test::More;
use Test::Mojo;
use Selecto::Components::Templates::InstanceStore::Memory ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $cases = _json("$fixtures/order-choice-root-cursor.cases.json");
my $catalog = _json("$fixtures/$cases->{domain_catalog}");
my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1);
my $manifest = Selecto::Templates->compile(
    Selecto::Templates->parse(_read("$fixtures/$cases->{source}")),
    domains => {orders => $domain},
    capabilities => _json("$fixtures/capabilities.json"),
);
my $owner = {actor_id => 'alice', tenant_id => 7};
my $scope = {
    tenant_id => '7', principal_id => 'alice',
    authorization_revision => 'acl-1', membership_revision => 'orders-1',
};
my $now = 1_000;
my @queries;
my $runner = sub {
    my ($engine, $query) = @_;
    my $compiled = $engine->compile($query);
    my $choice = $query->applied_query_library->{ordering};
    my $continued = $compiled->sql =~ /[<>]\s*\$[0-9]+/ ? 1 : 0;
    push @queries, {choice => $choice, continued => $continued,
        sql => $compiled->sql, params => $compiled->params};
    my %pages = (
        oldest => {
            first => [[1, 'PO-1', 'open'], [4, 'PO-4', 'open'], [5, 'PO-5', 'open']],
            next => [[5, 'PO-5', 'open'], [7, 'PO-7', 'open']],
        },
        newest => {
            first => [[7, 'PO-7', 'open'], [5, 'PO-5', 'open'], [4, 'PO-4', 'open']],
            next => [[4, 'PO-4', 'open'], [1, 'PO-1', 'open']],
        },
    );
    die 'unexpected named ordering' unless exists($pages{$choice});
    return {rows => $pages{$choice}{$continued ? 'next' : 'first'}};
};
my $registry = {
    components => {
        SearchInput => sub {
            my ($node) = @_;
            my $event = $node->{transport}{events}{change};
            my $fields = join '', map {
                '<input type="hidden" name="' . html_escape($_) . '" value="' .
                    html_escape($event->{fields}{$_}) . '">'
            } sort keys %{$event->{fields}};
            return Selecto::Components::Templates::Renderer->safe_html(
                '<form data-template-event="sort_changed" method="post" action="' .
                    html_escape($event->{action}) . '">' . $fields .
                    '<input name="value" value="' .
                    html_escape($node->{props}{value}) . '"></form>',
            );
        },
    },
    elements => {},
    include => sub { Selecto::Components::Templates::Renderer->safe_html('') },
};
my $store = Selecto::Components::Templates::InstanceStore::Memory->new(
    clock => sub { $now }, id_generator => sub { 'named-root-http-1' },
);
my $app = Mojolicious->new;
$app->secrets(['named-root-http-test-secret']);
$app->plugin('Selecto::Components::Templates' => {
    store => $store, clock => sub { $now },
    resolve_owner => sub {
        my ($controller) = @_;
        return {status => 'unauthenticated'}
            unless ($controller->req->headers->header('X-Test-Actor') // '') eq 'alice';
        return {status => 'ok', owner_scope => $owner};
    },
    source_scheduler => NamedRootHTTPScheduler->new,
    templates => {named_orders => {
        title => 'Named root pages', release_id => 'named-root-http-v1',
        manifest => $manifest, registry => $registry,
        page_secret => 'n' x 32, root_cursor_sources => ['orders'],
        resolve_page_scope => sub { $scope },
        source_authorizer => sub {
            my ($source_context, $source, $effect) = @_;
            my $scoped = $domain->with_required_predicate(
                Selecto::Expression->eq('tenant_id', 7),
            );
            my $engine = Selecto::Engine->new(
                domain => $scoped,
                adapter => Selecto::PostgreSQL->new(dbh => NamedRootHTTPDBH->new),
            );
            return {
                status => 'ok', engine => $engine,
                query => $engine->query->where(
                    Selecto::Expression->eq('status', $cases->{host_status}),
                ),
                page_scope => $scope,
            };
        },
        source_runner => $runner,
    }},
    install_assets => 0,
});

my $t = Test::Mojo->new($app);
my $headers = {'X-Test-Actor' => 'alice'};
$t->get_ok('/templates/named_orders' => $headers)->status_is(200);
my $source_form = $t->tx->res->dom->at('form.selecto-template-source');
my $csrf = $source_form->at('input[name="csrf_token"]')->attr('value');
my $source_path = '/template-instances/named-root-http-1/sources/orders';
$t->post_ok($source_path => $headers => form => {csrf_token => $csrf})->status_is(200);
my $first = $store->load(owner_scope => $owner, instance_id => 'named-root-http-1')->{snapshot};
is_deeply [map { $_->{id} } @{$first->{sources}{orders}{result}{rows}}],
    $cases->{cases}[0]{pages}[0]{ids}, 'initial HTTP source uses oldest named order';
is scalar(@queries), 1, 'initial named root read uses one source query';
is $queries[0]{choice}, 'oldest', 'initial query selects the locked oldest ordering';
like $queries[0]{sql}, qr/order by .*"id" asc/is,
    'oldest ordering reaches native SQL';
ok scalar(grep { defined($_) && !ref($_) && "$_" eq '7' } @{$queries[0]{params}}),
    'initial named root query keeps required tenant scope';
ok scalar(grep { defined($_) && !ref($_) && "$_" eq 'open' } @{$queries[0]{params}}),
    'initial named root query keeps host status membership';
my $old_cursor_form = $t->tx->res->dom->at('form.selecto-template-root-page');
my $old_cursor = $old_cursor_form->at('input[name="root_cursor"]')->attr('value');

my $event_form = $t->tx->res->dom->at('form[data-template-event="sort_changed"]');
ok $event_form, 'text-declared sort event renders an HTTP form';
my %event_fields = map {
    $_->attr('name') => $_->attr('value')
} @{$event_form->find('input[type="hidden"]')->to_array};
$event_fields{value} = 'newest';
$t->post_ok('/template-instances/named-root-http-1/events' => $headers
    => form => \%event_fields)->status_is(200);
my $reloading = $store->load(owner_scope => $owner, instance_id => 'named-root-http-1')->{snapshot};
is $reloading->{state}{sort}, 'newest', 'declared event changed the server-owned sort state';
my $new_source_form = $t->tx->res->dom->at('form.selecto-template-source');
my $new_csrf = $new_source_form->at('input[name="csrf_token"]')->attr('value');
$t->post_ok($source_path => $headers => form => {csrf_token => $new_csrf})->status_is(200);
my $newest = $store->load(owner_scope => $owner, instance_id => 'named-root-http-1')->{snapshot};
is_deeply [map { $_->{id} } @{$newest->{sources}{orders}{result}{rows}}],
    $cases->{cases}[1]{pages}[0]{ids}, 'sort event reloaded the first descending root page';
is scalar(@queries), 2, 'sort event needed one new source query';
is $queries[1]{choice}, 'newest', 'reloaded query selects the locked newest ordering';
like $queries[1]{sql}, qr/order by .*"id" desc/is,
    'newest ordering reaches native SQL';

my $new_cursor_form = $t->tx->res->dom->at('form.selecto-template-root-page');
my $new_cursor = $new_cursor_form->at('input[name="root_cursor"]')->attr('value');
my $root_csrf = $new_cursor_form->at('input[name="csrf_token"]')->attr('value');
isnt $new_cursor, $old_cursor, 'sort event replaces the opaque root cursor';
my $root_path = '/template-instances/named-root-http-1/root-pages/orders';
$t->post_ok($root_path => $headers => form => {
    csrf_token => $root_csrf, root_cursor => $old_cursor,
})->status_is(422)->element_exists('[data-selecto-template-error="invalid_root_cursor"]');
is scalar(@queries), 2, 'old ordering cursor is rejected before a source query';
$t->post_ok($root_path => $headers => form => {
    csrf_token => $root_csrf, root_cursor => $new_cursor,
})->status_is(200);
my $continued = $store->load(owner_scope => $owner, instance_id => 'named-root-http-1')->{snapshot};
is_deeply [map { $_->{id} } @{$continued->{sources}{orders}{result}{rows}}],
    $cases->{cases}[1]{pages}[1]{ids},
    'current ordering cursor advances to the terminal descending page';
is scalar(@queries), 3, 'valid new cursor executes one continuation query';
ok $queries[2]{continued}, 'continuation uses a seek predicate';
ok scalar(grep { defined($_) && !ref($_) && "$_" eq '5' } @{$queries[2]{params}}),
    'continuation binds the last visible descending root';

done_testing;

sub _read {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "cannot read $path: $!";
    return do { local $/; <$handle> };
}

sub _json {
    return JSON::PP->new->utf8(1)->decode(_read($_[0]));
}

package NamedRootHTTPScheduler;

sub new { bless {}, $_[0] }
sub execute {
    my ($self, %args) = @_;
    Mojo::IOLoop->next_tick(sub {
        my $result = $args{work}->($args{payload});
        $args{on_finish}->($result);
    });
    return {status => 'scheduled'};
}

package NamedRootHTTPDBH;

sub new { bless {}, $_[0] }
sub prepare { die 'named root HTTP test must use its governed source runner' }
sub errstr { undef }
