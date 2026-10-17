use 5.034;
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/../../selecto-perl/lib", "$Bin/lib";
use Test::More;
use Selecto::Error ();
use Selecto::Components::Config ();
use Selecto::Components::Explorer ();
use TestSelectoComponents ();
use Selecto::Components::QueryBuilder ();
use Selecto::Components::State ();
use Selecto::Components::Renderer::Results ();

sub config_with (%args) { Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products', %args) }

# Explorer queries run for query_timeout_seconds (15 by default), and a query that runs out
# of time says so instead of "Execution failed".

my $config = config_with();
is $config->query_timeout_seconds, 15, 'queries get 15 seconds by default';

for my $bad (0, -1, 601, '10s', 1.5) {
    ok !eval { config_with(query_timeout_seconds => $bad); 1 },
        "query_timeout_seconds $bad is refused";
}
my $thirty = config_with(query_timeout_seconds => 30);
is $thirty->query_timeout_seconds, 30, 'an Explorer can set its own time limit';

my $cancelled = Selecto::Error->new(code => 'query_error', message => 'Execution failed',
    details => {sqlstate => '57014', category => 'query_canceled'});
like Selecto::Components::Explorer::_public_error($cancelled, $config),
    qr/\AThe query took longer than 15 seconds and was stopped\. Add a filter or choose a segment/,
    'a statement the database cancelled reports the time limit';
like Selecto::Components::Explorer::_public_error(Selecto::Error->new(code => 'query_budget_exceeded',
    message => 'query time budget exceeded'), $thirty),
    qr/longer than 30 seconds/, 'so does a spent time budget, with the Explorer\'s own limit';
like Selecto::Components::Explorer::_public_error($cancelled), qr/\AThe query took too long/,
    'without a config, no number';
is Selecto::Components::Explorer::_public_error(Selecto::Error->new(code => 'query_error', message => 'Execution failed',
    details => {sqlstate => '23505', category => 'unique_violation'}), $config), 'Execution failed',
    'other failures keep their message';
is Selecto::Components::Explorer::_public_error('boom', $config), 'The query could not be completed.',
    'and a plain error stays generic';

# Aggregate views run no count query: the page fetches one row beyond its size, which says
# whether another page follows.
{
    my $domain = TestSelectoComponents::domain();
    my $state_for = sub (%input) { Selecto::Components::State->from_input($config, $domain, {
        q => 1, field => 'product_name', group => 'category.category_name', measure => 'count', limit => 10, page => 2, %input }) };
    my $aggregate = Selecto::Components::QueryBuilder->build($config, $domain, $state_for->(view => 'aggregate'));
    is $aggregate->{query}->limit_value, 11, 'an aggregate page fetches one row beyond its size';
    is $aggregate->{query}->offset_value, 10, 'from where its page starts';
    ok $aggregate->{peek}, 'and is counted from that row';
    my $graph = Selecto::Components::QueryBuilder->build($config, $domain, $state_for->(view => 'graph'));
    ok !$graph->{peek}, 'a graph is left as it was';
    my $detail = Selecto::Components::QueryBuilder->build($config, $domain,
        $state_for->(view => 'detail'));
    is $detail->{query}->limit_value, 10, 'a detail page fetches just its rows';

    # What the page shows with and without a count.
    my $page = sub ($result) { Selecto::Components::Renderer::Results->_results({
        state => $state_for->(view => 'aggregate'), config => $config, domain => $domain,
        result => {rows => [], columns => [], count => 10, elapsed_ms => 5, %$result} }) };
    like $page->({total_count => undef, total_known => 0, total_pages => 3}), qr/10<\/strong> rows on this page · more on the next/,
        'more pages: what is on this page, no invented total';
    like $page->({total_count => 15, total_known => 1, total_pages => 2}), qr/15<\/strong> rows matched/,
        'last page: the total, counted from the pages';
}

done_testing;
