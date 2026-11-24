use 5.034;
use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::URL;
use Mojo::DOM;
use DBI;
use IO::Uncompress::Unzip;
use lib 't/lib';
use AsOfFixture;
use Selecto::Components::Config;
use Selecto::Components::ExplorerSession;
use Selecto::Components::Renderer;
use Selecto::Components::Dashboard;
use Selecto::Components::Canonical;
use Selecto::Components::CannedPage;
use TestSelectoComponents;

my $app = AsOfFixture::app();
my $c = $app->build_controller;
my $explorer = $c->selecto_components_explorer('events');
my $config = $explorer->config;
my $live = $config->engine($c);
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
$dbh->do('CREATE TABLE asof_events (id integer primary key, day date, region text)');
$dbh->do("INSERT INTO asof_events VALUES (101, '2026-03-15', 'Snapshot'), (102, '2026-03-14', 'Snapshot')");
my $snapshot = Selecto::Engine->new(domain => $live->domain, adapter => Selecto->adapter(sqlite => dbh => $dbh));
my $last_socket;
my ($offered, $refuse, @calls, @callbacks, @cleanups) = (1, 0);
$config->title('Host Explorer');
$config->query_options([{
    name => 'backend', label => 'Query backend', choices => [[postgresql => 'Live'], [duckdb => 'Snapshot']],
    default => 'postgresql', control => 'checkbox', checkbox_label => 'Use snapshot',
    offered => sub ($controller, $config) { $offered },
    help_link => {href => '/snapshot-status', label => 'Snapshot status'},
}]);
Selecto::Components::QueryOptions->validate($config);
$config->engine_factory(sub ($controller, $request) {
    is_deeply $controller->stash('selecto_components_query_options'), $request->{query_options}, 'factory sees same stashed options';
    push @calls, {backend => $request->{query_options}{backend}, field => $request->{input}{field}};
    Selecto::Error->throw('invalid_query', 'Snapshot lacks Rush (rush). Turn off Use snapshot.')
        if $refuse == 1 && $request->{query_options}{backend} eq 'duckdb';
    die 'private connection details' if $refuse == 2;
    return $request->{query_options}{backend} eq 'duckdb' ? $snapshot : $live;
});
$config->result_cache_namespace(sub ($controller, $config) {
    push @callbacks, ['cache', $controller->stash('selecto_components_query_options')->{backend}];
    return 'same-source-for-cache-isolation-test';
});
$config->export_authorizer(sub ($controller, $config) {
    push @callbacks, ['export', $controller->stash('selecto_components_query_options')->{backend}];
    return 1;
});
$config->max_export_rows(sub ($controller, $config) {
    push @callbacks, ['limit', $controller->stash('selecto_components_query_options')->{backend}];
    return $controller->stash('selecto_components_query_options')->{backend} eq 'duckdb' ? 1 : 3;
});
$config->results_note_resolver(sub ($controller, $config, $model) {
    my $backend = $controller->stash('selecto_components_query_options')->{backend};
    push @callbacks, ['note', $backend];
    return $backend eq 'duckdb' ? 'Snapshot <2026-11-18> & tenant' : undef;
});
$config->api_console_resolver(sub { '/console' });
$config->websocket_message_cleanup(sub ($controller, $config) {
    $last_socket = $controller;
    push @cleanups, $controller->stash('selecto_components_query_options')->{backend};
});
my %base = (q => 1, view => 'detail', field => ['id', 'day', 'region'], order => 'id', limit => 1, backend => 'duckdb');
my $state = sub (%input) { Selecto::Components::State->from_input($config, $live->domain, {q => 1, %input}) };
is $state->(backend => 'duckdb')->query_options->{backend}, 'duckdb', 'declared option parses without building an engine';
like join(' ', @{$state->(backend => 'invalid')->errors}), qr/Query backend.*invalid/, 'invalid option is a named state error';
ok !$state->(backend => ['duckdb', 'postgresql'])->valid, 'ambiguous duplicate option refused';
is $state->(backend => ['postgresql', 'duckdb'])->query_options->{backend}, 'duckdb', 'HTML checkbox parses hidden default plus checked value';
my $default = $state->();
is_deeply $default->query_pairs, $state->(backend => 'postgresql')->query_pairs, 'explicit default and missing default serialize identically';
unlike $explorer->canonical_url($default, $live->domain), qr/backend/, 'default omitted from URL';
isnt $default->query_signature, $state->(backend => 'duckdb')->query_signature, 'options change query signature';
$offered = 0;
like join(' ', @{$state->(backend => 'duckdb')->errors}), qr/Query backend Snapshot isn't available/, 'unoffered nondefault refused';
my $t = Test::Mojo->new($app);
$t->get_ok('/events')->status_is(200)->element_exists_not('[data-sc-query-option]');
diag $t->tx->res->dom->find('[role=alert]')->map('all_text')->join('; ') if $t->tx->res->code != 200;
$t->get_ok('/events?backend=duckdb')->status_is(422)->content_like(qr/isn&#39;t available/)->element_exists_not('[data-sc-query-option]');
$offered = 1;
$t->get_ok('/events' => form => \%base)->status_is(200)->text_is('h1', 'Host Explorer')
    ->element_exists('input[data-sc-query-option][checked]')->element_exists('a[href="/snapshot-status"]')
    ->text_is('.sc-results-note', 'Snapshot <2026-11-18> & tenant');
like $t->tx->res->body, qr/Snapshot &lt;2026-11-18&gt; &amp; tenant/, 'note is escaped';
is $calls[-1]{backend}, 'duckdb', 'HTTP factory gets request choice';
is_deeply $calls[-1]{field}, ['id', 'day', 'region'], 'HTTP factory gets repeated raw fields';
my $dom = $t->tx->res->dom;
for my $link (@{$dom->find('a[data-sc-export-format], .sc-hero-actions > a')}) {
    next if $link->attr('data-sc-header-link');
    is(Mojo::URL->new($link->attr('href'))->query->param('backend'), 'duckdb', 'export/permalink carries backend');
}
for my $selector ('.sc-pagination form', 'form[data-sc-builder]') {
    my $forms = $dom->find($selector);
    ok $forms->size, "$selector exists";
    for my $form (@$forms) {
        my $option = $form->at('input[name=backend][value=duckdb]');
        ok $option, "$selector carries backend";
    }
}
$t->get_ok('/events' => form => {%base, direction => 'desc'})->status_is(200);
is_deeply $t->tx->res->dom->find('.sc-results tbody tr td:first-child')->map('all_text')->to_array,
    ['102'], 'sort reruns alternate engine in descending order';
is $calls[-1]{backend}, 'duckdb', 'sort keeps backend';
$t->post_ok('/events' => form => {%base, host_extra => 'raw-post-value'})->status_is(200);
is $calls[-1]{backend}, 'duckdb', 'POST fallback uses declared choice';
my $canonical = $explorer->model($c, \%base)->{canonical_url};
is(Mojo::URL->new($canonical)->query->param('backend'), 'duckdb', 'canonical URL carries option');
is(Selecto::Components::Dashboard->input_from_url($canonical, $config)->{backend}, 'duckdb', 'dashboard import carries declared option');
my %summary = (%base, view => 'aggregate', group => ['region', 'day'], measure => 'count', limit => 25);
for my $mode ('summary', 'grid', 'pivot') {
    my %input = (%summary, ($mode eq 'grid' ? (aggregate_grid => 1) : $mode eq 'pivot' ? (pivot_column => 'day') : ()));
    $t->get_ok('/events' => form => \%input)->status_is(200);
    my $forms = $t->tx->res->dom->find($mode eq 'grid' ? 'form.sc-grid-selection-form' : $mode eq 'pivot' ? 'form.sc-pivot-drill-form' : 'form.sc-drilldown-form');
    ok $forms->size, "$mode drill forms exist";
    for my $form (@$forms) {
        is $form->at('input[name=backend]')->attr('value'), 'duckdb', "$mode drill carries backend";
    }
}
# A concrete grid selection is sent back through the ordinary GET fallback.
my $grid_model = $explorer->model($c, {%summary, aggregate_grid => 1});
my $grid_html = Selecto::Components::Renderer->page($grid_model);
my $grid_form = Mojo::DOM->new($grid_html)->at('form.sc-grid-selection-form');
my %selection;
for my $input (@{$grid_form->find('input[type=hidden]')}) {
    push @{$selection{$input->attr('name')}}, $input->attr('value');
}
$selection{grid_cell} = '["Snapshot","2026-03-15"]';
$t->get_ok('/events' => form => \%selection)->status_is(200);
is $calls[-1]{backend}, 'duckdb', 'grid selected cells reach alternate factory';

$t->get_ok('/events' => form => \%base)->status_is(200);
my $csrf = $t->tx->res->dom->at('form[data-sc-builder]')->attr('data-sc-column-values-csrf');
$t->post_ok('/events/saved-queries' => form => {csrf_token => $csrf, saved_query_operation => 'new',
    saved_query_name => 'Snapshot view', saved_query_url => $canonical})->status_is(302);
my $saved = $config->saved_query_store->list($c, $config)->[0];
is(Mojo::URL->new($saved->{url})->query->param('backend'), 'duckdb', 'saved state carries backend');
$t->get_ok($saved->{url})->status_is(200)->element_exists('input[data-sc-query-option][checked]');
is $calls[-1]{backend}, 'duckdb', 'saved query reopens on alternate engine';
$t->post_ok('/events/column-values' => form => {csrf_token => $csrf, field => 'region', backend => 'duckdb'})->status_is(200);
is $calls[-1]{backend}, 'duckdb', 'column lookup carries option';

for my $format (qw(csv tsv json xlsx)) {
    $t->get_ok('/events' => form => {%base, format => $format})->status_is(200);
    is $calls[-1]{backend}, 'duckdb', "$format export gets alternate engine";
    my $body = $t->tx->res->body;
    if ($format eq 'json') {
        my $json = decode_json($body);
        is $json->{meta}{results_note}, 'Snapshot <2026-11-18> & tenant', 'JSON export metadata contains note';
        is $json->{row_limit}, 1, 'callback export limit honored';
        is scalar(@{$json->{rows}}), 1, 'stream actually stops at callback limit';
        is $json->{rows}[0]{Id}, 101, 'export uses snapshot database';
    } elsif ($format eq 'xlsx') {
        my $zip = IO::Uncompress::Unzip->new(\$body) or die 'invalid XLSX';
        my ($comments, $sheet) = ('', '');
        do {
            my $part = ''; while ($zip->read(my $chunk) > 0) { $part .= $chunk }
            $comments .= $part if $zip->getHeaderInfo->{Name} =~ /comments\d+\.xml/;
            $sheet = $part if $zip->getHeaderInfo->{Name} eq 'xl/worksheets/sheet1.xml';
        } while ($zip->nextStream > 0);
        like $comments, qr/Snapshot &lt;2026-11-18&gt; &amp; tenant/, 'XLSX header comment contains escaped note';
        like $sheet, qr/r="A2"[^>]*><v>101<\/v>/, 'XLSX data starts on row two';
        unlike $sheet, qr/r="A3"/, 'XLSX callback row limit honored';
    } else {
        unlike $body, qr/Snapshot <2026/, "$format has no extra comment row";
        is scalar(split /\r\n/, $body), 2, "$format header plus one data row";
    }
}
for my $kind (qw(export limit note cache)) {
    ok scalar(grep { $_->[0] eq $kind && $_->[1] eq 'duckdb' } @callbacks), "$kind callback sees stashed options";
}
# Identical SQL/domain/namespace, different physical data, through both caches.
{
    package QueryOptionsHostCache;
    sub new { bless {entries => {}}, shift }
    sub fetch { $_[0]{entries}{$_[1]} }
    sub store { $_[0]{entries}{$_[1]} = {result => Mojo::JSON::decode_json(Mojo::JSON::encode_json($_[2]))} }
}
my $host_cache = QueryOptionsHostCache->new;
for my $backend (qw(postgresql duckdb postgresql duckdb)) {
    my $model = $explorer->model($c, {%base, backend => $backend}, {result_cache => $host_cache});
    is 0 + $model->{result}{records}[0]{id}, $backend eq 'duckdb' ? 101 : 1,
        'external cache keys separate identical SQL across choices';
}
my $cache = Selecto::Components::ExplorerSession->new;
for my $backend (qw(postgresql duckdb postgresql)) {
    my $model = $explorer->model($c, {%base, backend => $backend}, {result_cache => $cache});
    is $model->{runtime_error}, undef, 'cache model runs';
    is 0 + $model->{result}{records}[0]{id}, $backend eq 'duckdb' ? 101 : 1, 'cache never crosses options';
}
$t->websocket_ok('/events/ws')->send_ok({text => encode_json({headers => {}, %base, selecto_request_id => 'one'})})->message_ok;
my $first = decode_json($t->message->[1]);
is $first->{selecto}{session}{accepted}, 1, 'socket accepts alternate backend';
like $first->{content}, qr/Snapshot &lt;2026-11-18&gt;/, 'socket shows note';
$t->send_ok({text => encode_json({headers => {}, selecto_session => {revision => 1, set => {backend => 'postgresql'}, remove => []}})})->message_ok;
my $second = decode_json($t->message->[1]);
is $second->{selecto}{session}{accepted}, 1, 'socket accepts option patch';
is $calls[-1]{backend}, 'postgresql', 'patch builds different engine from message state';
unlike $second->{selecto}{url}, qr/backend/, 'default option omitted from socket URL';
unlike $second->{content}, qr/sc-results-note/, 'default backend clears note';
$t->send_ok({text => encode_json({headers => {}, selecto_session => {revision => 2, set => {backend => 'duckdb'}, remove => []}})})->message_ok;
my $third = decode_json($t->message->[1]);
like $third->{content}, qr/>101</, 'return to snapshot does not reuse live data';
is_deeply [@cleanups[-3..-1]], [qw(duckdb postgresql duckdb)], 'stash belongs to each message through cleanup';
$t->finish_ok;
ok !defined($last_socket->stash('selecto_components_query_options')), 'socket option stash restored after message';
ok !defined($last_socket->stash('selecto_components_query_input')), 'socket raw input stash restored after message';

$refuse = 1;
$t->get_ok('/events' => form => \%base)->status_is(422)->content_like(qr/Snapshot lacks Rush/)
    ->text_is('h1', 'Host Explorer')->element_exists('input[data-sc-query-option][checked]')
    ->element_exists('input[type=hidden][name=field][value=region]');
$t->websocket_ok('/events/ws')->send_ok({text => encode_json({headers => {}, %base})})->message_ok;
like decode_json($t->message->[1])->{content}, qr/Snapshot lacks Rush/, 'socket refusal keeps useful error and control';
$t->finish_ok;
$refuse = 2;
$t->get_ok('/events' => form => \%base)->status_is(422)->content_unlike(qr/private connection details/);
$refuse = 0;

# Declaring options selects the plain two-argument API. Without declarations,
# even a factory accepting optional context receives only the controller.
for my $declared (0, 1) {
    for my $factory (
        sub ($controller, $context = {}) {
            is_deeply $context, $declared ? {query_options => {backend => 'duckdb'}, input => \%base} : {},
                'signature factory follows declaration rule';
            return $live;
        },
        sub {
            is scalar(@_), $declared ? 2 : 1, 'traditional factory follows declaration rule';
            return $live;
        },
    ) {
        my $copy = Selecto::Components::Config->new(%$config, engine_factory => $factory,
            query_options => $declared ? $config->query_options : [], max_export_rows => 100);
        is $copy->engine($c, \%base), $live, 'factory returns engine';
    }
}
my $copy = Selecto::Components::Config->new(%$config, engine_factory => sub ($controller, $context) {
    ok !defined($context->{input}{absent}), 'input copy permits absent-key reads';
    $context->{input}{backend} = 'other';
    push @{$context->{input}{field}}, 'rush';
    $context->{input}{extra} = {nested => ['changed']};
    return $live;
});
$copy->engine($c, \%base);
is $base{backend}, 'duckdb', 'factory scalar changes do not alter caller input';
is_deeply $base{field}, [qw(id day region)], 'factory array changes do not alter caller input';
ok !exists($base{extra}), 'factory additions do not alter caller input';
is $c->stash('selecto_components_query_options')->{backend}, 'duckdb', 'input copy changes do not alter parsed options';
$copy = Selecto::Components::Config->new(%$config, query_options => [{%{$config->query_options->[0]}, control => 'select'}]);
my $select = Selecto::Components::Renderer::Builder->query_options_control({config => $copy, input => \%base});
like $select, qr/<select data-sc-query-option name="backend" data-sc-query-option-default="postgresql">/, 'select renders labelled options';
for my $name (qw(field format selecto_session backend)) {
    my $options = [{%{$config->query_options->[0]}, name => $name}];
    push @$options, {%{$options->[0]}} if $name eq 'backend';
    ok !eval { Selecto::Components::Config->new(%$config, query_options => $options); 1 }, 'reserved/duplicate option rejected';
}
$copy = Selecto::Components::Config->new(%$config, max_export_rows => sub { 0 });
ok !eval { $copy->engine($c, \%base); 1 }, 'invalid callback row limit refused';
# Prepare two requests against the same plugin config, then return to A.
# No per-request state may be attached to the plugin-wide configuration.
my @request_keys = qw(_request_config _query_options_context _resolved_export_rows
    _localization_controller _resolved_theme _resolved_page_shell _export_allowed
    _hidden_prerequisite_actions _catalog_cache _i18n_metadata_cache);
my $clean_shared = sub ($label) {
    is_deeply [grep { exists $config->{$_} } @request_keys], [], $label;
};
$clean_shared->('shared config is clean before interleaved requests');
my $controller_a = $app->build_controller;
my $controller_b = $app->build_controller;
my $prepared_a = $explorer->prepare($controller_a, {%base, backend => 'duckdb'});
my $fingerprint_a = Selecto::Components::QueryOptions->fingerprint($prepared_a->{config});
my $key_a = Selecto::Components::Explorer->result_cache_key($prepared_a->{statement}, 'interleaved',
    $prepared_a->{domain}->fingerprint . $fingerprint_a);
$clean_shared->('preparing A leaves shared config clean');
my $prepared_b = $explorer->prepare($controller_b, {%base, backend => 'postgresql'});
my $fingerprint_b = Selecto::Components::QueryOptions->fingerprint($prepared_b->{config});
isnt $fingerprint_a, $fingerprint_b, 'interleaved request fingerprints differ';
is(Selecto::Components::QueryOptions->fingerprint($prepared_a->{config}), $fingerprint_a,
    'preparing B cannot change A fingerprint');
is(Selecto::Components::Explorer->result_cache_key($prepared_a->{statement}, 'interleaved',
    $prepared_a->{domain}->fingerprint . Selecto::Components::QueryOptions->fingerprint($prepared_a->{config})),
    $key_a, 'using A cache key after B retains A identity');
like(Selecto::Components::Renderer::Builder->query_options_control($prepared_a), qr/value="duckdb" checked/,
    'rendering A after B retains its selected backend');
unlike(Selecto::Components::Renderer::Builder->query_options_control($prepared_b), qr/value="duckdb" checked/,
    'rendering B retains its default backend');
$clean_shared->('preparing and rendering both leaves shared config clean');
# Defensive public engine calls also create a request copy.
$config->engine($controller_a, {%base, backend => 'duckdb'});
$config->engine($controller_b, {%base, backend => 'postgresql'});
Selecto::Components::QueryOptions->fingerprint($config);
Selecto::Components::Renderer::Builder->query_options_hidden({config => $config});
$clean_shared->('direct engine calls and read helpers do not mutate shared config');

# Page title uses the configured title or explicitly supplied original domain.
my $alternate_contract = $live->domain->contract;
$alternate_contract->{extensions}{i18n}{terms}{'domain.title'} = {default => 'Duck Explorer'};
my $alternate_domain = Selecto::Domain->parse($alternate_contract, strict => 1);
my $alternate = Selecto::Engine->new(domain => $alternate_domain, adapter => $snapshot->adapter);
my $title_config = Selecto::Components::Config->new(%$config,
    engine_factory => sub ($controller, $context) { $alternate });
my $title_explorer = Selecto::Components::Explorer->new(config => $title_config);
like(Selecto::Components::Renderer->page($title_explorer->model($c, \%base)), qr/<h1>Host Explorer<\/h1>/,
    'alternative domain title cannot rename host page');
$title_config->label_domain($live->domain);
$title_config->localizer(sub ($key, $default, $context) { $key eq 'asof.domain.title' ? 'Localized host' : $default });
like(Selecto::Components::Renderer->page($title_explorer->model($c, \%base)), qr/<h1>Localized host<\/h1>/,
    'original label domain supplies localized title');

# Canonical engine reads get URL options and the raw JSON query together.
my @canonical;
my $canonical_contract = $live->domain->contract;
$canonical_contract->{domain_version} = '1.0.0';
$canonical_contract->{domain_fingerprint} = 'sha256:queryopts-test';
my $canonical_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($canonical_contract, strict => 1), adapter => $snapshot->adapter);
my $canonical_config = Selecto::Components::Config->new(%$config,
    canonical_api_path => '/api/events', canonical_authorizer => sub { 1 },
    canonical_publication => sub { 'test-publication' },
    engine_factory => sub ($controller, $context) {
        push @canonical, $context;
        return $canonical_engine;
    });
