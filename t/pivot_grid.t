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
use Selecto::Components::Explorer ();
use Selecto::Components::Dashboard ();

# The aggregate grid with one group marked "Show as columns": the other groups
# are rows and every measure sits under each column value. SQLite runs in
# memory; PostgreSQL runs when SELECTO_PERL_TEST_POSTGRES_URL is set.
my $table = 'selecto_components_pivot_' . $$;
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

sub texts {
    my ($dom, $selector) = @_;
    return [map { my $text = $_->all_text; $text =~ s/[\s\x{2713}]+//g; $text } @{$dom->find($selector)}];
}

# Three groups, the last bucketed in an order that text sorting would change.
my @pivot = (q => 1, view => 'aggregate', aggregate_grid => 1, field => 'id',
    group => [qw(origin destination days)], group_alias => ['', '', ''],
    group_format => ['', '', 'buckets'], group_bucket_ranges => ['', '', '5-9, 10-20, 21+'],
    measure => [qw(price pay loads)], limit => 25, page => 1);

my $ran = 0;
my $some_state;
for my $backend (qw(sqlite postgresql)) {
    my $dbh = $connect{$backend}->() or next;
    $ran++;
    subtest $backend => sub {
        $dbh->do("CREATE TABLE $table (id integer primary key, origin varchar(4), destination varchar(4), days integer, price integer, pay integer)");
        push @cleanup, $dbh if $backend eq 'postgresql';
        $dbh->do("INSERT INTO $table VALUES (1,'MI','OH',7,100,80), (2,'MI','OH',15,200,150), (3,'MI','TX',8,50,40),
            (4,'MI','TX',30,300,250), (5,'OH','TX',12,70,60), (6,'MI','OH',6,10,5)");
        my $domain = Selecto::Domain->new(name => 'Loads', table => $table,
            fields => {id => 'integer', origin => 'string', destination => 'string', days => 'integer',
                price => 'integer', pay => 'integer'});
        my $adapter = Selecto->adapter($backend => (dbh => $dbh));
        plan skip_all => 'this selecto-perl has no grouping sets' unless $adapter->supports('grouping_sets');
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
        $app->secrets(['pivot-grid-test']);
        $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {
            loads => {%explorer},
            narrow => {%explorer, path => '/narrow', max_grid_columns => 2},
            shown => {%explorer, path => '/shown', show_sql => 1},
        }});
        my $t = Test::Mojo->new($app);

        $t->get_ok('/loads' => form => {@pivot, grid_column => 'days'})->status_is(200)
            ->element_exists('table.sc-aggregate-grid.sc-pivot-grid')
            or diag $t->tx->res->dom->find('.sc-error, [role=alert], .sc-grid-warning')->map('all_text')->join('; ');
        my $dom = $t->tx->res->dom;

        is_deeply texts($dom, '.sc-pivot-grid thead tr:nth-child(1) > th'),
            ['Origin', 'Destination', '5-9', '10-20', '21+', 'Total'],
            'row group headers, then bucket columns in the order the ranges were given, then Total';
        is_deeply texts($dom, '.sc-pivot-grid thead tr:nth-child(2) > th'), [('Price', 'Pay', 'Count') x 4],
            'each column value and the total have one sub-column per measure';
        is_deeply texts($dom, '.sc-pivot-grid tbody tr:nth-child(1) > *'),
            [qw(MI OH 110 85 2 200 150 1), '—', '—', '—', qw(310 235 3)], 'MI to OH, with its row totals';
        is_deeply texts($dom, '.sc-pivot-grid tbody tr:nth-child(2) > *'),
            [qw(MI TX 50 40 1), '—', '—', '—', qw(300 250 1 350 290 2)], 'MI to TX';
        is_deeply texts($dom, '.sc-pivot-grid tbody tr:nth-child(3) > *'),
            [qw(OH TX), '—', '—', '—', qw(70 60 1), '—', '—', '—', qw(70 60 1)], 'OH to TX';
        is_deeply texts($dom, '.sc-pivot-grid tbody tr.sc-grid-total-row > *'),
            [qw(Total 160 125 3 270 210 2 300 250 1 730 585 6)], 'column totals and the grand total';

        subtest 'accessibility' => sub {
            is $dom->find('.sc-pivot-grid thead tr:nth-child(1) > th[scope="colgroup"][colspan="3"]')->size, 4, 'column groups span their measures';
            is $dom->find('.sc-pivot-grid thead tr:nth-child(1) > th[scope="col"][rowspan="2"]')->size, 2, 'row group headers span both rows';
            is $dom->find('.sc-pivot-grid thead tr:nth-child(2) > th[scope="col"]')->size, 12, 'measure headers';
            my $cell = $dom->at('.sc-pivot-grid tbody tr:nth-child(1) > td:nth-of-type(2)');
            my %header = map { ($_->attr('id') => $_->all_text =~ s/\s+//gr) } @{$dom->find('.sc-pivot-grid th[id]')};
            is_deeply [map { $header{$_} } split ' ', $cell->attr('headers')], [qw(MI OH 5-9 Pay)],
                'a cell names its row values, its column value and its measure';
            my %seen;
            ok !grep({ $seen{$_}++ } keys %header) && keys(%header) == $dom->find('.sc-pivot-grid th[id]')->size, 'header ids are distinct';
        };

        subtest 'selection' => sub {
            is $dom->find('.sc-pivot-grid input[name="grid_cell"]')->size, 9, 'one selectable cell for each row and column value';
            is_deeply from_json($dom->at('.sc-pivot-grid tbody tr:nth-child(1) input[name="grid_cell"]')->attr('value')),
                ['MI', 'OH', '5-9'], 'a cell is one value per group, whichever measure is clicked';
            my $first = $dom->at('.sc-pivot-grid tbody tr:nth-child(1) input[name="grid_cell"]');
            is $dom->find('.sc-pivot-grid tbody tr:nth-child(1) label[for="' . $first->attr('id') . '"]')->size, 2,
                'the other measures of the cell toggle the same box';
            is_deeply from_json($dom->at('.sc-pivot-grid tbody tr:nth-child(1) input[data-sc-grid-row-toggle]')->attr('value')),
                {axes => [0, 1], values => ['MI', 'OH']}, 'a row header selects its row groups together';
            is_deeply from_json($dom->at('.sc-pivot-grid thead input[data-sc-grid-column-toggle="1"]')->attr('value')),
                {axis => 2, value => '10-20'}, 'a column header selects its column value';

            my @detail = (q => 1, view => 'detail', field => [qw(id origin destination days)],
                group => [qw(origin destination days)], group_alias => ['', '', ''],
                group_format => ['', '', 'buckets'], group_bucket_ranges => ['', '', '5-9, 10-20, 21+'],
                measure => 'loads', order => 'id', direction => 'asc', limit => 25, page => 1);
            my $ids = sub {
                my %more = @_;
                $t->get_ok('/loads' => form => {@detail, %more})->status_is(200);
                return [map { $_->all_text =~ s/\s+//gr } @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}];
            };
            is_deeply $ids->(grid_cell => '["MI","OH","5-9"]'), [1, 6], 'a cell filters on row values and the column value';
            is_deeply $ids->(grid_axis => '{"axes":[0,1],"values":["MI","TX"]}'), [3, 4], 'a row header filters on its row groups';
            is_deeply $ids->(grid_axis => '{"axis":2,"value":"10-20"}'), [2, 5], 'a column header filters on the column value';
            is_deeply $ids->(grid_axis => '{"axes":[0,1],"values":["MI","TX"]}', grid_cell => ['["MI","TX","5-9"]', '["OH","TX","10-20"]']),
                [3, 4, 5], 'a cell inside a selected row adds nothing; another cell is an alternative';
            $t->get_ok('/loads' => form => {@detail, grid_cell => '["MI","OH"]'})->status_is(422);
            $t->get_ok('/loads' => form => {@detail, grid_axis => '{"axes":[0,7],"values":["MI","TX"]}'})->status_is(422);
        };

        subtest 'the column group need not be last' => sub {
            $t->get_ok('/loads' => form => {@pivot, grid_column => 'destination'})->status_is(200);
            my $other = $t->tx->res->dom;
            is_deeply texts($other, '.sc-pivot-grid thead tr:nth-child(1) > th'), ['Origin', 'Days', 'OH', 'TX', 'Total'], 'destination across';
            is_deeply texts($other, '.sc-pivot-grid tbody tr:nth-child(1) > *'),
                [qw(MI 5-9 110 85 2 50 40 1 160 125 3)], 'origin and day bucket down, in range order';
            is_deeply from_json($other->at('.sc-pivot-grid tbody tr:nth-child(1) input[name="grid_cell"]')->attr('value')),
                ['MI', 'OH', '5-9'], 'cell values stay in group order';
            is_deeply from_json($other->at('.sc-pivot-grid thead input[data-sc-grid-column-toggle="0"]')->attr('value')),
                {axis => 1, value => 'OH'};
        };

        subtest 'two groups and several measures' => sub {
            $t->get_ok('/loads' => form => {q => 1, view => 'aggregate', aggregate_grid => 1, field => 'id',
                group => [qw(origin destination)], measure => [qw(price loads)], grid_column => 'origin', limit => 25, page => 1})->status_is(200);
            my $two = $t->tx->res->dom;
            is_deeply texts($two, '.sc-pivot-grid thead tr:nth-child(1) > th'), [qw(Destination MI OH Total)], 'the first group across';
            is_deeply texts($two, '.sc-pivot-grid tbody tr > *'),
                [qw(OH 310 3), '—', '—', qw(310 3), qw(TX 350 2 70 1 420 3), qw(Total 660 5 70 1 730 6)], 'cells and totals';
            is_deeply from_json($two->at('.sc-pivot-grid tbody tr:nth-child(1) input[data-sc-grid-row-toggle]')->attr('value')),
                {axis => 1, value => 'OH'}, 'one row group selects as a single axis';
        };

        subtest 'the original shape is untouched' => sub {
            my @legacy = (q => 1, view => 'aggregate', aggregate_grid => 1, field => 'id',
                group => [qw(origin destination)], measure => 'loads', limit => 25, page => 1);
            $t->get_ok('/loads' => form => {@legacy})->status_is(200)->element_exists('table.sc-aggregate-grid')
                ->element_exists_not('table.sc-pivot-grid');
            my $legacy = $t->tx->res->dom;
            is $legacy->find('.sc-aggregate-grid thead tr')->size, 1, 'one header row';
            is_deeply texts($legacy, '.sc-aggregate-grid thead th'), ['Origin/Destination', 'OH', 'TX', 'Total'], 'second group across';
            is_deeply texts($legacy, '.sc-aggregate-grid tbody tr > *'), [qw(MI 3 2 5 OH), '—', qw(1 1 Total 3 3 6)];
            is_deeply from_json($legacy->at('.sc-aggregate-grid tbody input[name="grid_cell"]')->attr('value')), ['MI', 'OH'];
            is_deeply from_json($legacy->at('.sc-aggregate-grid tbody input[data-sc-grid-row-toggle]')->attr('value')), {axis => 0, value => 'MI'};
            is_deeply from_json($legacy->at('.sc-aggregate-grid thead input[data-sc-grid-column-toggle]')->attr('value')), {axis => 1, value => 'OH'};

            $t->get_ok('/loads' => form => {@legacy, grid_column => 'origin'})->status_is(200)->element_exists_not('table.sc-pivot-grid');
            my $swapped = $t->tx->res->dom;
            is_deeply texts($swapped, '.sc-aggregate-grid thead th'), ['Destination/Origin', 'MI', 'OH', 'Total'], 'grid_column swaps the axes';
            is_deeply from_json($swapped->at('.sc-aggregate-grid tbody input[name="grid_cell"]')->attr('value')), ['MI', 'OH'], 'cell values stay in group order';
            is_deeply from_json($swapped->at('.sc-aggregate-grid tbody input[data-sc-grid-row-toggle]')->attr('value')), {axis => 1, value => 'OH'};

            $t->get_ok('/loads' => form => {@pivot})->status_is(200)->element_exists_not('table.sc-aggregate-grid')
                ->text_like('.sc-grid-warning' => qr/exactly two Group By fields and one Aggregate\. For more, mark one Group By as Show as columns\./);
        };

        subtest 'the Total columns can be turned off' => sub {
            $t->get_ok('/loads' => form => {@pivot, pivot_column => 'days', pivot_totals => 0})->status_is(200);
            my $off = $t->tx->res->dom;
            is_deeply texts($off, '.sc-pivot-grid thead tr:nth-child(1) > th'),
                ['Origin', 'Destination', '5-9', '10-20', '21+'], 'no Total column group';
            is_deeply texts($off, '.sc-pivot-grid thead tr:nth-child(2) > th'), [('Price', 'Pay', 'Count') x 3];
            is_deeply texts($off, '.sc-pivot-grid tbody tr:nth-child(1) > *'),
                [qw(MI OH 110 85 2 200 150 1), '—', '—', '—'], 'the cells are unchanged';
            is_deeply texts($off, '.sc-pivot-grid tbody tr:nth-child(2) > *'),
                [qw(MI TX 50 40 1), '—', '—', '—', qw(300 250 1)];
            is_deeply texts($off, '.sc-pivot-grid tbody tr.sc-grid-total-row > *'),
                [qw(Total 160 125 3 270 210 2 300 250 1)], 'the Total row stays, without the grand total';
            like $off->to_string, qr/[?&;]pivot_totals=0(?:&|")/, 'the setting is carried in generated links';
            unlike $dom->at('.sc-results')->to_string, qr/pivot_totals/, 'and left out when on';

            my $controller = $app->build_controller;
            my $explorer = $controller->selecto_components_explorer('loads');
            my $model = $explorer->model($controller, {@pivot, pivot_column => 'days', pivot_totals => 0});
            my $shown = $controller->selecto_components_explorer('shown');
            my $sql_on = $shown->model($controller, {@pivot, pivot_column => 'days'})->{result}{sql};
            my $sql_off = $shown->model($controller, {@pivot, pivot_column => 'days', pivot_totals => 0})->{result}{sql};
            cmp_ok length($sql_off), '<', length($sql_on), 'the query leaves out the grouping sets only the Total columns need';
            if ($backend eq 'postgresql') {
                like $sql_on, qr/GROUPING SETS \(.*\(\s*\)\)/s, 'with them: the grand total set';
                unlike $sql_off, qr/GROUPING SETS \(.*\(\s*\)\)/s, 'without them: none';
            }
            my $again = $explorer->model($controller, Selecto::Components::Dashboard->new->input_from_url(
                $explorer->canonical_url($model->{state}, $model->{domain})));
            is $again->{state}->pivot_totals, 0, 'a saved view URL restores it';
            ok !$again->{result}{grid_data}{total_columns}, 'and the grid has no Total columns again';
            my @lines = map { s/"//gr } split /\r?\n/, $explorer->export($model, 'csv');
            is $lines[0], join(',', 'Origin', 'Destination', map { my $c = $_; map { "$c \x{b7} $_" } qw(Price Pay Count) } '5-9', '10-20', '21+'),
                'export has no Total columns';
            is $lines[1], 'MI,OH,110,85,2,200,150,1,,,', 'a row without its totals';
            is $lines[-1], 'Total,,160,125,3,270,210,2,300,250,1', 'the total row';

            # Two groups, one measure: with a column group the option applies;
            # without one the grid keeps its Total column.
            my @two = (q => 1, view => 'aggregate', aggregate_grid => 1, field => 'id',
                group => [qw(origin destination)], measure => 'loads', limit => 25, page => 1);
            $t->get_ok('/loads' => form => {@two, pivot_totals => 0})->status_is(200);
            is_deeply texts($t->tx->res->dom, '.sc-aggregate-grid thead th'), ['Origin/Destination', 'OH', 'TX', 'Total'],
                'a grid without a column group keeps its Total column';
            $t->get_ok('/loads' => form => {@two, pivot_column => 'destination', pivot_totals => 0})->status_is(200);
            is_deeply texts($t->tx->res->dom, '.sc-aggregate-grid thead th'), ['Origin/Destination', 'OH', 'TX'];
            is_deeply texts($t->tx->res->dom, '.sc-aggregate-grid tbody tr > *'), [qw(MI 3 2 OH), '—', qw(1 Total 3 3)];
        };

        subtest 'limits refuse and say why' => sub {
            $t->get_ok('/narrow' => form => {@pivot, grid_column => 'days'})->status_is(200)
                ->element_exists_not('table.sc-aggregate-grid')
                ->text_like('.sc-grid-warning' => qr/more than 2 columns/);
            $t->get_ok('/narrow' => form => {@pivot, grid_column => 'origin'})->status_is(200)
                ->element_exists('table.sc-pivot-grid');
        };

        subtest 'state and export' => sub {
            $t->get_ok('/loads' => form => {@pivot, grid_column => 'nowhere'})->status_is(422);
            $t->get_ok('/loads' => form => {@pivot, grid_column => [qw(days origin)]})->status_is(422);
            $t->get_ok('/loads' => form => {@pivot, grid_column => 'days'})->status_is(200);
            like $t->tx->res->body, qr/[?&;]pivot_column=days(?:&|")/, 'the old grid_column spelling is read and written back as pivot_column';

            # The web export refuses every grid; a host exports one from its model.
            my $controller = $app->build_controller;
            my $explorer = $controller->selecto_components_explorer('loads');
            my %input = @pivot;
            my $model = $explorer->model($controller, {%input, grid_column => 'days'});
            ok $model->{state}->valid && $model->{result}{grid_data}{pivot}, 'a pivot model';
            is $model->{state}->pivot_column, 'days', 'the state carries the column group';
            $some_state //= $model->{state};
            my %pairs = @{$model->{state}->query_pairs};
            is $pairs{pivot_column}, 'days', 'and writes it back as pivot_column';
            my $again = $explorer->model($controller, Selecto::Components::Dashboard->new->input_from_url(
                $explorer->canonical_url($model->{state}, $model->{domain})));
            is $again->{state}->pivot_column, 'days', 'a saved view URL restores it';
            ok $again->{result}{grid_data}{pivot}, 'and renders the same pivot';

            my @lines = map { s/"//gr } split /\r?\n/, $explorer->export($model, 'csv');   # every field is quoted
            is $lines[0], join(',', 'Origin', 'Destination', map { my $c = $_; map { "$c \x{b7} $_" } qw(Price Pay Count) } '5-9', '10-20', '21+', 'Total'),
                'export headers are "<column value> · <measure>"';
            is $lines[1], 'MI,OH,110,85,2,200,150,1,,,,310,235,3', 'a row with its empty cells and totals';
            is $lines[-1], 'Total,,160,125,3,270,210,2,300,250,1,730,585,6', 'the total row';
            ok length($explorer->export($model, 'xlsx')) > 1000, 'the workbook builds';

            $t->get_ok('/loads' => form => {@pivot, grid_column => 'days', view => 'graph'})->status_is(200);
            unlike $t->tx->res->body, qr/[?&;](?:grid|pivot)_column=/, 'the choice belongs to the aggregate view only';
        };
    };
}

subtest 'rendered cells are counted with measures and totals' => sub {
    my $built = {aggregate_grid => 1, rollup => 1, cube => 1, grid => {column => 1, rows => [0], totals => 1},
        columns => [{key => 'a', field => 'a'}, {key => 'b', field => 'b'}, {key => 'm1', measure => 1}, {key => 'm2', measure => 1}]};
    my @records = map {
        my ($a, $b, $mask) = @$_;
        {a => $a, b => $b, m1 => 1, m2 => 2, __selecto_rollup_level => 2 - ($mask ? 1 : 0), __selecto_grouping_mask => $mask}
    } ['x', 'p', 0], ['x', 'q', 0], ['y', 'p', 0], ['x', undef, 1], ['y', undef, 1], [undef, 'p', 2], [undef, 'q', 2], [undef, undef, 3];
    plan skip_all => 'no database driver is available' unless $some_state;
    my $state = $some_state;
    my $data = sub { my @limits = @_; Selecto::Components::Explorer::_aggregate_grid_data($state, $built, \@records, [map { [] } @records], @limits) };
    # (2 rows + total) x (2 columns + total) x 2 measures = 18 rendered cells.
    ok !$data->(18, 50)->{limit_exceeded}, 'eighteen cells fit a limit of eighteen';
    is_deeply $data->(17, 50), {limit_exceeded => 1, limit => {kind => 'cells', limit => 17}}, 'and not seventeen';
    is_deeply $data->(100, 1), {limit_exceeded => 1, limit => {kind => 'columns', limit => 1}}, 'the column limit is checked first';
    is $data->(100, 50)->{totals}{grand}{values}{m2}, 2, 'totals carry every measure';
    # Without the Total columns: (2 rows + total) x 2 columns x 2 measures = 12.
    $built->{grid}{total_columns} = 0;
    ok !$data->(12, 50)->{limit_exceeded}, 'twelve cells fit once the Total columns are off';
    ok $data->(11, 50)->{limit_exceeded}, 'and not eleven';
};

plan skip_all => 'no database driver is available' unless $ran;
done_testing;
