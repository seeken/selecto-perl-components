use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(from_json);
use IO::Uncompress::Unzip;
use lib 't/lib';
use BooleanGroupsFixture;
use Selecto::Components::GroupValue;

sub unzip_parts {
    my ($bytes) = @_;
    my $zip = IO::Uncompress::Unzip->new(\$bytes) or die 'invalid XLSX archive';
    my %parts;
    do {
        my $name = $zip->getHeaderInfo->{Name};
        my $part = '';
        while ($zip->read(my $chunk) > 0) { $part .= $chunk }
        $parts{$name} = $part;
    } while ($zip->nextStream > 0);
    return join '', values %parts;
}
for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? ('postgresql') : ())) {
    subtest $backend => sub {
        my $app = BooleanGroupsFixture::app($backend);
        my $t = Test::Mojo->new($app);
        my %input = (q => 1, view => 'aggregate', field => 'id', group => ['region', 'rush'],
            measure => 'count', pivot_column => 'rush');
        my $get = sub {
            my ($path, @extra) = @_;
            $t->get_ok($path => form => {%input, @extra})->status_is(200);
            return $t->tx->res->dom;
        };
        my $dom = $get->('/flags');
        is_deeply $dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['No', 'Yes', '[NULL]'], 'boolean pivot headings, No before Yes and missing unchanged';
        my $form = $dom->at('form.sc-pivot-drill-form');
        my %base;
        push @{$base{$_->attr('name')}}, $_->attr('value') for @{$form->find('input[type=hidden]')};
        my $yes = $dom->at('button[aria-label="Show details for Rush Yes"]');
        is_deeply from_json($yes->attr('value')), {axis => 1, value => '1'}, 'Yes heading retains raw selection';
        $t->get_ok('/flags' => form => {%base, grid_axis => $yes->attr('value')})->status_is(200);
        is_deeply $t->tx->res->dom->find('.sc-results tbody tr td:first-child')->map('all_text')->to_array,
            ['1', '3'], 'Yes drilldown is equality to true';
        $get->('/flags', group => ['region', 'invoiced'], pivot_column => 'invoiced');
        is_deeply $t->tx->res->dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['Not invoiced', 'Invoiced'], 'field display override used';
        $get->('/localized');
        is_deeply $t->tx->res->dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['Non', 'Oui', '[NULL]'], 'existing i18n dictionary localizes boolean display terms';
        $get->('/flags', group => ['region', 'reverse_flag'], pivot_column => 'reverse_flag');
        is_deeply $t->tx->res->dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['Yes', 'No', '[NULL]'], 'host value_order overrides boolean order';
        $get->('/flags', group => 'rush', pivot_column => '');
        is_deeply $t->tx->res->dom->find('.sc-results tbody tr:not(.sc-rollup-total) th:first-child, .sc-results tbody tr:not(.sc-rollup-total) td:first-child')->map('all_text')->to_array,
            ['No', 'Yes', '[NULL]'], 'summary rows show labels';
        $get->('/flags', aggregate_grid => 1);
        like $t->tx->res->dom->at('.sc-aggregate-grid thead')->all_text, qr/No.*Yes/s, 'grid headings show labels';
        $get->('/flags', view => 'graph', graph_series_group => 'rush');
        my $chart = from_json($t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data'));
        is_deeply [map { $_->{label} } @{$chart->{datasets}}], ['No', 'Yes', "\x{2014}"], 'graph series use labels';

        my $controller = $app->build_controller;
        my $explorer = $controller->selecto_components_explorer('flags');
        my $model = $explorer->model($controller, {%input});
        like $explorer->export($model, 'csv'), qr/No.*Yes/, 'CSV pivot headers show labels';
        like unzip_parts($explorer->export($model, 'xlsx')), qr/No.*Yes/s, 'XLSX pivot headers show labels';
        my $overridden = $explorer->model($controller, {%input, group => ['invoiced', 'region'], pivot_column => 'region'});
        like $explorer->export($overridden, 'csv'), qr/Not invoiced.*Invoiced/s, 'CSV row groups use host labels';
        like unzip_parts($explorer->export($overridden, 'xlsx')), qr/>Invoiced</, 'XLSX row groups use host labels';
        my $summary = $explorer->model($controller, {%input, group => 'rush', pivot_column => ''});
        my @raw = map { $_->{rush} } grep { ($_->{__selecto_rollup_level} // 1) == 1 } @{$summary->{result}{records}};
        is_deeply \@raw, [0, 1, undef], 'result values remain raw';
        my $json = from_json($explorer->export($summary, 'json'));
        is_deeply [map { $_->{Rush} } grep { defined($_->{Rush}) } @{$json->{rows}}], [0, 1], 'JSON group values remain raw';
        like $explorer->export($summary, 'csv'), qr/"No","1".*"Yes","2"/s, 'CSV group columns show labels';
        my $xlsx = unzip_parts($explorer->export($summary, 'xlsx'));
        like $xlsx, qr/>No</, 'XLSX No group cell is text';
        like $xlsx, qr/>Yes</, 'XLSX Yes group cell is text';
        $get->('/flags', group => 'rush', pivot_column => '', format => 'csv');
        like $t->tx->res->body, qr/"No","1".*"Yes","2"/s, 'streamed CSV labels group columns';
        $get->('/flags', group => 'rush', pivot_column => '', format => 'json');
        my $stream_json = from_json($t->tx->res->body);
        is_deeply [map { $_->{Rush} } grep { defined($_->{Rush}) } @{$stream_json->{rows}}], [0, 1], 'streamed JSON stays raw';
        $get->('/flags', group => 'rush', pivot_column => '', format => 'xlsx');
        like unzip_parts($t->tx->res->body), qr/>No</, 'streamed XLSX labels group columns';
        $get->('/flags', pivot_column_value => ['1', '0']);
        is_deeply $t->tx->res->dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['Yes', 'No'], 'chosen values preserve raw keys and authored order';
        my $terms = $model->{config}->localization_terms($model->{domain});
        ok scalar(grep { $_->{semantic} eq 'fields.invoiced.display.true' && $_->{default} eq 'Invoiced' } @$terms),
            'boolean override is listed in i18n terms';
    };
}
done_testing;
