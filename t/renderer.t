use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config ();
use Selecto::Components::Renderer ();
use Selecto::Components::Renderer::Results ();
use Selecto::Components::State ();
use Selecto::Components::Util qw(html_escape humanize);

is humanize('status_code'), 'Status Code', 'underscores become title-cased words';
is humanize('query-library.view'), 'Query Library View',
    'hyphens and dots become title-cased words';
is html_escape(q{<script>alert(1)</script>}), '&lt;script&gt;alert(1)&lt;/script&gt;',
    'html_escape encodes angle brackets';

my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'products',
    title => q{<img src=x onerror="alert(1)">},
);
my $domain = TestSelectoComponents::domain();
my $state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'not-a-view',
    field => 'product_name',
    filter_field => 'product_name',
    filter_op => 'eq',
    filter_value => q{<script>alert(1)</script>},
});
my $html = Selecto::Components::Renderer->page({
    config => $config,
    state => $state,
    domain => $domain,
    canonical_url => q{/explore/products?q=1&filter_value=<script>},
    runtime_error => q{<script>runtime()</script>},
    action_notice => q{saved <b>ok</b>},
});

unlike $html, qr/<script>alert/, 'hostile filter values do not emit a raw script tag';
unlike $html, qr/<script>runtime/, 'runtime errors do not emit a raw script tag';
unlike $html, qr/<img src=x/, 'page HTML does not emit a raw image title';
like $html, qr/&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/,
    'explorer title is HTML-escaped';
like $html, qr/&lt;script&gt;alert\(1\)&lt;\/script&gt;/,
    'filter values are HTML-escaped in the builder';
like $html, qr/&lt;script&gt;runtime\(\)&lt;\/script&gt;/,
    'runtime errors are HTML-escaped';
like $html, qr/saved &lt;b&gt;ok&lt;\/b&gt;/,
    'action notices are HTML-escaped';
like $html, qr/data-selecto-url="\/explore\/products\?q=1&amp;filter_value=&lt;script&gt;"/,
    'canonical URLs are escaped in attributes';

my $theme_controller = bless {}, 'TestSelectoComponents::ThemeController';
my $theme_resolver_controller;
my $theme_config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'themed-products',
    path => '/explore/themed-products',
    theme_resolver => sub {
        ($theme_resolver_controller) = @_;
        return {
            scheme => 'light',
            primary => '#123456',
            secondary => '#ABCDEF',
            on_primary => '#FFFFFF',
        };
    },
    page_shell_resolver => sub {
        return {
            head_start_html => '<meta name="host-shell-start" content="enabled">',
            head_html => '<meta name="host-shell" content="enabled">',
            body_start_html => '<nav data-host-shell>Host navigation</nav>',
            body_class => 'host-shell host-shell-light',
            content_class => 'standard-host-page',
        };
    },
)->for_request($theme_controller);
my $theme_state = Selecto::Components::State->from_input($theme_config, $domain, {});
my $themed_html = Selecto::Components::Renderer->page({
    config => $theme_config,
    state => $theme_state,
    domain => $domain,
    canonical_url => '/explore/themed-products',
});
like $themed_html,
    qr{<html lang="en" data-sc-color-scheme="light" style="--sc-brand:#123456;--sc-accent:#ABCDEF;--sc-on-brand:#FFFFFF">},
    'request-resolved theme colors are rendered as scoped Explorer variables';
like $themed_html, qr{<meta name="host-shell" content="enabled"></head>},
    'trusted host shell head markup is included in the full page';
like $themed_html,
    qr{<meta name="host-shell-start" content="enabled"><link rel="stylesheet" href="/selecto-components/selecto-components\.css},
    'host dependencies can load before the portable component stylesheet';
like $themed_html,
    qr{<body class="host-shell host-shell-light"><nav data-host-shell>Host navigation</nav><main class="sc-page standard-host-page">},
    'trusted host navigation wraps the portable Explorer surface';
is $theme_resolver_controller, $theme_controller,
    'the theme resolver receives the request controller';

my $unsafe_theme = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'unsafe-theme',
    theme_resolver => sub { return {primary => 'red; background:url(x)'} },
);
my $theme_error = eval { $unsafe_theme->theme_style; undef } // $@;
like $theme_error, qr/theme primary must be a hexadecimal color/,
    'unsafe host theme values cannot enter an HTML style attribute';

my $unsafe_scheme = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'unsafe-scheme',
    theme_resolver => sub { return {scheme => 'light; color:red'} },
);
my $scheme_error = eval { $unsafe_scheme->theme_scheme; undef } // $@;
like $scheme_error, qr/theme scheme must be light or dark/,
    'theme schemes are restricted to the shared light and dark palettes';

my $unsafe_shell = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'unsafe-shell',
    page_shell_resolver => sub { return {body_class => 'ok" onclick="bad'} },
);
my $shell_error = eval { $unsafe_shell->page_shell; undef } // $@;
like $shell_error, qr/page shell body_class must contain CSS class names/,
    'host shell body classes cannot inject HTML attributes';

$unsafe_shell = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()},
    id => 'unsafe-content-shell',
    page_shell_resolver => sub { return {content_class => 'ok" onclick="bad'} },
);
$shell_error = eval { $unsafe_shell->page_shell; undef } // $@;
like $shell_error, qr/page shell content_class must contain CSS class names/,
    'host shell content classes cannot inject HTML attributes';

my $table = Selecto::Components::Renderer->_table(
    {
        columns => [{
            key => 'product_name',
            label => q{<b>Name</b>},
            field => 'product_name',
        }],
        records => [{product_name => q{<script>cell()</script>}}],
        drilldowns => [[]],
    },
    {
        bulk_actions => [],
        config => $config,
        state => $state,
        domain => $domain,
        canonical_url => '/explore/products',
    },
);
unlike $table, qr/<script>cell/, 'table cells do not emit raw scripts';
unlike $table, qr/<b>Name<\/b>/, 'column labels do not emit raw HTML';
like $table, qr/&lt;script&gt;cell\(\)&lt;\/script&gt;/,
    'table cell values are HTML-escaped';
like $table, qr/&lt;b&gt;Name&lt;\/b&gt;/,
    'column labels are HTML-escaped';

my $graph_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'graph',
    chart_type => 'bar',
    group => 'category.category_name',
    measure => 'count',
});
my $graph = Selecto::Components::Renderer::Results->_graph(
    {
        columns => [
            {key => 'category.category_name', label => 'Category'},
            {key => 'count', label => 'Product count', measure => 1},
        ],
        records => [{
            'category.category_name' => q{<img src=x onerror=alert(1)>},
            count => 3,
        }],
        drilldowns => [[]],
    },
    {
        config => $config,
        state => $graph_state,
        domain => $domain,
        canonical_url => '/explore/products',
    },
);
unlike $graph, qr/<img src=x/, 'chart labels do not emit raw HTML';
like $graph, qr/data-chart-data="[^"]*&lt;img src=x onerror=alert\(1\)&gt;/,
    'JSON chart data is HTML-escaped inside the attribute';

my $vin = Selecto::Components::Renderer::_html_display(
    {html_format => 'vin_last_six'},
    '1HGCM82633A004352',
);
like $vin, qr{1HGCM82633A<strong class="sc-vin-suffix">004352</strong>},
    'allowlisted VIN formatter still emits its bounded strong tag';
is(
    Selecto::Components::Renderer::_html_display(
        {html_format => 'vin_last_six'},
        q{<script>alert(1)</script>},
    ),
    html_escape(q{<script>alert(1)</script>}),
    'VIN formatter falls back to escaping values that are not 17-character VINs',
);

done_testing;
