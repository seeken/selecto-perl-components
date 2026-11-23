use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(from_json);
my $app = do './t/browser/fixtures/hbar.pl' or die $@ || $!;
my $t = Test::Mojo->new($app);
my %input = (q => 1, field => 'id', view => 'graph', chart_type => 'horizontal_bar', group => 'customer_id',
    measure => 'revenue', order => 'measure:revenue', direction => 'desc', limit => 15);
my $get = sub {
    $t->get_ok('/sales' => form => {%input, @_})->status_is(200)->element_exists('[data-sc-chart]');
    return from_json($t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data'));
};
my $data = $get->();
is scalar(@{$data->{labels}}), 15, 'limit counts categories';
is_deeply $data->{datasets}[0]{data}, [map { $_ * 20 + 1 } reverse 132 .. 146], 'largest first before limiting';
$t->text_is('.sc-chart-categories', 'Top 15 of 146 categories');
is $data->{axes}{y}{unit}{code}, 'USD', 'horizontal value axis carries its unit';
is $data->{datasets}[0]{yAxisID}, 'y', 'declared value axis is available to the browser';
my $form = $t->tx->res->dom->at('[data-sc-graph-drilldown="0"]');
my %drill;
push @{$drill{$_->attr('name')}}, $_->attr('value') for @{$form->find('input')};
is_deeply $drill{filter_field}, ['customer_id'], 'drilldown uses dimension key';
is_deeply $drill{filter_value}, ['146'], 'first bar retains its own key after ordering and limiting';
$t->get_ok('/sales' => form => \%drill)->status_is(200);
is $t->tx->res->dom->find('.sc-results tbody tr')->size, 2, 'drilldown executes for both original detail rows';
$data = $get->(group => ['customer_id', 'channel'], graph_series_group => 'channel');
is scalar(@{$data->{labels}}), 15, 'breakouts still limit categories, not cells';
is scalar(@{$data->{datasets}}), 2, 'both series retained';
is_deeply [map { scalar @{$_->{data}} } @{$data->{datasets}}], [15, 15], 'no partial category at the limit';
is_deeply [map { $_->{data}[-1] } @{$data->{datasets}}], [1321, 1320], 'last category retains both cells';
$data = $get->(limit => 500, order => 'customer_id', direction => 'asc');
is scalar(@{$data->{labels}}), 146, 'all categories when under limit';
is_deeply [@{$data->{labels}}[0, 1]], ['Customer 001', 'Customer 001'],
    'distinct dimension keys with equal labels remain distinct categories';
$t->text_is('.sc-chart-categories', 'Showing 146 of 146 categories');
$data = $get->(measure => ['revenue', 'volume'], measure_axis => ['left', 'right']);
is_deeply [map { $_->{yAxisID} } @{$data->{datasets}}], ['y', 'y1'], 'horizontal dual axes retained';
is $data->{axes}{y1}{unit}{kind}, 'count', 'second axis retains count unit';
$data = $get->(measure => ['revenue', 'revenue'], measure_series_id => ['first', 'second'], measure_stack => ['money', 'money']);
ok $data->{axes}{y}{stacked}, 'horizontal stack has a stacked value axis';
is_deeply [map { $_->{stack} } @{$data->{datasets}}], ['money', 'money'], 'horizontal stack groups retained';
# Past the grid cell cap a graph reads no further, so its total is a lower bound.
$t->get_ok('/sales-capped' => form => {%input})->status_is(200);
is scalar(@{from_json($t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data'))->{labels}}), 15,
    'capped graph still shows its top categories';
$t->text_is('.sc-chart-categories', 'Top 15 of more than 100 categories');
done_testing;
