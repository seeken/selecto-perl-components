use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config ();

# max_export_rows caps every all-rows export query (CSV, TSV, JSON and XLSX)
# while leaving paginated pages alone.
my $app = Mojolicious->new;
$app->secrets(['export-limit-test']);
my $config = TestSelectoComponents::config();
$config->{max_export_rows} = 5;
$app->plugin('Selecto::Components' => {explorers => {products => $config}});
my $t = Test::Mojo->new($app);

my $url = '/explore/products?q=1&view=detail&field=product_name&field=unit_price' .
    '&order=product_name&direction=asc&limit=10&page=1';
for my $format (qw(csv tsv json xlsx)) {
    $t->get_ok("$url&format=$format")->status_is(200);
    is $TestSelectoComponents::Adapter::LAST_DATA_QUERY->limit_value, 5,
        "$format export is capped at max_export_rows";
}
$t->get_ok($url)->status_is(200);
is $TestSelectoComponents::Adapter::LAST_DATA_QUERY->limit_value, 10,
    'a paginated page keeps its own page size';

for my $bad (0, -1, 'many', 10_000_001) {
    my $error = eval { Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products', max_export_rows => $bad); 1 } ? '' : $@;
    like $error, qr/max_export_rows must be a positive integer/, "max_export_rows rejects $bad";
}

done_testing;
