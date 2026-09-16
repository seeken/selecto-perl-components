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
is_deeply [map { $_->{id} } @$catalog], [qw(edit_product open_product open_product_page)],
    'validated link, iframe-modal, and record-editor actions enter the row-action catalog';

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

is_deeply(
    Selecto::Components::RowActions->resolve_record_editor(
        {
            name => 'Edit product', type => 'record_editor',
            payload => {
                editor => 'product_profile', target_field => 'id',
                title => 'Edit {{product_name}}', size => 'lg',
                navigation_enabled => 1,
            },
        },
        {product_id => 17, product_label => 'Widget'},
        [
            {field => 'id', key => 'product_id'},
            {field => 'product_name', key => 'product_label'},
        ],
    ),
    {
        type => 'record_editor', editor => 'product_profile', target_id => 17,
        title => 'Edit Widget', size => 'lg', navigation_enabled => 1,
    },
    'record-editor row actions resolve a governed editor and stable target without a host URL',
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
