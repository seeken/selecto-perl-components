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
like $page, qr{/selecto-components/api-console\.css\?v=20260831-2},
    'page loads the versioned shared stylesheet';
like $page, qr{/selecto-components/api-console\.js\?v=20260831-2},
    'page loads the versioned shared JavaScript';

$page = Selecto::Components::APIConsole->page(
    base_path => '/api2/client/v1',
    title => '<Client & API>',
);
unlike $page, qr{<Client & API>}, 'console title is not emitted as executable markup';
like $page, qr{&lt;Client &amp; API&gt;}, 'console title is HTML escaped';

for my $invalid ('api2/load/v1', '/api2//load/v1', '/api2/load/v1?x=1') {
    eval { Selecto::Components::APIConsole->page(base_path => $invalid) };
    like "$@", qr/base_path/, "invalid base path $invalid is rejected";
}

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