Selecto::Components::Canonical->register($app->routes, $canonical_config, '/api/events');
$t->get_ok('/api/events/explorer?backend=duckdb')->status_is(200);
is $canonical[-1]{query_options}{backend}, 'duckdb', 'canonical metadata factory gets options';
$t->post_ok('/api/events/query?backend=duckdb' => {'X-CSRF-Token' => $csrf} => json => {format => 'selecto.remote-query', format_version => 1, domain => {fingerprint => $canonical_engine->domain->fingerprint}, query => {select => ['id']}})->status_is(200);
is_deeply $canonical[-1]{input}{query}{select}, ['id'], 'canonical factory gets raw JSON input';
is $canonical[-1]{query_options}{backend}, 'duckdb', 'canonical JSON factory keeps URL choice';

# Canned pages use the same host context before HTTP and per-message reads.
my @canned;
my $page = Selecto::CannedPage->new(id => 'queryopts', domain => $live->domain,
    dataset => {query => $live->query, entity_key => ['id']},
    views => [{id => 'rows', kind => 'detail', query => $live->query->select('id')}], controls => []);
my $component = Selecto::Components::CannedPage->new(page => $page, path => '/canned-options',
    websocket_mode => 'public', websocket_enabled => 1, query_options => $config->query_options,
    engine_factory => sub ($controller, $context) {
        push @canned, $context->{query_options}{backend};
        return $context->{query_options}{backend} eq 'duckdb' ? $snapshot : $live;
    });
