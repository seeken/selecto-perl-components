use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Limits;
use Selecto::Components::State;
use Selecto::Components::BucketParser;

my $domain = TestSelectoComponents::domain();
my $config = Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products', title => 'Products',
    limits => Selecto::Limits->new(max_fields => 3, max_filter_values => 2, max_value_bytes => 4));
for my $input (
    {q => 1, field => [('id') x 4]},
    {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_values_json => '["a","b","c"]'},
    {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_values_json => '["abcde"]'},
    {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_value => 'a,b,c'},
) {
    ok !Selecto::Components::State->from_input($config, $domain, $input)->valid, 'over-budget state is refused';
}
is_deeply(Selecto::Components::BucketParser->parse(join(',', (1) x 101)), [], 'bucket count bounded before expansion');
is_deeply(Selecto::Components::BucketParser->parse('9' x 16), [], 'bucket digits bounded before numeric coercion');

ok(Selecto::Components::State->from_input($config, $domain, {q => 1, field => 'id', filter_field => 'product_name', filter_op => 'in', filter_values_json => '["a","b"]'})->valid, 'membership at configured ceiling remains usable');

my $options = TestSelectoComponents::config();
delete $options->{websocket_mode};
my $bad = eval { Mojolicious->new->plugin('Selecto::Components' => {explorers => {products => $options}}); 1 };
ok !$bad, 'default protected sockets require explicit live authorization';
like $@, qr/protected Explorer/, 'startup failure identifies migration';
$options->{websocket_enabled} = 0;
my $off = Mojolicious->new;
$off->plugin('Selecto::Components' => {explorers => {products => $options}});
Test::Mojo->new($off)->get_ok('/explore/products')->status_is(200)->element_exists_not('[hx-ws\\:connect]');

done_testing;
