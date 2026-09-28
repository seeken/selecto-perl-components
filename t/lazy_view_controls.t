use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::DOM;
use lib 't/lib';
use TestSelectoComponents;

my $app = Mojolicious->new;
$app->secrets(['controls-test']);
my $allow = 1;
my $bridge = $app->routes->under('/secured')->to(cb => sub {
    return 1 if $allow;
    $_[0]->render(text => 'Denied', status => 403);
    return undef;
});
my $spec = TestSelectoComponents::config();
$spec->{path} = '/secured/products';
$app->plugin('Selecto::Components' => {
    route_bridge => {routes => $bridge, prefix => '/secured'},
    lazy_view_controls => 1, explorers => {products => $spec},
});
my $t = Test::Mojo->new($app);
$t->get_ok('/secured/products')->status_is(200)
    ->element_exists('[data-sc-result-view-panel="detail"] [data-sc-picker-root]')
    ->element_exists('[data-sc-result-view-panel="summary"][data-sc-view-lazy][hidden][disabled]')
    ->element_exists_not('[data-sc-result-view-panel="summary"] [data-sc-picker-root]');
my $csrf = $t->tx->res->dom->at('[data-sc-controls-csrf]')->attr('data-sc-controls-csrf');
ok length($csrf), 'lazy controls carry a CSRF token outside URL query fields';
my $input = {
    csrf_token => $csrf, q => 1, view => 'aggregate',
    field => ['product_name', 'product_name'], field_alias => ['First', 'Second'],
    group => ['category.category_name'], measure => ['count'],
    filter_field => ['product_name'], filter_op => ['eq'], filter_value => ['abc'],
    limit => 25, page => 1,
};
{
    no warnings 'redefine';
    local *TestSelectoComponents::Adapter::execute_query = sub { die "must not execute SQL for controls" };
    $t->post_ok('/secured/products/controls' => form => $input)->status_is(200)
        ->header_is('Cache-Control', 'no-store');
    my $html = $t->tx->res->json->{html};
    diag $t->tx->res->body unless defined $html;
    like $html, qr/data-sc-picker-kind="group"/, 'summary controls are built on demand';
    my $dom = Mojo::DOM->new($html);
    is_deeply [map { $_->attr('value') } @{$dom->find('input[name="field_alias"]')->to_array}],
        ['First', 'Second'], 'repeated detail columns and aliases survive switching';
    $t->post_ok('/secured/products/controls' => form => {%$input, view => 'detail'})
        ->status_is(200);
    like $t->tx->res->json->{html}, qr/data-sc-picker-kind="field"/, 'detail controls also load without a query';
    $t->post_ok('/secured/products/controls' => form => {%$input, field => 'secret_field'})
        ->status_is(422)->json_like('/error', qr/column is not available/);
}
$t->post_ok('/secured/products/controls' => form => {%$input, csrf_token => 'wrong'})
    ->status_is(403);
$t->post_ok('/secured/products/controls' => {Origin => 'https://elsewhere.invalid'} => form => $input)
    ->status_is(403);
$allow = 0;
$t->post_ok('/secured/products/controls' => form => $input)->status_is(403);
$allow = 1;
$t->get_ok('/secured/products?view=aggregate')->status_is(200)
    ->element_exists('[data-sc-result-view-panel="summary"] [data-sc-picker-root]')
    ->element_exists('[data-sc-result-view-panel="detail"][data-sc-view-lazy]');
done_testing;
