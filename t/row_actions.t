use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config ();
use Selecto::Components::RowActions ();

my $domain = TestSelectoComponents::domain();
my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'products',
);
my $catalog = Selecto::Components::RowActions->catalog($domain, $config);
is_deeply [map { $_->{id} } @$catalog], [qw(open_product open_product_page)],
    'validated link and iframe-modal actions enter the row-action catalog';

my $action = Selecto::Components::RowActions->find(
    $domain, 'open_product', $config,
);
my $resolved = Selecto::Components::RowActions->resolve_iframe_modal(
    $action,
    {product_id => 17, product_label => q{A&B / special}},
    [
        {field => 'id', key => 'product_id'},
        {field => 'product_name', key => 'product_label'},
    ],
);
is_deeply $resolved, {
    type => 'iframe_modal',
    url => '/products/maint?id=17&name=A%26B%20%2F%20special',
    title => 'Product A&B / special',
    size => 'fullscreen',
    referrer_policy => 'same-origin',
    navigation_enabled => 1,
}, 'iframe-modal URLs are encoded while their visible titles retain the row value';

is(
    Selecto::Components::RowActions->resolve_iframe_modal(
    $action,
    {product_id => 17, product_label => undef},
    [
        {field => 'id', key => 'product_id'},
        {field => 'product_name', key => 'product_label'},
    ],
    ),
    undef,
    'a row with a missing required value is not made clickable',
);

my $link_action = Selecto::Components::RowActions->find(
    $domain, 'open_product_page', $config,
);
is_deeply(
    Selecto::Components::RowActions->resolve_external_link(
        $link_action,
        {product_id => 17},
        [{field => 'id', key => 'product_id'}],
    ),
    {url => '/products/maint?id=17', target => '_self'},
    'external-link row actions remain supported alongside modal actions',
);

is(
    Selecto::Components::RowActions->safe_url('javascript:alert(1)'), undef,
    'executable URL schemes are rejected again at the rendering boundary',
);
is(
    Selecto::Components::RowActions->safe_url('//evil.example/path'), undef,
    'protocol-relative row-action URLs are rejected',
);
is(
    Selecto::Components::RowActions->safe_url('https://example.test/product/17'),
    'https://example.test/product/17',
    'explicit HTTPS destinations remain available',
);

done_testing;
