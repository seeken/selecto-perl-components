use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(from_json);
use Mojo::URL;
use DBI;
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::BucketParser;
use lib 't/lib';
use TestSelectoComponents;

for my $backend (qw(sqlite postgresql)) {
    my $dbh;
    if ($backend eq 'sqlite') {
        next unless eval { require DBD::SQLite; 1 };
        $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    } else {
        next unless $ENV{SELECTO_PERL_TEST_POSTGRES_URL} && eval { require DBD::Pg; 1 };
        my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
        $dbh = DBI->connect('dbi:Pg:dbname=' . substr($url->path, 1) . ';host=' . $url->host . ';port=' . $url->port,
            $url->username, $url->password, {RaiseError => 1, PrintError => 0});
    }
    subtest $backend => sub {
        $dbh->do('CREATE TEMP TABLE bucket_order_rows (id integer, region varchar(4), qty integer, signed integer, received date, yearly date, monthly date)');
        my @days = (10, 100, 800, 2000, 0);
        my @months = (0, 1, 4, 8, 20);
        my @years = (1995, 2005, 2015, 2025, 2025);
        my @quantities = (50, 300, 800, 1500, 3000);
        my @signed = (-25, 5, 125, 1005, undef);
        my $date_ago = sub {
            my ($ago, $unit) = @_;
            my $sql = $backend eq 'sqlite' ? "SELECT date('now', '-$ago $unit')"
                : "SELECT (CURRENT_DATE - INTERVAL '$ago $unit')::date";
            return scalar $dbh->selectrow_array($sql);
        };
        for my $region (qw(A B)) {
            for my $i (0 .. 4) {
                $dbh->do('INSERT INTO bucket_order_rows VALUES (?, ?, ?, ?, ?, ?, ?)', undef,
                    ($region eq 'A' ? 0 : 5) + $i + 1, $region, $quantities[$i], $signed[$i],
                    $date_ago->($days[$i], 'days'), "$years[$i]-06-15", $date_ago->($months[$i], 'months'));
            }
        }
        my $domain = Selecto::Domain->new(name => 'Buckets', table => 'bucket_order_rows', fields => {
            id => 'integer', region => 'string', qty => 'integer', signed => 'integer',
            received => 'date', yearly => 'date', monthly => 'date'});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)));
        my %settings = (path => '/buckets', title => 'Buckets', default_fields => ['id'],
            engine_factory => sub { $engine }, measures => [{id => 'total', field => 'qty', aggregate => 'sum'}]);
        my $explorer = Selecto::Components::Explorer->new(config => Selecto::Components::Config->new(id => 'buckets', %settings));
        my $app = Mojolicious->new;
        $app->secrets(['bucket-order-test']); $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {buckets => \%settings}});
        my $t = Test::Mojo->new($app);
        my %base = (q => 1, field => 'id', view => 'aggregate', measure => 'total', limit => 25, page => 1);
        my @cases = (
            ['qty', 'buckets', '0-100,101-500,501-1000,1001-2000,2001+', [qw(0-100 101-500 501-1000 1001-2000 2001+)]],
            ['received', 'age_buckets', '0-30,31-365,366-1825,1826+', [qw(0-30 31-365 366-1825 1826+)]],
            ['received', 'custom_buckets', '31+,2-30,today', [qw(31+ 2-30 today)]],
            ['yearly', 'year_buckets', '2000-2009,1990-1999,2020+,2010-2019', [qw(2000-2009 1990-1999 2020+ 2010-2019)]],
            ['monthly', 'month_buckets', '0,1,2-6,7+', undef],
            ['signed', 'buckets', '*/10', [qw(-30--21 0-9 120-129 1000-1009 Other)]],
            ['yearly', 'year_buckets', '*/10', [qw(1990-1999 2000-2009 2010-2019 2020-2029)]],
        );
        for my $case (@cases) {
            my ($field, $format, $ranges, $expected) = @$case;
            $expected //= [map { $_->{label} } @{Selecto::Components::BucketParser->specification($ranges, 'month_ranges')->{ranges}}];
            my %input = (%base, group => $field, group_format => $format, group_bucket_ranges => $ranges);
            my $model = $explorer->model(undef, \%input);
            ok $model->{result}, "$format $ranges executes" or diag explain $model->{error}, $model->{state}->errors;
            next unless $model->{result};
            my @records = @{$model->{result}{records}};
            is_deeply [map { $_->{$field} } grep { $_->{__selecto_rollup_level} == 1 } @records], $expected,
                "$format summary follows range order";
            ok $model->{result}{columns}[0]{sort_key}, 'natural key is selected in SQL';
            $t->get_ok('/buckets' => form => \%input)->status_is(200);
            my @labels = map { my $text = $_->all_text; $text =~ s/\s+/ /g; $text =~ s/^ | $//g; $text }
                @{$t->tx->res->dom->find('.sc-results tbody tr > td:first-child')};
            my @shown = $format eq 'age_buckets' ? map { "$_ days ago" } @$expected : @$expected;
            is_deeply \@labels, ['Total', @shown], "$format HTML table preserves SQL order";
            my @paged;
            for my $page (1 .. int((@$expected + 2) / 2)) {
                my $part = $explorer->model(undef, {%input, limit => 2, page => $page});
                push @paged, map { $_->{$field} } grep { $_->{__selecto_rollup_level} == 1 } @{$part->{result}{records}};
            }
            is_deeply \@paged, $expected, "$format pages continue in range order";
            $t->get_ok('/buckets' => form => {%input, view => 'graph'})->status_is(200);
            my $chart = $t->tx->res->dom->at('[data-chart-data]');
            is_deeply $chart ? from_json($chart->attr('data-chart-data'))->{labels} : [], $expected,
                "$format graph categories follow range order, missing last";
            # Put the bucket on the rows of each pivot, and compare only detail
            # row keys so subtotal labels and repeated parent cells cannot mask order.
            for my $grid (0, 1) {
                my $pivot = $explorer->model(undef, {%input, group => [$field, 'region'], group_format => [$format, ''],
                    group_bucket_ranges => [$ranges, ''], pivot_column => 'region', aggregate_grid => $grid});
                ok $pivot->{result}, "$format pivot/grid executes";
                my $keys = $grid
                    ? [map { $_->{parts}[0]{value} } @{$pivot->{result}{grid_data}{rows}}]
                    : [map { $_->{$field} } grep { $_->{__selecto_rollup_level} == 1 } @{$pivot->{result}{records}}];
                is_deeply $keys, $expected, "$format " . ($grid ? 'grid' : 'summary pivot') . ' row order unchanged';
            }
        }
        my %hierarchy = (%base, group => [qw(region qty)], group_format => ['', 'buckets'],
            group_bucket_ranges => ['', '0-100,101-500,501-1000,1001-2000,2001+']);
        my $rollup = $explorer->model(undef, \%hierarchy);
        is_deeply [map { [$_->{region}, $_->{qty}, $_->{__selecto_rollup_level}] } @{$rollup->{result}{records}}],
            [[undef, undef, 0], map { my $region = $_; ([$region, undef, 1], map { [$region, $_, 2] } @{$cases[0][3]}) } qw(A B)],
            'each rollup subtotal heads its parent block and children stay in range order';
        # A bucket as the parent also keeps its subtotal ahead of its children.
        my $outer = $explorer->model(undef, {%hierarchy, group => [qw(qty region)], group_format => ['buckets', ''],
            group_bucket_ranges => ['0-100,101-500,501-1000,1001-2000,2001+', '']});
        is_deeply [map { [$_->{qty}, $_->{region}, $_->{__selecto_rollup_level}] } @{$outer->{result}{records}}],
            [[undef, undef, 0], map { my $bucket = $_; ([$bucket, undef, 1], map { [$bucket, $_, 2] } qw(A B)) } @{$cases[0][3]}],
            'bucket parents keep their subtotal and children together';
        for my $order ('total', 'measure:total') {
            my $sorted = $explorer->model(undef, {%base, group => 'qty', group_format => 'buckets',
                group_bucket_ranges => $cases[0][2], order => $order, direction => 'desc'});
            is_deeply [map { $_->{qty} } grep { $_->{__selecto_rollup_level} == 1 } @{$sorted->{result}{records}}],
                [reverse @{$cases[0][3]}], 'explicit measure sort wins over natural bucket order';
        }
        my $invalid = $explorer->model(undef, {%base, order => 'measure:not_selected'});
        ok !$invalid->{state}->valid, 'unselected measure sort rejected';
        # Isolate the known upstream bug: real NULLs tie with rolled-up NULLs
        # on native PostgreSQL multi-group rollups. Do not patch it here.
        $dbh->do(q{INSERT INTO bucket_order_rows VALUES (99, NULL, 50, NULL, NULL, NULL, NULL)});
        my $null_rollup = $explorer->model(undef, \%hierarchy);
        my @levels = map { $_->{__selecto_rollup_level} } @{$null_rollup->{result}{records}};
        is $levels[0], 0, 'grand total precedes a real NULL parent in this fixture';
    };
    $dbh->disconnect;
}
done_testing;
