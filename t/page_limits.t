use 5.034;
use strict;
use warnings;
use Test::More;
use Mojo::DOM;
use Mojo::JSON qw(from_json);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::State;
use Selecto::Components::Renderer::Markup qw(_limit_options _limit_views);

# Summary pages have their own page sizes: group rows are not counted, so a
# bigger page shows a whole report at once.
my $domain = TestSelectoComponents::domain();
my $config = Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products');
my $state = sub { Selecto::Components::State->from_input($config, $domain, {q => 1, @_}) };

is_deeply [$config->page_limits('detail')], [25, 100], 'Detail keeps 25 rows, up to 100';
is_deeply [$config->page_limits('aggregate')], [250, 1000], 'Summary pages default to 250 rows, up to 1000';
is_deeply [$config->page_limits('graph')], [100, 100], 'a graph is held to max_limit as before';

my $summary = $state->(view => 'aggregate', group => 'category.category_name', measure => 'count');
is $summary->limit, 250, 'a summary with no size asks for 250 rows';
is $state->(view => 'aggregate', group => 'category.category_name', measure => 'count', limit => 1000)->limit, 1000,
    'and may ask for 1000';
my $over = $state->(view => 'aggregate', group => 'category.category_name', measure => 'count', limit => 1001);
is $over->limit, 1000, 'more is held to 1000';
ok scalar(grep { /above the configured maximum/ } @{$over->errors}), 'and says so';
is $state->(view => 'detail', field => 'product_name')->limit, 25, 'Detail still asks for 25';
my $detail = $state->(view => 'detail', field => 'product_name', limit => 250);
is $detail->limit, 100, 'and is held to 100';

my $menu = Mojo::DOM->new('<select>' . _limit_options($summary, $config) . '</select>');
is $menu->at('option[selected]')->attr('value'), 250, 'the Rows menu selects 250 on a summary';
is_deeply [map { $_->attr('value') } @{$menu->find('option:not([hidden])')}], [qw(10 25 50 100 250 500 1000)],
    'and offers every size up to 1000';
$menu = Mojo::DOM->new('<select>' . _limit_options($state->(view => 'detail', field => 'product_name'), $config) . '</select>');
is_deeply [map { $_->attr('value') } @{$menu->find('option[hidden][disabled]')}], [qw(250 500 1000)],
    'Detail hides the summary-only sizes';
is_deeply from_json(_limit_views($config)), {
    detail => {default => 25, max => 100}, aggregate => {default => 250, max => 1000}, graph => {default => 100, max => 100},
}, 'the browser gets each view\'s sizes';

ok !eval { Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'x',
    aggregate_default_limit => 300, aggregate_max_limit => 200); 1 }, 'a summary maximum below its default is refused';

done_testing;
