use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use lib 't/lib';
use TestSelectoComponents;

my $app = Mojolicious->new;
$app->secrets(['route-bridge-test']);
my $protected = $app->routes->under('/secured')->to(cb => sub {
    my ($controller) = @_;
    return 1 if ($controller->req->headers->header('X-Test-Authorized') // '') eq 'yes';
    $controller->render(text => 'Denied by host', status => 401);
    return undef;
});
my $config = TestSelectoComponents::config();
$config->{path} = '/secured/products';
$app->plugin('Selecto::Components' => {
    route_bridge => {routes => $protected, prefix => '/secured'},
    explorers => {products => $config},
});

my $t = Test::Mojo->new($app);
$t->get_ok('/secured/products')->status_is(401)->content_is('Denied by host');
$t->get_ok('/secured/products' => {'X-Test-Authorized' => 'yes'})
    ->status_is(200)
    ->element_exists('section#selecto-channel-products')
    ->content_like(qr{hx-ws:connect="/secured/products/ws"});
$t->get_ok('/products')->status_is(404);

done_testing;
