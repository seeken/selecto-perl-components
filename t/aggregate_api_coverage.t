use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI;
use Mojo::JSON qw(decode_json);
use Mojo::URL;
use Mojo::Util qw(url_unescape);
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::Renderer;

sub relation {
    my ($table, $types, %extra) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %$types],
        columns => {map { ($_ => {type => $types->{$_},
            ($table eq 'coverage_notes' && $_ eq 'stage' ? (value_order => ['open', 'done']) : ())}) } keys %$types}, associations => {}, %extra};
}

for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? ('postgresql') : ())) {
    subtest $backend => sub {
        my $dbh;
        if ($backend eq 'postgresql') {
            my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
            die 'An explicit owned RAM database on port 55448 is required'
                unless $url->host eq '127.0.0.1' && $url->port && $url->port == 55448 && $url->path ne '/postgres';
            $dbh = DBI->connect('dbi:Pg:dbname=' . substr($url->path, 1) . ';host=' . $url->host . ';port=' . $url->port,
                $url->username, $url->password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        } else {
            $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
        }
        $dbh->do('CREATE TEMP TABLE coverage_items (id integer, tenant_id integer, area text, stage text, points integer, day date)');
        $dbh->do('CREATE TEMP TABLE coverage_notes (id integer, tenant_id integer, item_id integer, kind text, stage text, weight integer)');
        $dbh->do('INSERT INTO coverage_items VALUES (?,?,?,?,?,?)', undef, @$_) for
            [1, 1, 'A', 'open', 2, '2026-05-10'], [2, 1, 'A', 'done', 5, '2026-05-10'],
            [3, 1, 'B', 'open', 7, '2026-05-11'], [4, 1, 'A', undef, 3, '2026-05-10'],
            [5, 1, undef, 'done', 6, '2026-05-10'], [1, 2, 'Z', 'private', 900, '2026-05-10'];
        $dbh->do('INSERT INTO coverage_notes VALUES (?,?,?,?,?,?)', undef, @$_) for
            [10, 1, 1, 'memo', 'open', 2], [11, 1, 1, 'memo', 'open', 4],
            [12, 1, 2, 'mark', 'done', 7], [13, 1, 3, 'memo', 'done', 8],
            [14, 1, 3, 'mark', undef, 3],
            [10, 2, 1, 'private', 'private', 999];
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Coverage items',
            source => relation('coverage_items', {id => 'integer', tenant_id => 'integer', area => 'string',
                stage => 'string', points => 'integer', day => 'date'}, tenant_field => 'tenant_id',
                associations => {notes => {queryable => 'note', owner_key => 'id', related_key => 'item_id'}}),
            schemas => {note => relation('coverage_notes', {id => 'integer', tenant_id => 'integer', item_id => 'integer',
                kind => 'string', stage => 'string', weight => 'integer'}, tenant_field => 'tenant_id')},
            joins => {}, retarget => {targets => {notes => {label => 'Notes'}}},
            query_library => {segments => {area_a => {filters => [['eq', 'area', 'A']]}}}}, strict => 1);
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => dbh => $dbh), scope => {tenant => 1});
        my $app = Mojolicious->new;
        $app->secrets(['coverage-invented-fixture']); $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {items => {
            path => '/items', title => 'Items', default_fields => ['id'], default_group => ['area'],
            default_limit => 25, max_limit => 100, engine_factory => sub { $engine },
            measures => [{id => 'n', label => 'N', aggregate => 'count'},
                {id => 'score', label => 'Score', aggregate => 'sum', field => 'points'},
                {id => 'weight', label => 'Weight', aggregate => 'sum', field => 'notes.weight'}],
            canonical_api_path => '/api/items', canonical_authorizer => sub { 1 },
            canonical_publication => sub { 'coverage-reader' },
            canonical_explorer => {clock => '2030-01-01T12:00:00Z'},
            api_console_resolver => sub { '/api/items/console' },
        }}});
        $app->routes->get('/token')->to(cb => sub { my $c = shift; $c->render(text => $c->csrf_token) });
        my $t = Test::Mojo->new($app);
        my $csrf = $t->get_ok('/token')->tx->res->text;
        my $c = $app->build_controller;
        my $explorer = $c->selecto_components_explorer('items');
        my $config = $explorer->config;
        my %base = (q => 1, view => 'aggregate', field => 'id', rows_of => '-', group => ['area'], measure => ['n'], limit => 25, page => 1);
        my $round = sub {
            my ($extra) = @_;
            my %input = (%base, %$extra);
            $t->get_ok('/items' => form => \%input)->status_is(200);
            my $link = $t->tx->res->dom->at('a[data-sc-api-console]');
            ok $link, 'native view renders an API link' or do {
                diag $t->tx->res->dom->at('[data-sc-api-console]')->to_string;
                my $failed = $explorer->model($c, \%input);
                diag explain $failed->{state}->errors, $failed->{runtime_error};
                return;
            };
            my ($encoded) = Mojo::URL->new($link->{href})->fragment =~ /\Arequest=(.*)\z/;
            my $payload = decode_json(url_unescape($encoded));
            $t->post_ok('/api/items/explorer-query' => {'X-CSRF-Token' => $csrf} => json => $payload)->status_is(200);
            my $response = $t->tx->res->json;
            diag explain $response unless $response->{data};
            my $model = $explorer->model($c, \%input);
            ok $model->{state}->valid, 'native state valid' or diag explain $model->{state}->errors;
            is $model->{runtime_error}, undef, 'native executes';
            my $r = $model->{result};
            my @groups = grep { !$_->{measure} } @{$r->{columns}};
            my @measures = grep { $_->{measure} } @{$r->{columns}};
            my (@expected, @ids, @pivot_meta);
            my %group_ids;
            for my $g (@{$payload->{query}{group_by}}) { $group_ids{ref($g) ? $g->{field} : $g} = ref($g) ? $g->{alias} : $g }
            @ids = map { $group_ids{$_->{source_field}} } @groups;
            if (my $p = $r->{pivot_data}) {
                for my $i (0 .. $#{$p->{columns}}) {
                    my $col = $p->{columns}[$i];
                    my $gc = $model->{state}->group_configs->{$model->{state}->pivot_column};
                    my $other = defined($col->{selection_value}) && $col->{selection_value} eq ($gc->{pivot_other_value} // '') ? 1 : 0;
                    my $value = $other || (defined($col->{selection_value}) && $col->{selection_value} eq ($gc->{pivot_null_value} // ''))
                        ? undef : $col->{selection_value};
                    for my $m (0 .. $#measures) {
                        push @ids, "__pivot_${i}_$m";
                        push @pivot_meta, {column => $payload->{query}{pivot}{column}, value => $value,
                            other => $other ? Mojo::JSON::true : Mojo::JSON::false,
                            measure => $payload->{query}{select}[-@measures + $m]{alias}};
                    }
                }
                if ($p->{totals}) {
                    for my $m (0 .. $#measures) {
                        my $id = $payload->{query}{select}[-@measures + $m]{alias};
                        push @ids, '__pivot_total_' . $id;
                        push @pivot_meta, {column => $payload->{query}{pivot}{column}, total => Mojo::JSON::true, measure => $id};
                    }
                }
            } else { push @ids, map { $_->{alias} } grep { ref($_) && $_->{aggregate} } @{$payload->{query}{select}} }
            for my $record (grep { !$_->{__selecto_rollup_continued} } @{$r->{records}}) {
                my $level = $r->{rollup} ? $record->{__selecto_rollup_level} : scalar @groups;
                my @row = map { $_ < $level ? $record->{$groups[$_]{key}} : undef } 0 .. $#groups;
                if (my $p = $r->{pivot_data}) {
                    my $cells = $p->{cells_for}->($record);
                    for my $column (@{$p->{columns}}) {
                        push @row, map { ($cells->{$column->{key}} // {})->{$_->{key}} } @measures;
                    }
                    push @row, map { $record->{$_->{key}} } @measures if $p->{totals};
                } else { push @row, map { $record->{$_->{key}} } @measures }
                push @expected, \@row;
            }
            is_deeply $response->{data}{rows}, \@expected, 'exact native page, cells and totals (no display headers)';
            is_deeply [map { $_->{id} } @{$response->{data}{columns} // []}], \@ids, 'column identities and order match native view';
            is_deeply [map { $_->{pivot} } grep { $_->{pivot} } @{$response->{data}{columns}}], \@pivot_meta,
                'pivot metadata retains typed values, Other and totals';
            return ($payload, $model, $response);
        };
        subtest 'As of' => sub {
            my ($p, $m, $r) = $round->({as_of => '2026-05-10', filter_field => 'day', filter_op => 'date_shortcut', filter_value => 'today'});
            is $p->{query}{as_of}, '2026-05-10', 'read clock handed over';
            is $r->{meta}{as_of}, '2026-05-10', 'route echoes read clock';
            $round->({as_of => '2026-05-11T00:30:00+02:00'});
            # Query timezones are not URL state; preserve a timezone supplied
            # by a native query integration without changing Detail handling.
            $m->{result}{query} = $m->{result}{query}->use_timezone($backend eq 'postgresql' ? 'America/Denver' : 'UTC');
            my $handoff = Selecto::Components::APIHandoff->aggregate($m, $c);
            is $handoff->{payload}{query}{timezone}, $m->{result}{query}->timezone, 'native query timezone retained';
        };
        my %target = (rows_of => 'notes', field => 'notes.id', group => ['notes.kind'],
            measure => ['n', 'weight'], measure_alias => ['', 'w'], filter_field => 'area', filter_op => 'eq', filter_value => 'A');
        subtest 'Retarget' => sub {
            my ($p) = $round->(\%target);
            is $p->{query}{retarget}, 'notes', 'retarget path handed over';
            is_deeply $p->{query}{filters}, [{field => 'area', op => 'eq', value => 'A'}], 'filter stays root context';
            $round->({%target, query_library_segment => 'area_a'});
        };
        my %pivot = (group => ['area', 'stage'], pivot_column => 'stage', measure => ['n', 'score'], measure_alias => ['', 's']);
        subtest 'Summary pivots' => sub {
            for my $variant ({}, {pivot_totals => 0}, {pivot_column_value => ['open', 'empty'], pivot_column_other => 1},
                {pivot_column_value => ['open']}, {pivot_column_value => ['missing', 'done'], pivot_column_value_null => 0, pivot_column_other => 1},
                {pivot_column_top => 1, pivot_column_top_measure => 'score', pivot_column_other => 1},
                {pivot_column_top => 2, pivot_column_top_order => 'natural'},
                {measure => ['score', 'score'], measure_function => ['avg', 'count_distinct'], measure_alias => ['mean', 'distinct_points']},
                {group => ['area', 'day'], pivot_column => 'day', group_format => ['', 'month'], group_alias => ['', 'period'], pivot_column_top => 1},
                {group => ['area', 'points'], pivot_column => 'points', pivot_column_value => ['2', '5'], pivot_column_other => 1}) {
                $round->({%pivot, %$variant});
            }
        };
        subtest 'Partial subtotal pages' => sub {
            for my $groups (['area'], ['area', 'stage']) {
                for my $page (1, 2, 3) {
                    for my $order ({}, {order => 'measure:score', direction => 'desc'}, {order => 'measure:score', direction => 'asc'}) {
                        my ($p) = $round->({group => $groups, measure => ['n', 'score'], limit => 2, page => $page, %$order});
                        is $p->{query}{subtotal_position}, 'before', 'native subtotal order requested';
                        is $p->{query}{offset}, 2 * ($page - 1), 'native page offset';
                    }
                }
            }
        };
        my %compound = (%target, group => ['notes.kind', 'notes.stage'], pivot_column => 'notes.stage', pivot_column_value => ['open'], pivot_column_other => 1);
        subtest 'Retargeted pivot cells and ranking' => sub {
            my ($p, $m, $r) = $round->(\%compound);
            is $r->{data}{rows}[0][-4], 1, 'Other counts one target, excluding unmatched root';
            is $r->{data}{rows}[0][-2], 3, 'three target rows in total';
            is_deeply $p->{query}{pivot}{value_order}, ['open', 'done'], 'declared column value order handed over';
            for my $order ('rank', 'natural') {
                my %input = (%compound, pivot_column_top => 1, pivot_column_top_measure => 'n', pivot_column_top_order => $order);
                delete $input{pivot_column_value};
                my ($payload, $native, $response) = $round->(\%input);
                is $response->{data}{columns}[1]{pivot}{value}, 'open', 'global ranking counts target rows';
                is $payload->{query}{pivot}{top}{measure}, 'n', 'ranking uses selected measure alias';
            }
            $round->({%compound, limit => 2, page => 2});
            $round->({%compound, pivot_column_value => ['notes.stage', 'open']});
            $round->({%compound, filter_value => 'B'});
            $round->({%compound, filter_value => 'B', pivot_column_value => ['missing'], pivot_column_value_null => 0});
        };
        subtest 'Capability gates and limits' => sub {
            my $disabled = sub {
                my ($options, $input, $reason) = @_;
                $config->canonical_explorer({clock => '2030-01-01T12:00:00Z', %$options});
                my $m = $explorer->model($c, {%base, %$input});
                is $m->{runtime_error}, undef, 'native still succeeds when handoff is refused';
                like(Selecto::Components::Renderer->_api_console_control($m), $reason, 'specific disabled title');
                $config->canonical_explorer({clock => '2030-01-01T12:00:00Z'});
            };
            my %cases = (as_of => {as_of => '2026-05-10'}, retarget => \%target, pivot => \%pivot,
                subtotal_position => {group => ['area', 'stage'], limit => 2, page => 2});
            for my $flag (sort keys %cases) {
                $disabled->({supports => {$flag => 0}}, $cases{$flag}, qr/supports\.$flag/);
                my $features = Selecto::API::Explorer->can('features');
                no warnings 'redefine';
                local *Selecto::API::Explorer::features = sub { my $f = $features->(@_); delete $f->{supports}{$flag}; return $f };
                $disabled->({}, $cases{$flag}, qr/supports\.$flag/);
            }
            $disabled->({limits => {max_buckets => 1}}, \%pivot, qr/max_buckets/);
            $disabled->({limits => {max_buckets => 2}}, {%pivot, pivot_column_top => 2, pivot_column_other => 1}, qr/top-N.*max_buckets/);
            $disabled->({limits => {max_result_cells => 2}}, \%pivot, qr/max_result_cells/);
            $disabled->({limits => {max_groups => 1}}, \%pivot, qr/max_groups/);
            $disabled->({limits => {max_group_by => 1}}, \%pivot, qr/max_group_by/);
            $disabled->({limits => {max_aggregates => 1}}, \%pivot, qr/max_aggregates/);
            $disabled->({limits => {max_select => 3}}, \%pivot, qr/max_select/);
            $disabled->({}, {%pivot, pivot_column_other => 1}, qr/Other pivot column requires chosen values or top-N/);
            $disabled->({}, {%pivot, pivot_column_top => 1, filter_field => 'area', filter_op => 'eq', filter_value => 'absent'}, qr/empty top-N pivot/);
            $disabled->({}, {group_alias => ['Area']}, qr/Aliases on unformatted/);
            $disabled->({}, {filter_field => 'day', filter_op => 'date_shortcut', filter_value => 'today'}, qr/different clock/);
        };
        $dbh->disconnect;
    };
}
done_testing;
