use 5.034;
use strict;
use warnings;
use utf8;
use FindBin ();
use JSON::PP ();
use Storable qw(dclone);
use Test::More;
use Test::Mojo;
use Selecto::Components::Templates::AuthoringPreview ();
use Selecto::Components::Templates::AuthoringPreviewHost ();

my $preview = Selecto::Components::Templates::AuthoringPreview->new;
my $request = {
    schema => 'selecto.template.authoring-request.v1',
    source => '<template name="example" version="1"><state name="title" type="string" default="Perl &amp; café" /><h2>{{ state.title }}</h2></template>',
    domains => {}, samples => {}, templates => {}, inputs => {},
    capabilities => {
        schema => 'selecto.template.capabilities.v1',
        features => [qw(query.select query.order query.pagination runtime.state render.element render.component render.include render.slot)],
        limits => {sources => 4, selections_per_source => 16, page_size => 10, collections_per_source => 1, collection_depth => 1, selections_per_collection => 1},
        renderer => {map {my $kind = $_; $kind => {map {$_ => $preview->registrations->{$kind}{$_}{contract}}
            keys %{$preview->registrations->{$kind}}}} qw(components elements)},
    },
};
$request->{capabilities}{renderer}{limits} = {nodes => 128, depth => 16, expanded_nodes => 2048};
my $result = $preview->observe($request);
ok $result->{ok}, 'actual Perl compiler and runtime produce a preview';
is $result->{runtime}, 'perl', 'observation identifies its real runtime';
is $result->{snapshot}{state}{title}, 'Perl & café', 'native runtime mounts typed state';
like $result->{html}, qr{<h2>Perl &amp; café</h2>}, 'native Perl renderer escapes text';
is $result->{source_fingerprint}, Selecto::Templates->fingerprint($result->{ast}), 'canonical AST has an independently computed fingerprint';
is $result->{registrations}{components}{Card}{version}, '1.0.0', 'host reports an installed component version';

my $hostile = dclone($request);
$hostile->{source} =~ s/Perl &amp; café/&lt;script&gt;bad&lt;\/script&gt;/;
my $escaped = $preview->observe($hostile);
ok $escaped->{ok}, 'hostile text remains an ordinary string';
unlike $escaped->{html}, qr{<script>}, 'synthetic state cannot inject active markup';

my $unknown = dclone($request);
$unknown->{source} =~ s{<h2>.*?</h2>}{<script />};
my $rejected = $preview->observe($unknown);
ok !$rejected->{ok}, 'unsafe render node rejects';
is $rejected->{diagnostic}{code}, 'unavailable_render_node', 'real compiler diagnostic is returned';

my $contract = dclone($request);
$contract->{capabilities}{renderer}{components}{Card}{props}{unsafe} = 'string';
is $preview->observe($contract)->{diagnostic}{code}, 'native_component_contract_mismatch', 'caller cannot invent a native component contract';
$contract->{capabilities}{renderer}{components}{Unknown} = delete $contract->{capabilities}{renderer}{components}{Card};
is $preview->observe($contract)->{diagnostic}{code}, 'unavailable_native_component', 'uninstalled native components reject before rendering';

my $private = dclone($request);
$private->{database_url} = 'never-connect';
is $preview->observe($private)->{diagnostic}{code}, 'invalid_preview_request', 'application connection fields are not accepted';
my $large = dclone($request);
$large->{source} = 'x' x 65_537;
is $preview->observe($large)->{diagnostic}{code}, 'source_too_large', 'source budget enforced';

my $composed = dclone($request);
open my $fh, '<:raw', "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/domains.json" or die $!;
my $catalog = JSON::PP->new->utf8->decode(do {local $/; <$fh>});
close $fh;
$composed->{domains}{orders} = $catalog->{domains}{orders};
$composed->{samples}{orders} = [{id => 1, order_number => 'PO-SYNTHETIC', status => 'Draft'}];
$composed->{source} = '<template name="parent" version="1"><source name="orders" domain="orders" page-size="3"><select>id</select><order-by>id asc</order-by></source><include template="summary" order={orders} /></template>';
$composed->{templates}{summary} = '<template name="summary" version="1"><input name="order" type="source&lt;orders&gt;" /><require source="order">id, order_number</require><p>{{ order.order_number }}</p></template>';
my $nested = $preview->observe($composed);
ok $nested->{ok}, 'child-owned field requirement compiles in real Perl host' or diag explain $nested->{diagnostic};
is_deeply $nested->{manifest}{sources}[0]{query}{select}, [qw(id order_number)], 'composed child contributes the required field';
like $nested->{html}, qr{<p>PO-SYNTHETIC</p>}, 'Perl renders included template with the projected synthetic source row';
ok $nested->{manifest}{dependency_locks}[0]{fingerprint}, 'compiled parent pins the child dependency';

my $cycle = dclone($composed);
$cycle->{templates}{summary} = '<template name="summary" version="1"><include template="summary" /></template>';
is $preview->observe($cycle)->{diagnostic}{code}, 'include_cycle', 'recursive template catalogs reject';

my $installed = Selecto::Components::Templates::AuthoringPreview::_builtins();
my $first = $installed->{components}{Card};
$installed->{components}{Card} = {default => '2.0.0', versions => {
    '1.0.0' => $first,
    '2.0.0' => {%$first, render => sub {return Selecto::Components::Templates::Renderer->safe_html('<article>Version two</article>')}}
}};
my $versioned = Selecto::Components::Templates::AuthoringPreview->new(registrations => $installed);
my $version_request = dclone($request);
$version_request->{source} = '<template name="versioned" version="1"><Card /></template>';
$version_request->{registrations} = $preview->registrations;
like $versioned->observe($version_request)->{html}, qr{<section class="card">}, 'old lock selects old callback despite newer installed default';
$version_request->{registrations} = $versioned->registrations;
like $versioned->observe($version_request)->{html}, qr{<article>Version two</article>}, 'new lock selects second callback';
delete $installed->{components}{Card}{versions}{'1.0.0'};
$version_request->{registrations} = $preview->registrations;
is $versioned->observe($version_request)->{diagnostic}{code}, 'unavailable_native_component', 'removed pinned version does not fall forward';
$installed->{components}{Card}{versions}{'2.0.0'}{targets} = ['perl'];
$version_request->{registrations} = $versioned->registrations;
is $versioned->observe($version_request)->{diagnostic}{code}, 'native_only_component', 'native-only Perl component cannot claim portability';

local $ENV{SELECTO_TEMPLATE_PREVIEW_TOKEN} = 'test-only-token-' . ('x' x 40);
my $t = Test::Mojo->new(Selecto::Components::Templates::AuthoringPreviewHost->new);
$t->get_ok('/health')->status_is(200)->json_is('/runtime', 'perl');
$t->post_ok('/observe' => json => $request)->status_is(403);
my $headers = {'X-Selecto-Preview-Token' => $ENV{SELECTO_TEMPLATE_PREVIEW_TOKEN}};
$t->post_ok('/observe' => $headers => json => $request)->status_is(200)->json_is('/ok', JSON::PP::true)->json_is('/runtime', 'perl');
$t->post_ok('/observe' => {%$headers, Origin => 'https://untrusted.invalid'} => json => $request)->status_is(403);
$t->post_ok('/observe' => $headers => 'text')->status_is(415);
$t->post_ok('/observe' => $headers => json => $unknown)->status_is(200)->json_is('/ok', JSON::PP::false);
done_testing;
