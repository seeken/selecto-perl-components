use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::URL;
use Mojo::JSON qw(from_json);
use IO::Uncompress::Unzip;
use lib 't/lib';
use AsOfFixture;
use Selecto::Components::State;
use Selecto::Components::QueryBuilder;
use Selecto::Components::BucketParser;

for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? ('postgresql') : ())) {
    subtest $backend => sub {
        my $app = AsOfFixture::app($backend);
        my $t = Test::Mojo->new($app);
        my $c = $app->build_controller;
        my $explorer = $c->selecto_components_explorer('events');
        my $config = $explorer->config;
        my $engine = $config->engine($c);
        $t->get_ok('/events?q=1&field=id&filter_field=day&filter_op=date_shortcut&filter_value=today')
            ->status_is(200);
        is_deeply $t->tx->res->dom->find('.sc-results tbody tr td:first-child')->map('all_text')->to_array,
            ['6'], 'unbound Today finds the fixture row in the process local timezone';
        my %base = (q => 1, field => 'id', order => 'id', filter_field => 'day',
            filter_op => 'date_shortcut', filter_value => 'today', as_of => '2026-03-15');
        my $model = sub {
            my $m = $explorer->model($c, {%base, @_});
            ok $m->{state}->valid, 'valid state' or diag explain $m->{state}->errors;
            is $m->{runtime_error}, undef, 'no runtime error';
            return $m;
        };
        my $m = $model->();
        is_deeply [map { 0 + $_->{id} } @{$m->{result}{records}}], [1], 'today uses as-of day';
        $m = $model->(filter_value => 'last_7_days', limit => 1);
        is $m->{result}{total_count}, 3, 'exact count uses same last-seven-day clock';
        $t->get_ok('/events/count' => form => {%base, filter_value => 'last_7_days', limit => 1})->status_is(200)->json_is('/total_count', 3);
        $m = $model->(filter_value => 'last_7_days');
        is_deeply [map { 0 + $_->{id} } @{$m->{result}{records}}], [1,2,3], 'last 7 days returns as-of rows';
        my $url = Mojo::URL->new($m->{canonical_url});
        is $url->query->param('as_of'), $base{as_of}, 'permalink retains clock';
        my %input;
        for my $key (@{$url->query->names}) {
            my @values = @{$url->query->every_param($key)};
            $input{$key} = @values == 1 ? $values[0] : \@values;
        }
        my $round = Selecto::Components::State->from_input($config, $engine->domain, \%input);
        is_deeply $round->query_pairs, $m->{state}->query_pairs, 'permalink round trip';
        is $round->api_query_payload($config, $engine->domain)->{as_of}, $base{as_of}, 'canonical API handoff keeps clock';
        my $normal = $model->(as_of => '');
        ok !defined(Mojo::URL->new($normal->{canonical_url})->query->param('as_of')), 'unset clock omitted from URL';
        ok !exists($normal->{state}->api_query_payload($config, $engine->domain)->{as_of}), 'unset API clock omitted';
        my %without = %base; delete $without{as_of};
        my $absent = Selecto::Components::State->from_input($config, $engine->domain, \%without);
        my $compile = sub { $engine->compile(Selecto::Components::QueryBuilder->build($config, $engine->domain, $_[0])->{query}) };
        my $ordinary = $compile->($absent);
        my $cleared = $compile->($normal->{state});
        is $cleared->sql, $ordinary->sql, 'cleared SQL byte identical to absent clock';
        is_deeply $cleared->params, $ordinary->params, 'cleared SQL bindings identical';
        my $fixed = $compile->($round);
        unlike $fixed->sql, qr/CURRENT_DATE|2026-03-15|'now'/, 'read clock is bound';
        for my $bad ('yesterday', '2026-02-29', '2026-03-15T25:00:00', ['2026-03-15', '2026-03-16'], {}) {
            my $state = Selecto::Components::State->from_input($config, $engine->domain, {%base, as_of => $bad});
            ok !$state->valid, 'invalid clock is a state error';
            like join(' ', @{$state->errors}), qr/as_of.*ISO/, 'clock error explained';
        }
        my $stamp = $model->(as_of => '2026-03-16T00:30:00+02:00');
        is_deeply [map { 0 + $_->{id} } @{$stamp->{result}{records}}], [1], 'timestamp day normalized by core';
        for my $selection ({query_library_segment => 'today'}, {query_library_view => 'today'}) {
            my $library = $model->(%$selection);
            is_deeply [map { 0 + $_->{id} } @{$library->{result}{records}}], [1], 'library read uses clock';
        }
        for my $view ('aggregate', 'graph') {
            my $summary = $model->(view => $view, group => 'region', measure => 'count');
            is $summary->{result}{records}[0]{count}, 1, "$view uses clock";
        }
        my %monthly = (%base, view => 'aggregate', filter_field => [], filter_op => [], filter_value => [], group => ['region', 'day'],
            group_format => ['', 'month_buckets'], group_bucket_ranges => ['', '1,0'],
            measure => 'count', pivot_column => 'day');
        delete @monthly{qw(filter_field filter_op filter_value)};
        my $monthly_model = $explorer->model($c, \%monthly);
        diag explain $monthly_model->{state}->errors if !$monthly_model->{state}->valid;
        diag $monthly_model->{runtime_error} if $monthly_model->{runtime_error};
        $t->get_ok('/events' => form => \%monthly)->status_is(200);
        my $dom = $t->tx->res->dom;

        is_deeply $dom->find('.sc-pivot-table thead tr:nth-child(2) th')->map('all_text')->to_array,
            ['Feb 2026', 'Mar 2026'], 'pivot labels use as-of months';
        my $form = $dom->at('form.sc-pivot-drill-form');
        ok $form, 'pivot drill form exists';
        my %drill;
        push @{$drill{$_->attr('name')}}, $_->attr('value') for @{$form->find('input[type=hidden]')};
        is_deeply $drill{as_of}, ['2026-03-15'], 'drilldown carries clock';
        $t->get_ok('/events' => form => {%drill, grid_axis => '{"axis":1,"value":"Feb 2026"}'})->status_is(200);
        is_deeply $t->tx->res->dom->find('.sc-results tbody tr td:first-child')->map('all_text')->to_array,
            ['5'], 'month drilldown matches as-of bucket';
        $t->get_ok('/events' => form => {%monthly, aggregate_grid => 1})->status_is(200)->content_like(qr/Feb 2026.*Mar 2026/s);
        $t->get_ok('/events' => form => {%base, format => 'csv', export_scope => 'all'})->status_is(200);
        like $t->tx->res->body, qr/"1"/, 'stream export returns as-of row';
        unlike $t->tx->res->body, qr/"6"/, 'stream export excludes real-clock row';
        $t->get_ok('/events' => form => {%base, format => 'xlsx', export_scope => 'all'})->status_is(200);
        my $xlsx = $t->tx->res->body;
        my $zip = IO::Uncompress::Unzip->new(\$xlsx) or die 'invalid XLSX';
        my $sheet = '';
        do {
            my $part = '';
            while ($zip->read(my $chunk) > 0) { $part .= $chunk }
            $sheet = $part if $zip->getHeaderInfo->{Name} eq 'xl/worksheets/sheet1.xml';
        } while ($zip->nextStream > 0);
        like $sheet, qr/r="A2"[^>]*><v>1<\/v>/, 'XLSX exports the as-of row';
        unlike $sheet, qr/r="A3"/, 'XLSX has only that one data row';
        $t->get_ok('/events' => form => \%base)->status_is(200)->element_exists('[data-sc-as-of-summary]');
        my $csrf = $t->tx->res->dom->at('form[data-sc-builder]')->attr('data-sc-column-values-csrf');
        $t->post_ok('/events/column-values' => form => {csrf_token => $csrf,
            q => 1, field => 'day', term => '', as_of => '2026-03-15'})->status_is(200);
        $t->post_ok('/events/column-values' => form => {csrf_token => $csrf,
            q => 1, field => 'day', term => '', as_of => 'bad'})->status_is(422);
        $t->post_ok('/events/saved-queries' => form => {csrf_token => $csrf, saved_query_name => 'Clock',
            saved_query_operation => 'new', saved_query_url => $explorer->model($c, \%base)->{canonical_url}});
        my $saved = $config->saved_query_store->list($c, $config);
        is scalar(@$saved), 1, 'saved query persisted';
        is(Mojo::URL->new($saved->[0]{url})->query->param('as_of'), '2026-03-15', 'saved query keeps clock');
        $t->get_ok($saved->[0]{url})->status_is(200);
        is_deeply $t->tx->res->dom->find('.sc-results tbody tr td:first-child')->map('all_text')->to_array,
            ['1'], 'saved query restores clock and rows';
        $t->get_ok('/localized' => form => \%base)->status_is(200)->text_is('[data-sc-as-of-summary]', 'Au 15 mars 2026');
        $t->get_ok('/seeded')->status_is(200)->element_exists('input[data-sc-as-of-date][value="2026-03-15"]');
        $t->get_ok('/seeded?q=1&field=id')->status_is(200)->element_exists('input[data-sc-as-of-date][value=""]')->element_exists_not('[data-sc-as-of-summary]');
        $t->get_ok('/hidden')->status_is(200)->element_exists_not('[data-sc-as-of-control]')->element_exists('input[type=hidden][name=as_of][value="2026-03-15"]');
        $t->get_ok('/events?as_of=bad')->status_is(422);
        my $bad_default = eval { Selecto::Components::Config->new(%$config, default_as_of => 'bad'); 1 };
        ok !$bad_default, 'invalid default rejected';
    };
}
done_testing;