$app->routes->get('/canned-options')->to(cb => sub ($controller) { $component->handle($controller) });
$app->routes->websocket('/canned-options/ws')->to(cb => sub ($controller) { $component->handle_websocket($controller) });
$t->get_ok('/canned-options?backend=duckdb')->status_is(200)->element_exists('input[data-sc-query-option][checked]');
is $canned[-1], 'duckdb', 'canned HTTP factory gets options';
$t->websocket_ok('/canned-options/ws')->send_ok({text => encode_json({backend => 'duckdb', selecto_request_id => 1})})->message_ok;
is $canned[-1], 'duckdb', 'canned socket factory gets message options';
like decode_json($t->message->[1])->{content}, qr/value="duckdb" checked/, 'canned message renders its request option';
$t->send_ok({text => encode_json({backend => 'postgresql', selecto_request_id => 2})})->message_ok;
is $canned[-1], 'postgresql', 'canned socket next message gets different options';
unlike decode_json($t->message->[1])->{content}, qr/value="duckdb" checked/, 'canned next message renders its own default';
ok !exists($component->{_query_options_context}), 'shared canned component has no message option state';
$t->finish_ok;

# Action discovery, form loading, lookups and record editor callbacks use the page choice.
my $actions_app = TestSelectoComponents::app();
my $actions_c = $actions_app->build_controller;
my $actions_config = $actions_c->selecto_components_explorer('products')->config;
my $original_factory = $actions_config->engine_factory;
my @action_options;
$actions_config->query_options($config->query_options);
$actions_config->engine_factory(sub ($controller, $context) {
    push @action_options, $context->{query_options}{backend};
    return $original_factory->($controller);
});
$actions_config->action_authorizer(sub ($controller, $request) {
    is $controller->stash('selecto_components_query_options')->{backend}, 'duckdb', 'action authorizer sees options';
    return 'enabled';
});
$actions_config->action_form_resolvers({edit_one_product => sub { {fixed_inputs => {}} }});
my $at = Test::Mojo->new($actions_app);
$at->get_ok('/explore/products?q=1&backend=duckdb&field=id&field=action%3Aedit_one_product')->status_is(200)
    ->element_exists('form[data-sc-action-form] input[data-sc-query-option-value][name=backend][value=duckdb]');
