use 5.034;
use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Mojolicious;
use Encode qw(decode);
use Selecto::CannedPage ();
use Selecto::Components::CannedPage ();
use Selecto::Components::Renderer::Results ();
use Selecto::Domain ();
use Selecto::Query ();

my $domain = Selecto::Domain->new(
    name => 'Rows', table => 'rows', fields => {id => 'integer', name => 'string'},
);
my $page = Selecto::CannedPage->new(
    id => 'rows', domain => $domain,
    dataset => {query => Selecto::Query->new, entity_key => ['id']},
    views => [{id => 'list', kind => 'detail',
        query => Selecto::Query->new->select('id', 'name')}],
    controls => [{id => 'name', label => 'Name', field => 'name', kind => 'text'}],
);
my $component = Selecto::Components::CannedPage->new(
    page => $page, path => '/rows', title => 'Rows',
    engine_factory => sub { die 'not needed' },
    websocket_enabled => 0,
    record_link => {field => 'id', url_prefix => '/portal/quote?quoteId=',
        target => '_top'},
);
my $result = {
    state => $page->normalize_state({}),
    view => {id => 'list', kind => 'detail', label => 'Rows'},
    columns => [qw(id name)], rows => [[42, 'Sample']], total => 1,
    has_more => 0, facets => {},
};
my $html = $component->_html($result, 1);
like $html, qr{href="/portal/quote\?quoteId=42"},
    'selected record ID opens a local record';
like $html, qr{<td><a class="sc-object-link" href="/portal/quote\?quoteId=42" target="_top">42</a></td>},
    'the ID itself is the record link';
unlike $html, qr{<th scope="col">Open</th>},
    'the record link does not add a redundant Open column';
my $legacy_component = Selecto::Components::CannedPage->new(
    page => $page, path => '/rows', title => 'Rows',
    engine_factory => sub { die 'not needed' },
    record_link => {field => 'id',
        url_prefix => '/backoffice/loadmaint.mcgi?load_id=', target => '_top'},
);
like $legacy_component->_table($result),
    qr{href="/backoffice/loadmaint\.mcgi\?load_id=42" target="_top"},
    'a local legacy CGI can be a canned record link';
my $modal_component = Selecto::Components::CannedPage->new(
    page => $page, path => '/rows', title => 'Rows',
    engine_factory => sub { die 'not needed' }, websocket_enabled => 0,
    record_link => {field => 'id', url_prefix => '/portal-views/order-display/',
        modal_title => 'Order ID Display'},
);
my $modal_html = $modal_component->_html($result, 1);
like $modal_html,
    qr{href="/portal-views/order-display/42" data-sc-canned-modal-link data-sc-canned-modal-title="Order ID Display"},
    'a selected ID can open a same-origin modal with a usable URL fallback';
unlike $modal_html, qr{href="/portal-views/order-display/42" target="_top"},
    'a modal ID does not navigate out of the canned view';
like $modal_html, qr{src="/selecto-components/canned-page\.js\?v=[^"]+"},
    'the modal behavior is loaded on canned pages without WebSockets';
like $html, qr{target="_top"}, 'embedded canned list opens the record in the portal window';
unlike $html, qr{hx-ws:connect|hx-ws:send},
    'GET-only canned page does not try to reconnect a WebSocket';
like $html, qr{method="get"}, 'GET-only canned page keeps normal form navigation';
like $html, qr{<strong>1</strong> row matched .+? <strong>1</strong> page},
    'result summary uses the same count and page hint as Explorer';
like $html, qr{Page 1 of 1}, 'pagination shows the total page count';

my $nested_photos = Selecto::Components::Renderer::Results::_nested_table(
    {label => 'Photos', nested_fields => [{
        field => 'id', label => 'Photo',
        link => {url_prefix => '/portal-views/photos/'},
    }]},
    [{id => 123}], 1,
);
like $nested_photos,
    qr{href="/portal-views/photos/123" target="_top">123</a>},
    'nested IDs can link to a host-authorized local route';
my $named_photo_link = Selecto::Components::Renderer::Results::_nested_table(
    {label => 'Photos', nested_fields => [{field => 'id', label => 'Photo',
        link => {url_prefix => '/portal-views/photos/', text => 'View photo'}}]},
    [{id => 123}], 1,
);
like $named_photo_link,
    qr{href="/portal-views/photos/123" target="_top">View photo</a>},
    'nested photo links can use an accessible action label';
