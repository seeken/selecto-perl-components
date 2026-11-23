use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(from_json);
use Mojo::Parameters;
use lib 't/lib';
use SameFieldGroupsFixture;
use Selecto::Components::Config;
use Selecto::Components::Dashboard;
use Selecto::Components::State;
use Selecto::Components::QueryBuilder;

for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? ('postgresql') : ())) {
    subtest $backend => sub {
        my ($app, $domain) = SameFieldGroupsFixture::app($backend);
        my $t = Test::Mojo->new($app);
        my %input = (q => 1, view => 'aggregate', field => [qw(id created_on)],
            group => ['created_on', 'created_on'], group_format => ['month_of_year', 'year'], measure => 'count');
        my $get = sub {
            $t->get_ok('/seasonality' => form => {%input, @_})->status_is(200);
            return $t->tx->res->dom;
        };
        my $dom = $get->(pivot_column => 'created_on@year');
        $t->text_is('.sc-pivot-table thead tr:first-child th:first-child', 'Created (Month of Year)')
            ->text_is('.sc-pivot-axis-heading', 'Created (Year)');
        is_deeply $dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['2024', '2025'], 'one column per year';
        my @rows = @{$dom->find('.sc-pivot-table tbody tr:not(.sc-rollup-total)')};
        is scalar(@rows), 12, 'twelve months';
        my $total = 0;
        for my $row (@rows) {
            my @values = map { 0 + $_->all_text } @{$row->find('td')};
            is $values[0] + $values[1], $values[2], 'year cells sum to month total';
            $total += $values[2];
        }
        is $total, 26, 'month totals sum to all source rows';
        my $form = $dom->at('form.sc-pivot-drill-form');
        my %base;
        push @{$base{$_->attr('name')}}, $_->attr('value') for @{$form->find('input[type=hidden]')};
        # Numeric month labels are core DateFormat values; drill with the exact raw March value.
        my $march = $rows[2];
        my $button = $march->find('button[name=grid_cell]')->[1];
        ok $button, 'March 2025 cell has a drilldown';
        my $cell = from_json($button->attr('value'));
        is $cell->[1], '2025', 'year selection stays raw';
        $t->get_ok('/seasonality' => form => {%base, grid_cell => $button->attr('value')})->status_is(200);
        my @detail = @{$t->tx->res->dom->find('.sc-results tbody tr')};
        is scalar(@detail), 2, 'March 2025 returns only its two rows';
        like $_->all_text, qr/2025-03-/, 'both grouped filters apply to the same date' for @detail;
        $get->(pivot_column => 'created_on@month_of_year');
        is $t->tx->res->dom->find('.sc-pivot-table thead tr:nth-child(2) th')->size, 12, 'either group can be columns';
        $get->(aggregate_grid => 1, pivot_column => 'created_on@year');
        $t->element_exists('.sc-aggregate-grid');
        $get->(pivot_column => '', view => 'graph', chart_type => 'line', graph_series_group => 'created_on@year');
        my $chart = from_json($t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data'));
        is scalar(@{$chart->{labels}}), 12, 'graph has twelve month categories';
        is_deeply [map { $_->{label} } @{$chart->{datasets}}], ['2024', '2025'], 'one line per year';
        is_deeply [map { $_->{data}[2] } @{$chart->{datasets}}], [2, 2], 'March counts per year';
        my $controller = $app->build_controller;
        my $explorer = $controller->selecto_components_explorer('seasonality');
        my $model = $explorer->model($controller, {%input, pivot_column => 'created_on@year'});
        like $explorer->export($model, 'csv'), qr/Created \(Month of Year\).*2024.*2025/, 'export retains separate groups';
        my $saved = $explorer->model($controller, Selecto::Components::Dashboard->new->input_from_url(
            $explorer->canonical_url($model->{state}, $model->{domain})));
        ok $saved->{result}{pivot_data}, 'saved query URL restores shared groups';

        my $config = $model->{config};
        my $state = sub { Selecto::Components::State->from_input($config, $domain, {%input, @_}) };
        my $same = $state->(group_format => ['year', 'year']);
        ok $same->valid, 'same-format duplicates accepted';
        is_deeply $same->groups, ['created_on'], 'identical groups deduplicated';
        my $old = $state->(group => ['created_on'], group_format => ['year'], pivot_column => 'created_on');
        my $pairs = Mojo::Parameters->new(@{$old->query_pairs});
        is_deeply $pairs->every_param('group'), ['created_on'], 'single group writes its old field name';
        is $pairs->param('pivot_column'), 'created_on', 'old group reference unchanged';
        is_deeply +Selecto::Components::State->from_input($config, $domain, $pairs->to_hash)->query_pairs,
            $old->query_pairs, 'old permalink round trips unchanged';
        ok !$state->(pivot_column => 'created_on')->valid, 'ambiguous plain name rejected';
        is $state->(pivot_column => 'group:2')->pivot_column, 'created_on@year', 'positional reference resolves';
        my $excluded = $state->(group_exclude_missing => 'created_on@year');
        ok $excluded->group_configs->{'created_on@year'}{exclude_missing}, 'missing exclusion names its instance';
        ok !$excluded->group_configs->{'created_on@month_of_year'}{exclude_missing}, 'other instance unaffected';
        my $options = $state->(group => ['title', 'title'], group_format => ['text_prefix', 'text_prefix'],
            group_prefix_length => [1, 3], group_exclude_articles => [1, 1]);
        ok $options->valid, 'same format with different options allowed';
        is scalar(@{$options->groups}), 2, 'prefix options distinguish groups';
        isnt $options->groups->[0], $options->groups->[1], 'option variants have distinct identities';
        my $option_pairs = Mojo::Parameters->new(@{$options->query_pairs});
        is_deeply +Selecto::Components::State->from_input($config, $domain, $option_pairs->to_hash)->groups,
            $options->groups, 'option identities survive permalinks and saved query state';
        my $default_options = $state->(group => ['title', 'title'], group_format => ['text_prefix', 'text_prefix'],
            group_prefix_length => ['', '2'], group_exclude_articles => ['', '1']);
        is scalar(@{$default_options->groups}), 1, 'default and explicit prefix options deduplicate';
        my $spaced_ranges = $state->(group => ['days', 'days'], group_format => ['buckets', 'buckets'],
            group_bucket_ranges => ['1-6, 7-12', '1-6,7-12']);
        is scalar(@{$spaced_ranges->groups}), 1, 'equivalent range spacing deduplicates';
        my $articles = $state->(group => ['title', 'title'], group_format => ['text_prefix', 'text_prefix'],
            group_prefix_length => [2, 2], group_exclude_articles => [1, 0]);
        is scalar(@{$articles->groups}), 2, 'article handling distinguishes text groups';
        my $duplicate_options = $state->(group => ['title', 'title'], group_format => ['text_prefix', 'text_prefix'],
            group_prefix_length => [2, 2], group_exclude_articles => [1, 1]);
        is scalar(@{$duplicate_options->groups}), 1, 'identical prefix options deduplicate';
        $get->(group => ['title', 'title'], group_format => ['text_prefix', 'default'],
            group_prefix_length => [2, 2], pivot_column => 'title@default');
        $t->element_exists('.sc-pivot-table');
        $get->(group => ['days', 'days'], group_format => ['buckets', 'age_buckets'],
            group_bucket_ranges => ['1-6, 7-12', '1-3, 4-12'], pivot_column => 'days@age_buckets');
        $t->element_exists('.sc-pivot-table');
        $get->(view => 'detail', group => ['days', 'days'], group_format => ['buckets', 'age_buckets'],
            group_bucket_ranges => ['1-6, 7-12', '1-3, 4-12'],
            filter_field => ['days', 'days'], filter_op => ['eq', 'eq'],
            filter_value => ['1-6', '1-3'], filter_group => ['days@buckets', 'days@age_buckets']);
        is $t->tx->res->dom->find('.sc-results tbody tr')->size, 8, 'two bucket filters on one field AND together';
        $get->(pivot_column => 'created_on@year', pivot_column_top => 1);
        is $t->tx->res->dom->find('.sc-pivot-table thead tr:nth-child(2) th')->size, 1, 'Top N resolves shared formatted field';
        $get->(pivot_column => '');
        is $t->tx->res->dom->find('.sc-results tbody tr.sc-rollup-subtotal')->size, 12, 'shared field summary retains month rollups';
        my $built = Selecto::Components::QueryBuilder->build($config, $domain, $state->(), {rollup => 0});
        isnt $built->{columns}[0]{key}, $built->{columns}[1]{key}, 'distinct result and SQL aliases';
        $get->(pivot_column => '', group_alias => ['Season month', 'Season year']);
        like $t->tx->res->body, qr/Season month/, 'explicit group alias wins';
    };
}
done_testing;