$at->get_ok('/explore/products/actions/edit_one_product/form?selected_id=101&backend=duckdb')->status_is(200);
is $action_options[-1], 'duckdb', 'action form factory gets page option';
$at->get_ok('/explore/products/actions/consolidate/lookups/carrier_party_id?q=north&selected_id=101&backend=duckdb')
    ->status_is(200)->json_is('/results/0/value', '501');
is $action_options[-1], 'duckdb', 'action lookup factory gets page option';
$at->get_ok('/explore/products/records/101/edit?editor=product_profile&backend=duckdb')->status_is(200)
    ->element_exists('form[data-sc-record-editor-form] input[name=backend][value=duckdb]');
is $action_options[-1], 'duckdb', 'record editor factory gets page option';

# Traditional factories without declarations keep their historical argument count.
my $legacy = Selecto::Components::Config->new(%$config, query_options => [], max_export_rows => 100, engine_factory => sub {
    is scalar(@_), 1, 'undeclared legacy explorer factory gets one argument';
    for (1..2) { next }
    return $live;
});
$legacy->engine($c, {});

# Existing explorer without declarations keeps its prior title, rows and URLs.
$t->get_ok('/seeded?q=1&field=id')->status_is(200)->element_exists_not('[data-sc-query-option]');
unlike $t->tx->res->body, qr/sc-results-note/, 'ordinary explorer has no note';
done_testing;
