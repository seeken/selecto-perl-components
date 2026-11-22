use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::URL ();
use Mojo::JSON qw(from_json);
use Mojolicious;
use Selecto;
use Selecto::Components;

for my $backend (qw(sqlite postgresql)) {
    subtest $backend => sub {
        my $dbh;
        if ($backend eq 'sqlite') {
            eval { require DBD::SQLite; 1 } or plan skip_all => 'SQLite unavailable';
            $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
        } else {
            plan skip_all => 'disposable PostgreSQL URL required' unless $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
            require DBD::Pg;
            my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
            $dbh = DBI->connect('dbi:Pg:dbname=' . substr($url->path, 1) . ';host=' . $url->host . ';port=' . $url->port,
                $url->username, $url->password, {RaiseError => 1, PrintError => 0});
        }
        my $stamp = $backend eq 'sqlite' ? 'TEXT' : 'TIMESTAMPTZ';
        $dbh->do("CREATE TEMP TABLE duration_ui (id INTEGER, region VARCHAR(8), started $stamp, ended $stamp)");
        $dbh->do("INSERT INTO duration_ui VALUES
            (1, 'east', '2026-06-30 00:00:00', '2026-06-30 08:30:00'),
            (2, 'east', '2026-06-30 00:00:00', '2026-06-30 16:00:00'),
            (3, 'east', '2026-06-30 00:00:00', '2026-07-01 00:00:00'),
            (4, 'east', '2026-06-30 00:00:00', '2026-07-01 01:00:00'),
            (5, 'east', '2026-06-30 00:00:00', '2026-06-29 22:00:00'),
            (6, 'east', NULL, NULL)");
        my %columns = (id => {type => 'integer'}, region => {type => 'string'},
            started => {type => 'utc_datetime'}, ended => {type => 'utc_datetime'});
        for my $entry ([hours => 'hour'], [fraction => 'fractional_day'], [precise => 'fractional_day'], [days => 'day']) {
            my ($field, $unit) = @$entry;
            $columns{$field} = {type => $unit eq 'day' ? 'integer' : 'decimal',
                ($field eq 'precise' ? (display => {decimals => 2}) : ()),
                computed => {kind => 'temporal_delta', from => 'started', to => 'ended', unit => $unit, minimum => 0}};
        }
        my $domain = Selecto::Domain->parse({name => 'Duration UI', source => {
            source_table => 'duration_ui', primary_key => 'id', fields => [sort keys %columns],
            columns => \%columns, associations => {}}, schemas => {}, joins => {}});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)));
        my $app = Mojolicious->new;
        $app->secrets(['synthetic-duration-test']); $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {durations => {
            path => '/durations', title => 'Durations', default_fields => ['id'], engine_factory => sub { $engine },
            measures => [map { +{id => 'avg_' . $_, field => $_, aggregate => 'avg'} } qw(hours fraction precise days)],
        }}});
        my $t = Test::Mojo->new($app);
        my %form = (q => 1, view => 'aggregate', field => 'id', group => 'id', measure => [qw(avg_hours avg_fraction avg_precise avg_days)]);
        $t->get_ok('/durations' => form => \%form)->status_is(200)->element_count_is('.sc-alert', 0);
        my @cells = @{$t->tx->res->dom->find('[data-sc-raw-value]')};
        ok(scalar(grep { $_->all_text eq '8.5' } @cells), 'hours default to one decimal');
        ok(scalar(grep { $_->all_text eq '0.4' } @cells), 'fractional days default to one decimal');
        ok(scalar(grep { $_->all_text eq '0.35' } @cells), 'host decimals override');
        ok(scalar(grep { $_->all_text eq '0' } @cells), 'whole days remain integers');
        for my $entry ([avg_hours => 1], [avg_precise => 2], [avg_days => 0]) {
            $t->get_ok('/durations' => form => {%form, view => 'graph', measure => $entry->[0]})
                ->status_is(200)->element_count_is('.sc-alert', 0);
            my $chart = from_json($t->tx->res->dom->at('[data-sc-chart]')->attr('data-chart-data'));
            is($chart->{datasets}[0]{displayDecimals}, $entry->[1], 'graph inherits duration precision');
        }
        for my $format (qw(buckets age_buckets)) {
            $t->get_ok('/durations' => form => {%form, group => 'hours', group_format => $format,
                group_bucket_ranges => '0-8, 9-16, 17-24, 25+', measure => 'avg_hours', measure_function => 'sum'})
                ->status_is(200)->element_count_is('.sc-alert', 0);
            diag($t->tx->res->dom->at('.sc-alert')->all_text) if $t->tx->res->code != 200;
            my $text = $t->tx->res->dom->at('.sc-results')->all_text;
            like($text, qr/9-16/, "$format groups numeric hours");
            unlike($text, qr/days ago/, "$format numeric labels do not claim calendar dates");
        }
        for my $function (qw(buckets age_buckets)) {
            $t->get_ok('/durations' => form => {%form, group => 'region', measure => 'avg_hours', measure_function => $function,
                measure_bucket_ranges => '0-8, 9-16, 17-24, 25+'})
                ->status_is(200)->element_count_is('.sc-alert', 0);
            like($t->tx->res->dom->at('.sc-results')->all_text, qr/9-16/, "$function counts duration bands");
        }
        $dbh->disconnect;
    };
}
done_testing;
