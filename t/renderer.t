use 5.034;
use strict;
use warnings;
use Test::More;
use Mojo::JSON qw(decode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config ();
use Selecto::Components::Explorer ();
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

my $measure_table = Selecto::Components::Renderer->_table(
    {
        columns => [
            {key => 'category', label => 'Category', type => 'string'},
            {key => 'revenue', label => 'Revenue', type => 'decimal', measure => 1},
            {key => 'latest_pickup', label => 'Latest pickup', type => 'datetime', measure => 1},
        ],
        records => [{
            category => 'SUV', revenue => '1234.50', latest_pickup => '2026-09-02 10:30:00',
        }],
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
like $measure_table,
    qr{<th scope="col" class="sc-numeric-measure">Revenue</th>},
    'numeric measure headings receive right-alignment semantics';
like $measure_table,
    qr{<td class="sc-numeric-measure">1234\.50</td>},
    'numeric measure values receive right-alignment semantics';
like $measure_table,
    qr{<th scope="col">Latest pickup</th>.*<td>2026-09-02 10:30:00</td>}s,
    'non-numeric measures retain normal alignment';

my $continued_result = {
    rollup => 1,
    group_count => 3,
    rollup_key => '__selecto_rollup_grouping',
    columns => [
        {key => 'region', field => 'region', label => 'Region', type => 'string'},
        {key => 'city', field => 'city', label => 'City', type => 'string'},
        {key => 'status', field => 'status', label => 'Status', type => 'string'},
        {key => 'count', label => 'Orders', type => 'integer', measure => 1},
    ],
    records => [{
        region => 'East', city => 'Boston', status => 'Ready', count => 7,
        __selecto_rollup_grouping => 0,
        __selecto_rollup_level => 3,
    }],
};
is Selecto::Components::Explorer::_prepend_continued_rollup_records(
    $continued_result, $continued_result->{records},
), 2, 'a page beginning at level three restores both missing parent headers';
is_deeply [map { $_->{__selecto_rollup_level} } @{$continued_result->{records}}],
    [1, 2, 3], 'continued parent headers preserve hierarchy order';
$continued_result->{drilldowns} = [
    [[view => 'detail', filter_field => 'region', filter_value => 'East']],
    [[], [view => 'detail', filter_field => 'city', filter_value => 'Boston']],
    [[]],
];
my $continued_table = Selecto::Components::Renderer->_table(
    $continued_result,
    {
        bulk_actions => [],
        config => $config,
        state => $state,
        domain => $domain,
        canonical_url => '/explore/products',
    },
);
is scalar(() = $continued_table =~ /data-rollup-continued="1"/g), 2,
    'each restored parent is rendered as continuation context';
like $continued_table,
    qr{sc-rollup-continued-label">East <span>\(continued\)</span>},
    'the outer parent header is visibly marked continued';
like $continued_table,
    qr{sc-rollup-continued-label">Boston <span>\(continued\)</span>},
    'the inner parent header is visibly marked continued';
like $continued_table,
    qr{sc-rollup-continued-measure">-</span>},
    'continued context rows do not repeat an inaccurate aggregate value';
is scalar(() = $continued_table =~ /<form class="sc-drilldown-form"/g), 2,
    'each continued header retains its drill-down control';
like $continued_table,
    qr{sc-rollup-continued[^>]*>.*?name="filter_field" value="region".*?\(continued\).*?</form>}s,
    'continued parent links retain their governed group filters';

my $grid_state = Selecto::Components::State->from_input($config, $domain, {
    q => 1,
    view => 'aggregate',
    aggregate_grid => 1,
    aggregate_grid_colorize => 1,
    aggregate_grid_color_scale => 'linear',
    field => 'product_name',
    group => ['category.category_name', 'units_in_stock'],
    measure => 'count',
    filter_field => 'unit_price',
    filter_op => 'gte',
    filter_value => '10',
    order => 'product_name',
    limit => 25,
    page => 1,
});
my $grid_built = {
    aggregate_grid => 1,
    rollup => 1,
    group_count => 2,
    columns => [
        {
            key => 'category__category_name', field => 'category.category_name',
            label => 'Category', type => 'string',
        },
        {
            key => 'units_in_stock', field => 'units_in_stock',
            label => 'Stock', type => 'integer',
        },
        {key => 'count', label => 'Products', type => 'integer', measure => 1},
    ],
};
my $grid_records = [
    {
        category__category_name => 'East', units_in_stock => 1, count => 2,
        __selecto_rollup_level => 2,
    },
    {
        category__category_name => 'East', units_in_stock => 2, count => 20,
        __selecto_rollup_level => 2,
    },
    {
        category__category_name => 'West', units_in_stock => 1, count => 5,
        __selecto_rollup_level => 2,
    },
    {
        category__category_name => 'East', units_in_stock => undef, count => 22,
        __selecto_rollup_level => 1,
    },
    {
        category__category_name => undef, units_in_stock => undef, count => 27,
        __selecto_rollup_level => 0,
    },
];
my $grid_drilldowns = Selecto::Components::Explorer::_drilldowns(
    $grid_state, $grid_built, $grid_records,
);
my $grid_data = Selecto::Components::Explorer::_aggregate_grid_data(
    $grid_state, $grid_built, $grid_records, $grid_drilldowns,
);
is scalar(@{$grid_data->{rows}}), 2,
    'aggregate grid derives unique row-axis values from detail-level rollups';
is scalar(@{$grid_data->{columns}}), 2,
    'aggregate grid derives unique column-axis values from detail-level rollups';
is $grid_data->{maximum_positive}, 20,
    'aggregate grid records the maximum positive measure for heat scaling';
my $grid_result = {
    %$grid_built,
    grid_data => $grid_data,
    records => $grid_records,
    drilldowns => $grid_drilldowns,
    total_count => 5,
    total_pages => 1,
    elapsed_ms => 3,
};
my $grid_model = {
    bulk_actions => [],
    config => $config,
    state => $grid_state,
    domain => $domain,
    canonical_url => '/explore/products',
    result => $grid_result,
};
my $grid_html = Selecto::Components::Renderer::Results->_grid(
    $grid_result, $grid_model,
);
like $grid_html, qr/<strong>Aggregate Grid<\/strong><span>Linear heat scale<\/span>/,
    'aggregate grid identifies its active heat scale';
like $grid_html, qr/class="sc-table-wrap sc-aggregate-grid-wrap"/,
    'aggregate grid renders in its sticky scroll viewport';
like $grid_html, qr/data-sc-grid-heat="10"/,
    'the smallest positive grid value uses the low heat color';
like $grid_html, qr/data-sc-grid-heat="64"/,
    'the maximum grid value uses the high heat color';
like $grid_html,
    qr{<th scope="row">.*?filter_field" value="unit_price".*?filter_field" value="category\.category_name".*?>East</button>}s,
    'row-axis labels drill down with the row group and existing filters';
like $grid_html,
    qr{<th scope="col">.*?filter_field" value="unit_price".*?filter_field" value="units_in_stock".*?>1</button>}s,
    'column-axis labels drill down with the column group and existing filters';
like $grid_html,
    qr{class="sc-grid-cell sc-grid-empty-cell"},
    'missing row-column combinations remain visibly empty and non-clickable';
is(
    Selecto::Components::Renderer::Results->_pagination($grid_model),
    '',
    'a full aggregate grid does not render misleading page controls',
);

my $grid_export = decode_json(
    Selecto::Components::Explorer->new(config => $config)->json($grid_model)
);
is_deeply $grid_export->{columns}, ['Category', '1', '2'],
    'grid JSON export preserves the rendered matrix columns';
is $grid_export->{row_count}, 2,
    'grid JSON export writes one row per rendered row-axis value';
is $grid_export->{rows}[0]{Category}, 'East',
    'grid JSON export preserves the row-axis label';
is $grid_export->{rows}[0]{2}, 20,
    'grid JSON export places measures under their column-axis value';
ok !defined($grid_export->{rows}[1]{2}),
    'grid JSON export preserves an empty matrix cell as null';

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
