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
use Selecto::Components::NumberFormat;
use Selecto::Components::Renderer::Markup;
use lib 't/lib';
use TestSelectoComponents;

my $formatter = 'Selecto::Components::NumberFormat';
sub column { +{measure => 1, type => 'decimal', function => 'avg', @_} }
for my $case (
    [column(), '789.2609221822209914', '789.26'],
    [column(series => {raw_unit => {kind => 'duration', code => 'hour'}}), '8.54', '8.5'],
    [column(series => {raw_unit => {kind => 'duration', code => 'hour'}}), '8', '8.0'],
    [column(series => {raw_unit => {kind => 'duration', code => 'day'}}), '.354166', '0.4'],
    [column(series => {raw_unit => {kind => 'duration', code => 'day'}}, type => 'integer'), '8', '8'],
    [column(series => {raw_unit => {kind => 'duration', code => 'day'}}, display => {decimals => 2}), '.354166', '0.35'],
    [column(function => 'count', type => 'integer'), 17526, '17,526'],
    [column(function => 'count_distinct', type => 'integer'), 17526, '17,526'],
    [column(function => 'true_count', type => 'integer'), 17526, '17,526'],
    [column(function => 'false_count', type => 'integer'), 17526, '17,526'],
    [column(series => {raw_unit => {kind => 'currency', code => 'USD'}}), 12.5, '12.50'],
    [column(function => 'true_percentage'), '13.123359580052493438', '13.1%'],
    [column(series => {raw_unit => {kind => 'percentage', scale => 'fraction'}}), '.005', '0.5%'],
    [column(), '442.7363179534033805', '442.74'],
    [column(type => 'integer'), '12.5', '12.5'],
    [column(type => 'integer', function => 'sum'), 7753198, '7,753,198'],
    [column(function => 'min'), '1234.5', '1,234.5'],
    [column(function => 'max'), '-1234.555', '-1,234.56'],
    [column(display => {decimals => 0}), '442.7363179534033805', '443'],
    [column(display => {decimals => 3}), '12.5', '12.500'],
    [column(), '999999999999999999999.995', '1,000,000,000,000,000,000,000'],
    [column(), '1.2345e4', '12,345'],
) {
    is $formatter->format($case->[0], $case->[1]), $case->[2], "format $case->[1] as $case->[2]";
}
my $aligned = column();
$formatter->prepare($aligned, [12.5, 1234.567]);
is $formatter->format($aligned, 12.5), '12.50', 'pad all rows when the column needs two decimals';
is _html_display({type => 'integer'}, 17526, 1), '17526', 'numeric group labels stay identifiers';
is _html_display(column(type => 'date', function => 'min'), '2026-01-01'), '2026-01-01', 'date minimum unchanged';
is _html_display(column(), undef), '—', 'NULL measure unchanged';
like _html_display(column(), '789.2609221822209914'), qr/title="789\.2609221822209914".*>789\.26</, 'exact source value is available on hover';
for my $transform (qw(percent_of_total percent_change)) {
    is $formatter->format(column(series => {unit => {kind => 'percentage', scale => 'whole'},
        transforms => [{type => $transform}]}), 24.3456), '24.3%', "$transform output format";
}
is $formatter->xlsx_format(column(function => 'true_percentage')), '0.0"%"', 'whole percentages retain their raw value in XLSX';
is $formatter->xlsx_format(column(series => {unit => {kind => 'percentage', scale => 'fraction'}})), '0.0%', 'fraction percentage Excel format';

