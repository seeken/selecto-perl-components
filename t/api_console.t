use 5.034;
use strict;
use warnings;

use Test::More;
use Mojolicious;
use Selecto::Components::APIConsole ();

my $page = Selecto::Components::APIConsole->page(
    base_path => '/api2/load/v1/',
    title => 'Load API Console',
);
like $page, qr{data-selecto-api-console}, 'page exposes the framework-neutral mount point';
like $page, qr{data-api-base="/api2/load/v1"}, 'page normalizes the API base path';
like $page, qr{<html lang="en" data-sac-color-scheme="light">},
    'console pages use the shared light operational palette by default';
like $page, qr{/selecto-api-console/selecto-api-console\.css\?v=0\.2\.0},
    'page loads the versioned shared stylesheet';
like $page, qr{/selecto-api-console/selecto-api-console\.js\?v=0\.2\.0},
    'page loads the versioned shared JavaScript';

$page = Selecto::Components::APIConsole->page(
    base_path => '/api2/load/v1',
    title => 'Load API Console',
    theme => {
        scheme => 'light', primary => '#cc5500', secondary => '#dc8b52',
        on_primary => '#000000',
    },
    page_shell => {
        head_start_html => '<meta name="host-start" content="1">',
        head_html => '<meta name="host-end" content="1">',
        body_start_html => '<nav data-host-menu>Menu</nav>',
        body_class => 'cgt-host-menu-toolbar',
        content_class => 'cgt-mojo-page',
    },
);
like $page,
    qr{<html lang="en" data-sac-color-scheme="light" style="--sac-accent:#CC5500;--cgt-brand:#CC5500;--sac-teal:#DC8B52;--cgt-accent:#DC8B52;--sac-on-accent:#000000;--cgt-on-brand:#000000">},
    'semantic host colors become console and common menu variables';
like $page,
    qr{<meta name="host-start" content="1"><link rel="stylesheet" href="/selecto-api-console/},
    'host dependencies can load before the shared console assets';
like $page, qr{<meta name="host-end" content="1"></head>},
    'host compatibility markup follows the console assets';
like $page,
    qr{<body class="sac-body cgt-host-menu-toolbar"><nav data-host-menu>Menu</nav><main class="sac-app cgt-mojo-page"},
    'host navigation and the standard Mojo content class wrap the console';

$page = Selecto::Components::APIConsole->page(
    base_path => '/api2/client/v1',
    title => '<Client & API>',
);
unlike $page, qr{<Client & API>}, 'console title is not emitted as executable markup';
like $page, qr{&lt;Client &amp; API&gt;}, 'console title is HTML escaped';

for my $invalid ('api2/load/v1', '/api2//load/v1', '/api2/load/v1?x=1', '/api2/../admin') {
    eval { Selecto::Components::APIConsole->page(base_path => $invalid) };
    like "$@", qr/base_path/, "invalid base path $invalid is rejected";
}

eval {
    Selecto::Components::APIConsole->page(
        base_path => '/api2/load/v1', theme => {primary => 'red;display:none'},
    );
};
like "$@", qr/theme primary must be a hexadecimal color/,
    'unsafe tenant colors cannot enter the console style attribute';
eval {
    Selecto::Components::APIConsole->page(
        base_path => '/api2/load/v1',
        page_shell => {content_class => 'ok" onclick="bad'},
    );
};
like "$@", qr/page_shell content_class must contain CSS class names/,
    'unsafe host content classes cannot inject HTML attributes';

my $app = Mojolicious->new;
my $asset_path = Selecto::Components::APIConsole->install_assets($app);
ok -d $asset_path, 'API console installs its packaged static asset path';
is(
    Selecto::Components::APIConsole->install_assets($app),
    $asset_path,
    'installing API console assets is idempotent',
);
is(
    scalar(grep { $_ eq $asset_path } @{$app->static->paths}),
    1,
    'the shared static path is installed only once',
);

done_testing;