my $context_photo_link = Selecto::Components::Renderer::Results::_nested_table(
    {label => 'Photos', nested_fields => [{field => 'id', label => 'Photo',
        link => {url_prefix => '/portal-views/photos/',
            parent_field => 'id', text => 'View photo'}}]},
    [{id => 123, __selecto_parent_id => 42}], 1,
);
like $context_photo_link,
    qr{href="/portal-views/photos/42/123" target="_top">View photo</a>},
    'nested links can carry the selected parent context';
my $invalid_parent = Selecto::Components::Renderer::Results::_nested_table(
    {label => 'Photos', nested_fields => [{field => 'id', label => 'Photo',
        link => {url_prefix => '/portal-views/photos/', parent_field => 'id'}}]},
    [{id => 123, __selecto_parent_id => '../other'}], 1,
);
unlike $invalid_parent, qr{<a },
    'invalid parent identifiers cannot become nested URLs';

my $layout_component = Selecto::Components::CannedPage->new(
    page => $page, path => '/rows', title => 'Rows',
    engine_factory => sub { die 'not needed' },
    column_layout => [
        {kind => 'field', field => 'id', label => 'ID'},
        {kind => 'link', field => 'id', label => 'Photos',
            text => 'View photos', url_prefix => '/portal-views/photos/'},
    ],
);
like $layout_component->_table($result),
    qr{href="/portal-views/photos/42" target="_top">View photos</a>},
    'canned layouts can show a local action link instead of an ID';
ok !eval { Selecto::Components::CannedPage->new(
    page => $page, path => '/rows', engine_factory => sub { die 'not needed' },
    column_layout => [{kind => 'link', field => 'id', label => 'Photos',
        text => 'View photos', url_prefix => '//external.example/'}],
); 1 }, 'canned layout links reject external URL prefixes';

my $paged_result = {
    %$result,
    state => $page->normalize_state({page => 2, limit => 25,
        filters => {name => 'Sam'}}),
    total => 72, has_more => 1, elapsed_ms => 17,
};
my $paged_html = $component->_html($paged_result, 1);
like $paged_html, qr{<strong>72</strong> rows matched .+? <strong>3</strong> pages .+? <strong>17 ms</strong> query time},
    'result summary includes matching rows, pages, and query time';
is scalar(() = $paged_html =~ /Page 2 of 3/g), 2,
    'matching top and bottom pagination show the current page';
like $paged_html, qr{name="page" value="1" aria-label="Page 1">Previous</button>},
    'previous-page button uses Explorer pagination';
like $paged_html, qr{aria-current="page" aria-label="Page 2, current page"},
    'current page is identified accessibly';
like $paged_html, qr{name="page" value="3" aria-label="Page 3">Next</button>},
    'next-page button uses Explorer pagination';
unlike $paged_html, qr{hx-ws:send},
    'pagination also avoids WebSocket transport when it is disabled';
like $paged_html, qr{<nav class="sc-pagination sc-pagination-top".+?<input type="hidden" name="f_name" value="Sam".+?</nav>}s,
    'pagination preserves the active filter';

my $app = Mojolicious->new;
my $http_component = Selecto::Components::CannedPage->new(
    page => $page, path => '/rows', title => 'Rows',
    engine_factory => sub { bless {}, 'Test::CannedRenderEngine' },
    websocket_enabled => 0,
    record_link => {field => 'id', url_prefix => '/portal/quote?quoteId=',
        target => '_top'},
);
$app->routes->get('/rows')->to(cb => sub {
    my ($controller) = @_;
    local *Selecto::CannedPage::run = sub {
        return {%$result, rows => [[42, "Caf\x{e9}"]]};
    };
    $http_component->handle($controller);
});
my $http = Test::Mojo->new($app);
$http->get_ok('/rows')->status_is(200);
ok !utf8::is_utf8($http->tx->res->body),
    'canned HTML is emitted as bytes before response compression';
like decode('UTF-8', $http->tx->res->body), qr/Caf\x{e9}/,
    'non-ASCII result data survives UTF-8 encoding';

for my $bad (
    {field => 'id', url_prefix => '//external.example/'},
    {field => 'id', url_prefix => '/../external/'},
    {field => 'id', url_prefix => '/rows/', target => '_blank'},
    {field => 'id', url_prefix => '/rows/', modal_title => []},
    {field => 'id', url_prefix => '/rows/', modal_title => 'Details', target => '_top'},
) {
    my $ok = eval {
        Selecto::Components::CannedPage->new(
            page => $page, path => '/rows',
            engine_factory => sub { die 'not needed' }, record_link => $bad,
        );
        1;
    };
    ok !$ok, 'unsafe record navigation is rejected';
}

done_testing;