sub unzip_parts {
    my ($bytes) = @_;
    require IO::Uncompress::Unzip;
    my $zip = IO::Uncompress::Unzip->new(\$bytes) or die 'invalid XLSX archive';
    my %parts;
    do {
        my $name = $zip->getHeaderInfo->{Name};
        my $part = '';
        while ($zip->read(my $chunk) > 0) { $part .= $chunk }
        $parts{$name} = $part;
    } while ($zip->nextStream > 0);
    return \%parts;
}
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
        $dbh->do('CREATE TEMP TABLE number_format_rows (id integer, region varchar(4), category varchar(4), amount numeric, miles integer, active boolean)');
        $dbh->do('INSERT INTO number_format_rows VALUES (?, ?, ?, ?, ?, ?)', undef, @$_) for
            [1001, 'east', 'A', '789.2609221822209914', 1250, 1],
            [1002, 'west', 'B', '12.5', 1251, 0];
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Numbers',
            source => {source_table => 'number_format_rows', primary_key => 'id', fields => [qw(id region category amount miles active)],
                columns => {id => {type => 'integer'}, region => {type => 'string'}, category => {type => 'string'},
                    amount => {type => 'decimal', unit => {kind => 'currency', code => 'USD'}},
                    miles => {type => 'integer', unit => {kind => 'distance', code => 'mile'}, display => {decimals => 0}}, active => {type => 'boolean'}}, associations => {}},
            schemas => {}, joins => {}}, strict => 1);
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)));
        my %settings = (path => '/numbers', title => 'Numbers', default_fields => [qw(id amount)],
            engine_factory => sub { $engine }, measures => [
                {id => 'average', field => 'amount', aggregate => 'avg'},
                {id => 'miles', field => 'miles', aggregate => 'avg'},
                {id => 'active', field => 'active', aggregate => 'true_percentage'}]);
        my $config = Selecto::Components::Config->new(id => 'numbers', %settings);
        my $explorer = Selecto::Components::Explorer->new(config => $config);
        my $app = Mojolicious->new;
        $app->secrets(['number-format-test']); $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {numbers => \%settings}});
        my $t = Test::Mojo->new($app);
        my %params = (q => 1, field => 'id', view => 'aggregate', group => [qw(region category)], measure => [qw(average miles active)]);
        for my $shape (
            [{}, '.sc-results tbody'],
            [{pivot_column => 'category'}, '.sc-pivot-table tbody'],
            [{aggregate_grid => 1, pivot_column => 'category'}, '.sc-pivot-grid tbody'],
            [{aggregate_grid => 1, measure => 'average'}, '.sc-aggregate-grid tbody'],
            [{view => 'graph', graph_show_table => 1, measure => 'average'}, '.sc-results table tbody'],
        ) {
            my %input = (%params, %{$shape->[0]});
            $t->get_ok('/numbers' => form => \%input)->status_is(200);
            my $dom = $t->tx->res->dom;
            my $cells = $dom->find($shape->[1] . ' [data-sc-raw-value]');
            ok $cells->size, "formatted cells in $shape->[1]";
            my ($average) = grep { $_->all_text eq '789.26' } @$cells;
            ok $average, 'same average display across table paths';
            like $average ? $average->attr('title') : '', qr/^789\.26092218222/, 'unrounded database value retained';
            if ($shape->[0]{aggregate_grid}) {
                ok $dom->at('input[name="grid_cell"]'), 'grid selections remain present';
                like $dom->at('input[name="grid_cell"]')->attr('value'), qr/"east","A"/, 'selection contains raw group values';
            }
            my $model = $explorer->model(undef, \%input);
            diag explain $model->{errors}, $model->{state}->errors unless $model->{result};
            ok $model->{state}->valid && $model->{result}, 'real database model available';
            my ($raw) = map { $_->{average} } grep { defined($_->{average}) && $_->{average} =~ /^789/ } @{$model->{result}{records}};
            is $average ? $average->attr('title') : '', $raw, 'hover retains every digit returned by the database';
            my $csv = $explorer->csv($model);
            like $csv, qr/789\.26092218222/, 'CSV retains unrounded numeric value';
            my $parts = unzip_parts($explorer->xlsx($model));
            like $parts->{'xl/worksheets/sheet1.xml'}, qr/<v>\Q$raw\E<\/v>/, 'XLSX stores the unrounded database number';
            like $parts->{'xl/styles.xml'}, qr/formatCode="#,##0\.00"/, 'XLSX carries a measure number format';
        }
        $t->get_ok('/numbers' => form => {q => 1, field => 'id', view => 'aggregate', group => 'region', measure => 'miles'})->status_is(200);
        ok $t->tx->res->dom->find('[data-sc-raw-value]')->grep(sub { $_->all_text eq '1,251' })->size, 'host decimals override reaches rendered cells';
        $t->get_ok('/numbers' => form => {q => 1, field => [qw(id amount)], order => 'id'})->status_is(200);
        like $t->tx->res->dom->at('.sc-results tbody')->all_text, qr/1001/, 'detail IDs retain original display';
        my $file = $explorer->xlsx_file_export(TestSelectoComponents::Controller->new(params => {
            q => 1, field => 'id', view => 'aggregate', group => 'region', measure => 'average'}));
        open my $fh, '<:raw', $file->{path} or die $!;
        my $bytes = do { local $/; <$fh> }; close $fh;
        my $parts = unzip_parts($bytes); $file->{close}->();
        like $parts->{'xl/styles.xml'}, qr/formatCode="#,##0\.00"/, 'streamed XLSX uses the same numeric style';
        my ($raw_export) = $dbh->selectrow_array(q{SELECT AVG(amount) FROM number_format_rows WHERE region = 'east'});
        like $parts->{'xl/worksheets/sheet1.xml'}, qr/<v>\Q$raw_export\E<\/v>/, 'streamed XLSX retains raw precision';
    };
    $dbh->disconnect;
}
done_testing;
