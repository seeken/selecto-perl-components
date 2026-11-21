use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::JSON qw(from_json);
use Mojo::URL ();
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::Dashboard ();

# The summary (paged aggregate) table with one group marked "Show as columns",
# and a group's "Leave out rows with no value". SQLite runs in memory;
# PostgreSQL runs when SELECTO_PERL_TEST_POSTGRES_URL is set.
my $table = 'selecto_components_summary_pivot_' . $$;
my %connect = (
    sqlite => sub {
        return undef unless eval { require DBD::SQLite; 1 };
        return DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
    postgresql => sub {
        my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
        return undef unless defined($url) && length($url) && eval { require DBD::Pg; 1 };
        my $parsed = Mojo::URL->new($url);
        return DBI->connect('dbi:Pg:dbname=' . substr($parsed->path, 1) . ';host=' . ($parsed->host // 'localhost')
            . ';port=' . ($parsed->port // 5432), $parsed->username, $parsed->password,
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
);
my @cleanup;
END { eval { $_->do("DROP TABLE IF EXISTS $table") } for @cleanup }

sub text_of { my $text = $_[0]->all_text; $text =~ s/\s+//g; return $text }
sub rows_of {
    my ($dom, $selector) = @_;
    return [map { join '|', map { text_of($_) } @{$_->children} } @{$dom->find($selector)}];
}

my @groups = (group => [qw(origin destination days)], group_alias => ['', '', ''],
    group_format => ['', '', 'buckets'], group_bucket_ranges => ['', '', '5-9, 10-20, 21+']);
my @summary = (q => 1, view => 'aggregate', field => 'id', @groups, measure => [qw(price pay loads)], page => 1);

# What each row holds under 5-9, 10-20, 21+ and Total (price, pay, count).
my %expected = (
    'Total|'  => '180|135|4|270|210|2|300|250|1|750|595|7',
    'MI|'     => '160|125|3|200|150|1|300|250|1|660|525|5',
    '|OH'     => '110|85|2|200|150|1|—|—|—|310|235|3',
    '|TX@MI'  => '50|40|1|—|—|—|300|250|1|350|290|2',
    'OH|'     => '20|10|1|70|60|1|—|—|—|90|70|2',
    '|[NULL]' => '20|10|1|—|—|—|—|—|—|20|10|1',
    '|TX@OH'  => '—|—|—|70|60|1|—|—|—|70|60|1',
);

my $ran = 0;
for my $backend (qw(sqlite postgresql)) {
    my $dbh = $connect{$backend}->() or next;
    $ran++;
    subtest $backend => sub {
        $dbh->do("CREATE TABLE $table (id integer primary key, origin varchar(4), destination varchar(4), days integer, price integer, pay integer)");
        push @cleanup, $dbh if $backend eq 'postgresql';
        $dbh->do("INSERT INTO $table VALUES (1,'MI','OH',7,100,80), (2,'MI','OH',15,200,150), (3,'MI','TX',8,50,40),
            (4,'MI','TX',30,300,250), (5,'OH','TX',12,70,60), (6,'MI','OH',6,10,5), (7,'OH',NULL,9,20,10)");
        my $domain = Selecto::Domain->new(name => 'Loads', table => $table,
            fields => {id => 'integer', origin => 'string', destination => 'string', days => 'integer',
                price => 'integer', pay => 'integer'});
        my $adapter = Selecto->adapter($backend => (dbh => $dbh));
        my %explorer = (
            path => '/loads', title => 'Loads', default_fields => [qw(id origin destination)],
            engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
            measures => [
                {id => 'price', label => 'Price', aggregate => 'sum', field => 'price'},
                {id => 'pay', label => 'Pay', aggregate => 'sum', field => 'pay'},
                {id => 'loads', label => 'Count', aggregate => 'count'},
            ],
        );
        my $app = Mojolicious->new;
        $app->secrets(['summary-pivot-test']);
        $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {
            loads => {%explorer},
            narrow => {%explorer, path => '/narrow', max_grid_columns => 2},
            small => {%explorer, path => '/small', max_grid_result_cells => 100},
        }});
        my $t = Test::Mojo->new($app);
        my $get = sub {
            my ($path, %form) = @_;
            $t->get_ok($path => form => \%form)->status_is(200)
                or diag $t->tx->res->dom->find('.sc-error, [role=alert], .sc-grid-warning')->map('all_text')->join('; ');
            return $t->tx->res->dom;
        };

        # The plain summary of the row groups is what the pivot's rows must be.
        my $plain = $get->('/loads', q => 1, view => 'aggregate', field => 'id', group => [qw(origin destination)],
            measure => [qw(price pay loads)], limit => 25, page => 1);
        my $plain_rows = rows_of($plain, '.sc-results tbody tr');
        is scalar(@$plain_rows), 7, 'four detail rows, two subtotals and the total';

        my $dom = $get->('/loads', @summary, limit => 25, pivot_column => 'days');
        ok $dom->at('table.sc-pivot-table'), 'the summary table is pivoted';
        ok !$dom->at('table.sc-aggregate-grid'), 'and it is not the grid';
        is_deeply [map { text_of($_) } @{$dom->find('.sc-pivot-table thead tr:nth-child(1) > th')}],
            ['Origin', 'Destination', '5-9', '10-20', '21+', 'Total'],
            'row groups, bucket columns in the order the ranges were given, then Total';
        is_deeply [map { text_of($_) } @{$dom->find('.sc-pivot-table thead tr:nth-child(2) > th')}],
            [('Price', 'Pay', 'Count') x 4], 'one sub-column per measure under each';

        my $rows = rows_of($dom, '.sc-pivot-table tbody tr');
        is scalar(@$rows), 7, 'the same seven rows';
        # A pivot row is its group cells, the cells under each column, then
        # the totals; a plain row is its group cells, then the totals.
        is_deeply [map { join '|', (split /\|/, $_, -1)[0, 1, 11, 12, 13] } @$rows], $plain_rows,
            'in the summary table\'s order, with its totals as the Total columns';
        my ($origin, %got) = ('');
        for my $row (@$rows) {
            my @cells = split /\|/, $row, -1;
            $origin = $cells[0] if length $cells[0];
            my $name = "$cells[0]|$cells[1]";
            $name .= "\@$origin" if $name eq '|TX';
            $got{$name} = join '|', @cells[2 .. $#cells];
        }
        is_deeply \%got, \%expected, 'cells, row totals, rollup subtotals, column totals and the grand total';
        is $dom->find('.sc-pivot-table tbody tr.sc-rollup-subtotal')->size, 2, 'subtotal rows keep their marking';
        is $dom->find('.sc-pivot-table tbody tr.sc-rollup-total')->size, 1, 'and so does the total row';
        is $dom->find('.sc-pivot-table tbody form.sc-drilldown-form')->size, 6, 'each row keeps its drilldown control';

        subtest 'accessibility' => sub {
            is $dom->find('.sc-pivot-table thead tr:nth-child(1) > th[scope="colgroup"][colspan="3"]')->size, 4;
            is $dom->find('.sc-pivot-table thead tr:nth-child(1) > th[scope="col"][rowspan="2"]')->size, 2;
            is $dom->find('.sc-pivot-table tbody th[scope="row"]')->size, 7, 'each row has a header cell';
            my %header = map { ($_->attr('id') => text_of($_)) } @{$dom->find('.sc-pivot-table th[id]')};
            my ($row) = grep { text_of($_) =~ /\A\|?OH110/ || text_of($_) =~ /OH11085/ } @{$dom->find('.sc-pivot-table tbody tr')};
            my $cell = $row->find('td[headers]')->[1];
            is_deeply [map { $header{$_} } split ' ', $cell->attr('headers')], [qw(OH 5-9 Pay)],
                'a cell names its row, its column value and its measure';
        };

        subtest 'drilling from a cell or a column header' => sub {
            my %value;
            for my $button (@{$dom->find('.sc-pivot-table button[form][name]')}) {
                $value{$button->attr('aria-label')}{$button->attr('name')} = $button->attr('value');
            }
            is_deeply from_json($value{'Show details for MI, OH, 5-9'}{grid_cell}), ['MI', 'OH', '5-9'], 'a detail cell';
            is_deeply from_json($value{'Show details for MI, 21+'}{grid_axis}), {axes => [0, 2], values => ['MI', '21+']}, 'a subtotal cell';
            is_deeply from_json($value{'Show details for Total, 10-20'}{grid_axis}), {axis => 2, value => '10-20'}, 'a total cell';
            is_deeply from_json($value{'Show details for Days 5-9'}{grid_axis}), {axis => 2, value => '5-9'}, 'a column header';
            is $dom->find('.sc-pivot-table button[aria-label="Show details for MI, OH, 5-9"]')->size, 3,
                'each measure of a cell is the same drilldown';
            my $form = $dom->at('form.sc-pivot-drill-form');
            my %base;
            push @{$base{$_->attr('name')}}, $_->attr('value') for @{$form->find('input[type="hidden"]')};
            my $ids = sub {
                my (%more) = @_;
                $t->get_ok('/loads' => form => {%base, %more})->status_is(200);
                return [sort { $a <=> $b } map { text_of($_) } @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}];
            };
            is $base{view}[0], 'detail', 'the drilldown opens the Detail view';
            is_deeply $ids->(grid_cell => $value{'Show details for MI, OH, 5-9'}{grid_cell}), [1, 6], 'row values and the column value';
            is_deeply $ids->(grid_axis => $value{'Show details for MI, 21+'}{grid_axis}), [4], 'a subtotal row and the column value';
            is_deeply $ids->(grid_axis => $value{'Show details for Total, 10-20'}{grid_axis}), [2, 5], 'the column value alone';
        };

        subtest 'paging keeps the columns and the totals' => sub {
            my @pages = map { $get->('/loads', @summary, limit => 3, page => $_, pivot_column => 'days') } 1 .. 3;
            my @heads = map { join ',', map { text_of($_) } @{$_->find('.sc-pivot-table thead th')} } @pages;
            is $heads[1], $heads[0], 'page 2 has the same columns as page 1';
            is $heads[2], $heads[0], 'and so has page 3';
            my (%seen, $continued);
            for my $page (@pages) {
                my $origin = '';
                for my $row (@{$page->find('.sc-pivot-table tbody tr')}) {
                    my @cells = map { text_of($_) } @{$row->children};
                    if (($row->attr('class') // '') =~ /sc-rollup-continued/) {
                        $continued++;
                        ($origin = $cells[0]) =~ s/\(continued\)\z//;
                        next;
                    }
                    $origin = $cells[0] if length $cells[0];
                    my $name = "$cells[0]|$cells[1]";
                    $name .= "\@$origin" if $name eq '|TX';
                    $seen{$name} = join '|', @cells[2 .. $#cells];
                }
            }
            is_deeply \%seen, \%expected, 'every page\'s rows carry whole-result values, the Total row included';
            ok $continued, 'a group that continues across a page break is marked continued';
            is $pages[0]->find('.sc-pivot-table tbody tr')->size, 3, 'limit counts rows, not cells';
        };

        subtest 'limits refuse and say why' => sub {
            $get->('/narrow', @summary, limit => 25, pivot_column => 'days');
            ok !$t->tx->res->dom->at('table.sc-pivot-table'), 'no table';
            like $t->tx->res->dom->at('.sc-grid-warning')->all_text, qr/more than 2 columns/, 'the column limit is named';
            $get->('/small', @summary, limit => 25, pivot_column => 'days');   # 7 x (3 + 1) x 3 = 84
            ok $t->tx->res->dom->at('table.sc-pivot-table'), '84 cells fit a limit of 100';
            # Destination across: 8 rows x (3 columns + Total) x 4 measures = 128.
            $get->('/small', @summary, measure => [qw(price pay loads price)], limit => 25, pivot_column => 'destination');
            ok !$t->tx->res->dom->at('table.sc-pivot-table'), '128 cells do not';
            like $t->tx->res->dom->at('.sc-grid-warning')->all_text, qr/more than 100 display cells/, 'the cell limit is named';
            my $one = $get->('/loads', q => 1, view => 'aggregate', field => 'id', group => 'origin', measure => 'loads',
                limit => 25, page => 1, pivot_column => 'origin');
            ok !$one->at('table.sc-pivot-table'), 'a lone group stays a plain table';
            like $one->at('.sc-grid-warning')->all_text, qr/needs at least one other Group By/;
        };

        subtest 'state, links and export' => sub {
            like $dom->to_string, qr/[?&;]pivot_column=days(?:&|")/, 'pivot_column is carried in generated links';
            my $old = $get->('/loads', @summary, limit => 25, grid_column => 'days');
            is_deeply rows_of($old, '.sc-pivot-table tbody tr'), $rows, 'the old grid_column spelling still works';
            like $old->to_string, qr/[?&;]pivot_column=days(?:&|")/, 'and is written back as pivot_column';
            unlike $old->to_string, qr/[?&;]grid_column=/;
            $t->get_ok('/loads' => form => {@summary, limit => 25, pivot_column => 'nowhere'})->status_is(422);
            $t->get_ok('/loads' => form => {@summary, limit => 25, pivot_column => [qw(days origin)]})->status_is(422);

            my $controller = $app->build_controller;
            my $explorer = $controller->selecto_components_explorer('loads');
            my $model = $explorer->model($controller, {@summary, limit => 25, pivot_column => 'days'});
            is $model->{state}->pivot_column, 'days';
            my $again = $explorer->model($controller, Selecto::Components::Dashboard->new->input_from_url(
                $explorer->canonical_url($model->{state}, $model->{domain})));
            is $again->{state}->pivot_column, 'days', 'a saved view URL restores it';
            ok $again->{result}{pivot_data}, 'and pivots again';
            my @lines = map { s/"//gr } split /\r?\n/, $explorer->export($model, 'csv');
            is $lines[0], join(',', 'Origin', 'Destination', map { my $c = $_; map { "$c \x{b7} $_" } qw(Price Pay Count) } '5-9', '10-20', '21+', 'Total'),
                'export headers are "<column value> · <measure>"';
            is scalar(@lines), 8, 'with the subtotal and total rows';
            ok scalar(grep { $_ eq 'Total,,180,135,4,270,210,2,300,250,1,750,595,7' } @lines), 'the total row';
            ok scalar(grep { $_ eq 'MI,,160,125,3,200,150,1,300,250,1,660,525,5' } @lines), 'a subtotal row';
            ok scalar(grep { $_ eq 'MI,OH,110,85,2,200,150,1,,,,310,235,3' } @lines), 'a detail row with its full key';
            $t->get_ok('/loads' => form => {@summary, limit => 25, pivot_column => 'days', format => 'csv'});
            isnt $t->tx->res->code, 200, 'the streamed web export refuses a pivot, as it refuses a grid';
        };

        subtest 'leave out rows with no value' => sub {
            my @off = (@summary, limit => 25, pivot_column => 'days');
            ok !$dom->at('[data-sc-group-filter]'), 'no group filter is listed without the option';
            is $dom->find('input[name="group_exclude_missing"]')->size, 3, 'every group offers the option';
            is $dom->find('input[name="group_exclude_missing"][checked]')->size, 0;

            my $left_out = $get->('/loads', @off, group_exclude_missing => 'destination');
            my $kept = rows_of($left_out, '.sc-pivot-table tbody tr');
            is scalar(@$kept), 6, 'the row with no destination is gone';
            ok !grep({ /\[NULL\]/ } @$kept), 'by value';
            ok scalar(grep { $_ eq 'OH||—|—|—|70|60|1|—|—|—|70|60|1' } @$kept), 'its subtotal leaves it out';
            ok scalar(grep { $_ eq 'Total||160|125|3|270|210|2|300|250|1|730|585|6' } @$kept), 'and so does the total';
            # Every Total column equals the sum of the columns shown.
            for my $row (@$kept) {
                my @cells = map { $_ eq '—' ? 0 : $_ } (split /\|/, $row, -1)[2 .. 13];
                is $cells[9 + $_], $cells[$_] + $cells[3 + $_] + $cells[6 + $_], "row total $_ adds up: $row" for 0 .. 2;
            }
            is $left_out->find('input[name="group_exclude_missing"][value="destination"][checked]')->size, 1, 'the box stays ticked';
            is $left_out->find('[data-sc-group-filters] [data-sc-group-filter="destination"]')->size, 1, 'the filter is listed, from the group';
            like $left_out->at('[data-sc-group-filter="destination"]')->all_text, qr/Destination.*has a value.*from Group By/s;
            is $left_out->find('[data-sc-filter-set] [data-sc-filter-set-item]')->size, 0, 'it is not an editable filter';
            like $left_out->to_string, qr/[?&;]group_exclude_missing=destination(?:&|")/, 'it is carried in generated links';
            unlike $left_out->to_string, qr/filter_op=not_null/, 'and never as a filter parameter';

            my $moved = $get->('/loads', q => 1, view => 'aggregate', field => 'id', group => [qw(origin days)],
                group_format => ['', 'buckets'], group_bucket_ranges => ['', '5-9, 10-20, 21+'],
                measure => [qw(price pay loads)], limit => 25, page => 1, group_exclude_missing => 'destination');
            ok !$moved->at('[data-sc-group-filter]'), 'removing the group removes its filter';
            is rows_of($moved, '.sc-results tbody tr')->[0], 'Total||750|595|7', 'and the rows come back';

            my $plain_left_out = $get->('/loads', q => 1, view => 'aggregate', field => 'id', group => [qw(origin destination)],
                measure => [qw(price pay loads)], limit => 25, page => 1, group_exclude_missing => 'destination');
            is_deeply rows_of($plain_left_out, '.sc-results tbody tr'),
                ['Total||730|585|6', 'MI||660|525|5', '|OH|310|235|3', '|TX|350|290|2', 'OH||70|60|1', '|TX|70|60|1'],
                'the plain summary table leaves them out of rows and totals';
            my $grid = $get->('/loads', q => 1, view => 'aggregate', aggregate_grid => 1, field => 'id',
                group => [qw(origin destination)], measure => 'loads', limit => 25, page => 1, group_exclude_missing => 'destination');
            is_deeply [map { text_of($_) =~ s/\x{2713}//gr } @{$grid->find('.sc-aggregate-grid tbody tr.sc-grid-total-row > *')}],
                [qw(Total 3 3 6)], 'the grid leaves them out of its totals';
            my $graph = $get->('/loads', q => 1, view => 'graph', field => 'id', group => 'destination',
                measure => 'loads', group_exclude_missing => 'destination');
            is $graph->find('input[name="group_exclude_missing"][checked]')->size, 1, 'the graph view offers and keeps it';
            unlike $graph->to_string, qr/\[NULL\]/, 'and its data has no missing-value point';

            my %drill;
            push @{$drill{$_->attr('name')}}, $_->attr('value') for @{$left_out->find('form.sc-pivot-drill-form input[type="hidden"]')};
            $t->get_ok('/loads' => form => {%drill, grid_axis => '{"axis":2,"value":"5-9"}'})->status_is(200);
            is_deeply [sort map { text_of($_) } @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}], [1, 3, 6],
                'drilling from a column leaves the same rows out';
        };
    };
}

plan skip_all => 'no database driver is available' unless $ran;
done_testing;
