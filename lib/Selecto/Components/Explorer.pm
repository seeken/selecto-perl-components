package Selecto::Components::Explorer;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json to_json);
use Mojo::URL ();
use File::Temp qw(tempfile tempdir);
use File::Find ();
use Encode qw(encode);
use Selecto::Components::ExportBudget ();
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(blessed looks_like_number);
use Time::HiRes qw(time);
use Selecto::Components::QueryBuilder ();
use Selecto::Components::State ();
use Selecto::Components::Util qw(decode_driver_json);
use Selecto::Statement ();

has 'config';

sub input_from_controller ($self, $controller) {
    my %input;
    for my $name (@{Selecto::Components::State->parameter_names}) {
        my @values = $controller->every_param($name);
        next unless @values;
        $input{$name} = @values == 1 ? $values[0] : \@values;
    }
    my @group_names = grep { /\Aquery_library_segment_choice_[A-Za-z][A-Za-z0-9_]*\z/ && length($_) <= 128 }
        @{$controller->req->params->names};
    for my $name (@group_names[0 .. ($#group_names < 31 ? $#group_names : 31)]) {
        next unless defined $name;
        my @values = $controller->every_param($name);
        next unless @values;
        $input{$name} = @values == 1 ? $values[0] : \@values;
    }
    return \%input;
}

sub model ($self, $controller, $input = undef, $options = undef) {
    my $model_started = time;
    $options //= {};
    die "explorer model options must be an object\n" unless ref($options) eq 'HASH';
    # Optional result cache keyed by the exact compiled SQL and bound values
    # (see result_cache_key). Hosts such as dashboards use it to reuse results
    # across requests. WebSocket sessions supply a bounded connection-local cache.
    die "Use a bounded stream export for all_rows requests\n" if $options->{all_rows};
    my $result_cache = $options->{result_cache};
    die "explorer result_cache must provide fetch and store\n"
        if defined($result_cache)
            && !(blessed($result_cache) && $result_cache->can('fetch') && $result_cache->can('store'));
    my %cache_info = (hits => 0, misses => 0);
    my $input_supplied = defined $input;
    my $config = $self->config->for_request($controller);
    my $engine;
    my $state;
    my $all_rows = 0;
    my $grid_all_rows = 0;
    my $model = {
        config => $config,
        input => undef,
        result => undef,
        runtime_error => undef,
    };
    my $ok = eval {
        my $setup_started = time;
        $engine = $config->engine($controller);
        $result_cache->bind_domain($engine->domain->fingerprint)
            if $result_cache && $result_cache->can('bind_domain');
        $all_rows = $options->{all_rows}
            && $config->query_params_enabled($engine->domain) ? 1 : 0;
        $input = $input_supplied || $config->query_params_enabled($engine->domain)
            ? ($input // $self->input_from_controller($controller))
            : {};
        $model->{input} = $input;
        $state = Selecto::Components::State->from_input(
            $config, $engine->domain, $input
        );
        $model->{engine} = $engine;
        $model->{domain} = $engine->domain;
        $model->{state} = $state;
        $model->{canonical_url} = $self->canonical_url($state, $engine->domain);
        my $setup_ms = _elapsed_ms($setup_started);
        return $model unless $state->valid;

        my $build_started = time;
        my $built = Selecto::Components::QueryBuilder->build(
            $config, $engine->domain, $state,
            {paginate => !$all_rows, rollup => _rollup_supported($engine)}
        );
        _cap_export($config, $built) if $all_rows;
        my $build_ms = _elapsed_ms($build_started);
        $grid_all_rows = $built->{aggregate_grid} ? 1 : 0;
        my $started = time;
        my $compile_started = time;
        my $statement = $engine->compile($built->{query});
        my $compile_ms = _elapsed_ms($compile_started);
        my $data_started = time;
        my $raw = _execute($engine, $statement, $result_cache, \%cache_info);
        my $data_query_ms = _elapsed_ms($data_started);
        _validate_result($raw);
        my $grid_limit_exceeded = $grid_all_rows
            && @{$raw->{rows}} > $config->max_grid_result_cells ? 1 : 0;
        my $total_count;
        my ($count_statement, $count_compile_ms, $count_query_ms, $count_cache_hit);
        if ($all_rows || $grid_all_rows) {
            $total_count = scalar @{$raw->{rows}};
        } else {
            my $count_query = defined($built->{count_selections})
                ? $built->{query}->count_query($built->{count_selections})
                : $built->{query}->count_query;
            my $count_compile_started = time;
            my $count_source = $engine->compile($count_query);
            $count_statement = _count_statement($count_source);
            $count_compile_ms = _elapsed_ms($count_compile_started);
            my $count_key = _count_cache_key($count_statement);
            $total_count = !$result_cache && _wants_cached_count($input)
                ? _cached_count($controller, $count_key) : undef;
            if (defined($total_count)) {
                $count_cache_hit = 1;
                $count_query_ms = 0;
            } else {
                my $count_started = time;
                my $hits_before_count = $cache_info{hits};
                my $count_raw = _execute($engine, $count_statement, $result_cache, \%cache_info);
                $count_query_ms = _elapsed_ms($count_started);
                _validate_result($count_raw);
                $total_count = _total_count($count_raw);
                _store_count($controller, $count_key, $total_count) unless $result_cache;
                $count_cache_hit = $cache_info{hits} > $hits_before_count ? 1 : 0;
            }
        }
        my $elapsed_ms = _elapsed_ms($started);
        my $total_pages = $all_rows || $grid_all_rows ? 1
            : int(($total_count + $state->limit - 1) / $state->limit);
        $total_pages = 1 if $total_pages < 1;
        my $transform_started = time;
        my @records = map {
            my %record;
            @record{@{$raw->{columns}}} = @$_;
            \%record;
        } @{$raw->{rows}};
        @records = () if $grid_limit_exceeded;
        my $returned_count = scalar(@records);
        _prepare_nested_records($built, \@records);
        _prepare_rollup_records($built, \@records);
        _prepend_continued_rollup_records($built, \@records)
            if !$all_rows && !$grid_all_rows && $state->page > 1;
        my $drilldown_grain = _drilldown_grain($config, $engine->domain, $state);
        my $drilldowns = _drilldowns($state, $built, \@records, $drilldown_grain);
        my $graph_axis_drilldowns = _graph_axis_drilldowns(
            $state, $built, \@records, $drilldown_grain,
        );
        my $grid_data = _aggregate_grid_data(
            $state, $built, \@records, $drilldowns,
            $config->max_grid_result_cells,
        );
        if (ref($grid_data) eq 'HASH' && $grid_data->{limit_exceeded}) {
            $grid_limit_exceeded = 1;
            $grid_data = undef;
        }
        my $transform_ms = _elapsed_ms($transform_started);
        $model->{result} = {
            %$built,
            columns => $built->{columns},
            records => \@records,
            drilldowns => $drilldowns,
            graph_axis_drilldowns => $graph_axis_drilldowns,
            (defined($grid_data) ? (grid_data => $grid_data) : ()),
            grid_limit_exceeded => $grid_limit_exceeded,
            count => $returned_count,
            total_count => $total_count,
            total_pages => $total_pages,
            has_more => !$all_rows && !$grid_all_rows && $state->page < $total_pages ? 1 : 0,
            all_rows => $all_rows,
            grid_all_rows => $grid_all_rows,
            elapsed_ms => $elapsed_ms,
            adapter_name => $engine->adapter->name,
            ($result_cache ? (cache => {
                hit => $cache_info{misses} ? 0 : 1,
                (defined($cache_info{created_at}) ? (created_at => $cache_info{created_at}) : ()),
            }) : ()),
            ($config->show_sql ? (
                sql => $statement->sql,
                params => $statement->params,
                debug => {
                    data_query => {
                        sql => $statement->sql,
                        params => $statement->params,
                    },
                    (defined($count_statement) ? (
                        count_query => {
                            sql => $count_statement->sql,
                            params => $count_statement->params,
                        },
                    ) : ()),
                    stats => {
                        adapter => $engine->adapter->name,
                        view => $state->view,
                        returned_rows => $returned_count,
                        matched_rows => $total_count,
                        page => $all_rows || $grid_all_rows ? 1 : $state->page,
                        total_pages => $total_pages,
                        page_size => $all_rows || $grid_all_rows
                            ? scalar(@records) : $state->limit,
                        compile_ms => $compile_ms + ($count_compile_ms // 0),
                        data_query_ms => $data_query_ms,
                        count_compile_ms => $count_compile_ms,
                        count_query_ms => $count_query_ms,
                        count_cache_hit => $count_cache_hit,
                        total_ms => $elapsed_ms,
                        setup_ms => $setup_ms,
                        build_ms => $build_ms,
                        transform_ms => $transform_ms,
                        model_ms => _elapsed_ms($model_started),
                    },
                },
            ) : ()),
        };
        1;
    };
    unless ($ok) {
        my $error = $@;
        $controller->app->log->error("Selecto explorer model failed: $error")
            if $controller->can('app');
        $model->{runtime_error} = _public_error($error);
        if (!$state && $engine) {
            $state = Selecto::Components::State->from_input(
                $config, $engine->domain, {}
            );
            $model->{state} = $state;
            $model->{domain} = $engine->domain;
            $model->{canonical_url} = $self->canonical_url($state, $engine->domain);
        }
    }
    return $model;
}

# The cache key for a compiled statement: adapter, SQL text and bound values,
# so any difference in the query (including visibility scoping) is a different entry.
sub result_cache_key ($class, $statement) {
    return sha256_hex(encode_json([
        'selecto-result-v2',
        $statement->adapter_name,
        $statement->sql,
        $statement->columns,
        @{$statement->params},
    ]));
}

# Run a statement, through the result cache when one is supplied. fetch($key)
# returns {result => {columns, rows}, created_at => epoch} or undef;
# store($key, {columns, rows}) saves a fresh result.
sub _execute ($engine, $statement, $cache, $info) {
    return $engine->adapter->execute_query($statement) unless $cache;
    my $key = __PACKAGE__->result_cache_key($statement);
    my $entry = $cache->fetch($key);
    if (ref($entry) eq 'HASH' && ref($entry->{result}) eq 'HASH'
        && eval { _validate_result($entry->{result}); 1 }) {
        $info->{hits}++;
        my $created = $entry->{created_at};
        $info->{created_at} = $created
            if defined($created) && (!defined($info->{created_at}) || $created < $info->{created_at});
        return $entry->{result};
    }
    my $raw = $engine->adapter->execute_query($statement);
    _validate_result($raw);
    $info->{misses}++;
    $info->{created_at} //= time;  # the oldest part of the result decides its age
    $cache->store($key, {columns => $raw->{columns}, rows => $raw->{rows}});
    return $raw;
}

sub prepare ($self, $controller, $input = undef) {
    my $config = $self->config->for_request($controller);
    my $engine = $config->engine($controller);
    $input //= $config->query_params_enabled($engine->domain)
        ? $self->input_from_controller($controller) : {};
    my $state = Selecto::Components::State->from_input($config, $engine->domain, $input);
    my $model = {
        config => $config,
        engine => $engine,
        domain => $engine->domain,
        input => $input,
        state => $state,
        result => undef,
        runtime_error => undef,
        canonical_url => $self->canonical_url($state, $engine->domain),
    };
    return $model unless $state->valid;
    my $built = Selecto::Components::QueryBuilder->build(
        $config, $engine->domain, $state, {paginate => 1},
    );
    $model->{prepared} = $built;
    $model->{statement} = $engine->compile($built->{query});
    return $model;
}

sub _elapsed_ms ($started) {
    return int((time - $started) * 1000 + 0.5);
}

sub _count_cache_key ($statement) {
    return sha256_hex(encode_json([
        $statement->adapter_name,
        $statement->sql,
        @{$statement->params},
    ]));
}

sub _wants_cached_count ($input) {
    return 0 unless ref($input) eq 'HASH';
    my $value = $input->{reuse_count};
    $value = $value->[0] if ref($value) eq 'ARRAY';
    return defined($value) && !ref($value) && "$value" eq '1' ? 1 : 0;
}

sub _cached_count ($controller, $key) {
    my $cache = $controller->stash('selecto_count_cache');
    return undef unless ref($cache) eq 'HASH';
    my $entry = $cache->{$key};
    return undef unless ref($entry) eq 'HASH';
    if (($entry->{expires_at} // 0) <= time) {
        delete $cache->{$key};
        return undef;
    }
    return $entry->{count};
}

sub _store_count ($controller, $key, $count) {
    my $cache = $controller->stash('selecto_count_cache');
    unless (ref($cache) eq 'HASH') {
        $cache = {};
        $controller->stash(selecto_count_cache => $cache);
    }
    my $now = time;
    delete @{$cache}{grep {
        ref($cache->{$_}) ne 'HASH' || ($cache->{$_}{expires_at} // 0) <= $now
    } keys %$cache};
    if (keys(%$cache) >= 32) {
        my ($oldest) = sort {
            ($cache->{$a}{created_at} // 0) <=> ($cache->{$b}{created_at} // 0)
        } keys %$cache;
        delete $cache->{$oldest} if defined $oldest;
    }
    $cache->{$key} = {
        count => $count,
        created_at => $now,
        expires_at => $now + 30,
    };
    return $count;
}

sub _prepare_nested_records ($built, $records) {
    my @columns = grep { $_->{nested} } @{$built->{columns} // []};
    return unless @columns;
    for my $record (@$records) {
        for my $column (@columns) {
            my $value = $record->{$column->{key}};
            if (defined($value) && !ref($value)) {
                my $decoded;
                my $ok = eval { $decoded = decode_driver_json($value); 1 };
                $value = $ok ? $decoded : undef;
            }
            if (ref($value) eq 'ARRAY'
                && !grep { ref($_) ne 'HASH' } @$value) {
                $record->{$column->{key}} = $value;
            } else {
                $record->{$column->{key}} = [];
            }
        }
    }
}

# Aggregate subtotals use GROUP BY ROLLUP. Adapters without it (SQLite,
# MySQL and SQL Server in selecto-perl) get plainly grouped aggregates.
sub _rollup_supported ($engine) {
    return $engine->adapter->supports('rollup') ? 1 : 0;
}

sub _prepare_rollup_records ($built, $records) {
    return unless $built->{rollup};
    my $group_count = $built->{group_count};
    my $rollup_key = $built->{rollup_key};
    my $maximum_mask = (1 << $group_count) - 1;
    for my $record (@$records) {
        my $mask = $record->{$rollup_key};
        die "aggregate rollup returned invalid grouping metadata\n"
            unless defined($mask) && !ref($mask) && "$mask" =~ /\A\d+\z/
                && $mask <= $maximum_mask && (($mask & ($mask + 1)) == 0);
        my $rolled_up = 0;
        my $remaining = 0 + $mask;
        while ($remaining) {
            $rolled_up += $remaining & 1;
            $remaining >>= 1;
        }
        $record->{__selecto_rollup_level} = $group_count - $rolled_up;
    }
}

sub _prepend_continued_rollup_records ($built, $records) {
    return 0 unless $built->{rollup} && ref($records) eq 'ARRAY' && @$records;
    my $first = $records->[0];
    my $level = $first->{__selecto_rollup_level};
    return 0 unless defined($level) && !ref($level) && "$level" =~ /\A\d+\z/
        && $level > 1;

    my @groups = grep { !$_->{measure} } @{$built->{columns} // []};
    my @measures = grep { $_->{measure} } @{$built->{columns} // []};
    my $group_count = scalar(@groups);
    return 0 if !$group_count || $level > $group_count;

    my @continued;
    for my $parent_level (1 .. $level - 1) {
        my %record = (
            __selecto_rollup_level => $parent_level,
            __selecto_rollup_continued => 1,
        );
        for my $group_index (0 .. $parent_level - 1) {
            my $group = $groups[$group_index];
            for my $key (grep { defined && length } $group->{key}, $group->{drilldown_key}) {
                $record{$key} = $first->{$key} if exists $first->{$key};
            }
        }
        $record{$_->{key}} = undef for @measures;
        if (defined(my $rollup_key = $built->{rollup_key})) {
            $record{$rollup_key} = (1 << ($group_count - $parent_level)) - 1;
        }
        push @continued, \%record;
    }
    unshift @$records, @continued;
    return scalar(@continued);
}

# A summary drilldown opens the rows its measures counted: when the summary
# reads a single to-many association, the detail view is retargeted to it.
sub _drilldown_grain ($config, $domain, $state) {
    return undef if $state->view eq 'detail';
    my $path = Selecto::Components::State->aggregate_grain($config, $domain, $state);
    return undef unless defined $path;
    return {path => $path} if ($state->retarget // '') eq $path;
    return {path => $path, fields => $config->resolved_default_fields($domain, $path)};
}

sub _drilldowns ($state, $built, $records, $grain = undef) {
    return [] if $state->view eq 'detail';
    my @groups = grep { !$_->{measure} } @{$built->{columns}};
    my @drilldowns;
    for my $record (@$records) {
        my $available_levels = $built->{rollup}
            ? $record->{__selecto_rollup_level} : scalar(@groups);
        my @row_drilldowns;
        for my $group_index (0 .. $available_levels - 1) {
            push @row_drilldowns, _drilldown_for_group_indexes(
                $state, \@groups, $record, [0 .. $group_index], $grain,
            );
        }
        push @drilldowns, \@row_drilldowns;
    }
    return \@drilldowns;
}

sub _drilldown_for_group_indexes ($state, $groups, $record, $indexes, $grain = undef) {
    # A grouping predicate narrows the existing query; it does not replace
    # filters already applied to that field.  This is especially important for
    # temporal groups: a clicked weekday must remain inside the selected date
    # range rather than matching that weekday across all history.
    my @filters = map { { %$_ } } @{$state->filters};
    for my $group_index (@$indexes) {
        my $group = $groups->[$group_index];
        next unless $group;
        my $value_key = $group->{drilldown_key} // $group->{key};
        my $value = $record->{$value_key};
        push @filters, {
            field => $group->{drilldown_field} // $group->{field},
            op => defined($value) ? 'eq' : 'is_null',
            value => defined($value) ? "$value" : '',
            value_end => '',
            grouped => exists($group->{drilldown_grouped})
                ? $group->{drilldown_grouped}
                : (length($group->{format} // '')
                    && ($group->{format} // '') ne 'default' ? 1 : 0),
            promoted => 1,
        };
    }
    my $drilldown = Selecto::Components::State->new(
        %{$state->as_hash},
        view => 'detail',
        filters => \@filters,
        page => 1,
        errors => [],
        ($grain ? (
            rows_of => $grain->{path},
            retarget => $grain->{path},
            retarget_auto => 0,
            # The root grain's columns and sort do not exist at the target.
            ($grain->{fields} ? (
                fields => [@{$grain->{fields}}],
                field_configs => {map { $_ => {alias => '', format => ''} } @{$grain->{fields}}},
                field_config_list => [map { {alias => '', format => ''} } @{$grain->{fields}}],
                orders => [],
            ) : ()),
        ) : ()),
    );
    return $drilldown->query_pairs;
}

sub _graph_axis_drilldowns ($state, $built, $records, $grain = undef) {
    return [] unless $state->view eq 'graph'
        && length($state->graph_series_group // '');
    my @groups = grep { !$_->{measure} } @{$built->{columns}};
    my @indexes = grep {
        ($groups[$_]{field} // '') ne $state->graph_series_group
    } 0 .. $#groups;
    return [] unless @indexes;
    return [map {
        _drilldown_for_group_indexes($state, \@groups, $_, \@indexes, $grain)
    } @$records];
}

sub _aggregate_grid_data ($state, $built, $records, $drilldowns, $maximum_cells = undef) {
    return undef unless $built->{aggregate_grid};
    my @groups = grep { !$_->{measure} } @{$built->{columns} // []};
    my @measures = grep { $_->{measure} } @{$built->{columns} // []};
    return undef unless @groups == 2 && @measures == 1;

    my (@rows, @columns);
    my (%seen_row, %seen_column, %cells);
    my $maximum_positive;
    for my $record_index (0 .. $#$records) {
        my $record = $records->[$record_index];
        next if $record->{__selecto_rollup_continued};
        next unless ($record->{__selecto_rollup_level} // -1) == 2;

        my $row_value = $record->{$groups[0]{key}};
        my $column_value = $record->{$groups[1]{key}};
        my $row_key = _grid_value_key($row_value);
        my $column_key = _grid_value_key($column_value);
        unless ($seen_row{$row_key}++) {
            push @rows, {
                key => $row_key,
                value => $row_value,
                (defined($groups[0]{sort_key})
                    ? (sort_value => $record->{$groups[0]{sort_key}}) : ()),
                selection_value => $record->{$groups[0]{drilldown_key} // $groups[0]{key}},
                drilldown => _drilldown_for_group_indexes(
                    $state, \@groups, $record, [0],
                ),
            };
        }
        unless ($seen_column{$column_key}++) {
            push @columns, {
                key => $column_key,
                value => $column_value,
                (defined($groups[1]{sort_key})
                    ? (sort_value => $record->{$groups[1]{sort_key}}) : ()),
                selection_value => $record->{$groups[1]{drilldown_key} // $groups[1]{key}},
                drilldown => _drilldown_for_group_indexes(
                    $state, \@groups, $record, [1],
                ),
            };
        }
        my $value = $record->{$measures[0]{key}};
        $cells{$row_key}{$column_key} = {
            value => $value,
            drilldown => $drilldowns->[$record_index][-1],
            selection_values => [map {
                my $value_key = $_->{drilldown_key} // $_->{key};
                $record->{$value_key}
            } @groups],
        };
        if (defined($value) && !ref($value) && looks_like_number($value) && $value > 0) {
            $maximum_positive = 0 + $value
                if !defined($maximum_positive) || $value > $maximum_positive;
        }
    }

    @rows = @{_sort_grid_entries(\@rows, $groups[0])};
    @columns = @{_sort_grid_entries(\@columns, $groups[1])};
    return {limit_exceeded => 1}
        if defined($maximum_cells) && @rows * @columns > $maximum_cells;
    return {
        row_axis => $groups[0],
        column_axis => $groups[1],
        measure => $measures[0],
        rows => \@rows,
        columns => \@columns,
        cells => \%cells,
        maximum_positive => $maximum_positive,
        selection_pairs => _grid_selection_pairs($state),
    };
}

sub _grid_selection_pairs ($state) {
    my $detail = Selecto::Components::State->new(
        %{$state->as_hash},
        view => 'detail',
        aggregate_grid => 0,
        aggregate_grid_colorize => 0,
        filters => [map { { %$_ } }
            grep { !defined($_->{clause}) } @{$state->filters}],
        page => 1,
        errors => [],
    );
    return $detail->query_pairs;
}

sub _grid_value_key ($value) {
    return encode_json([defined($value) ? 1 : 0, defined($value) ? "$value" : '']);
}

sub _sort_grid_entries ($entries, $column) {
    my $format = $column->{format} // '';
    my $type = $column->{source_type} // $column->{type} // '';
    my $has_sort_key = defined($column->{sort_key}) ? 1 : 0;
    my $numeric = $format =~ /\A(?:epoch_seconds|epoch_milliseconds|year|month_of_year|day_of_month|day_of_week_num|day_of_year|hour)\z/;
    my $lexical = $format =~ /\A(?:iso8601|rfc3339_millis|day|time|day_hour|week|iso_week|iso_week_date|month|quarter)\z/
        || ((!length($format) || $format eq 'default') && $type =~ /(?:date|time)/i);
    my $timezone = $format eq 'timezone_offset' ? 1 : 0;
    return [@$entries] unless $has_sort_key || $numeric || $lexical || $timezone;
    return [sort {
        !defined($a->{value}) <=> !defined($b->{value})
            || _compare_grid_entry_values(
                $a, $b, $has_sort_key, $numeric, $timezone,
            )
    } @$entries];
}

sub _compare_grid_entry_values ($left, $right, $has_sort_key, $numeric, $timezone) {
    my $left_value = $has_sort_key ? $left->{sort_value} : $left->{value};
    my $right_value = $has_sort_key ? $right->{sort_value} : $right->{value};
    my $defined_order = !defined($left_value) <=> !defined($right_value);
    return $defined_order if $defined_order;
    return 0 unless defined($left_value) && defined($right_value);
    if (($has_sort_key || $numeric)
        && looks_like_number($left_value) && looks_like_number($right_value)) {
        return $left_value <=> $right_value;
    }
    if ($timezone) {
        my $left_offset = _timezone_offset_minutes($left_value);
        my $right_offset = _timezone_offset_minutes($right_value);
        return $left_offset <=> $right_offset
            if defined($left_offset) && defined($right_offset);
    }
    return "$left_value" cmp "$right_value";
}

sub _timezone_offset_minutes ($value) {
    return undef unless defined($value) && !ref($value)
        && "$value" =~ /\A([+-])(\d{2}):(\d{2})\z/;
    my $minutes = ($2 * 60) + $3;
    return $1 eq '-' ? -$minutes : $minutes;
}

sub _count_statement ($source) {
    return Selecto::Statement->new(
        sql => 'SELECT COUNT(*) AS selecto_total_count FROM (' . $source->sql .
            ') AS selecto_count_source',
        params => $source->params,
        columns => ['selecto_total_count'],
        adapter_name => $source->adapter_name,
    );
}

sub _total_count ($raw) {
    die "count query returned an invalid result\n"
        unless @{$raw->{columns}} == 1 && @{$raw->{rows}} == 1
            && @{$raw->{rows}[0]} == 1;
    my $value = $raw->{rows}[0][0];
    die "count query returned an invalid total\n"
        unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/;
    return 0 + $value;
}

sub canonical_url ($self, $state, $domain = undef) {
    return $self->config->path
        if $domain && !$self->config->query_params_enabled($domain);
    my $url = Mojo::URL->new($self->config->path);
    $url->query($state->query_pairs);
    return $url->to_string;
}

# Applies the host's max_export_rows to an unpaginated export query.
sub _cap_export ($config, $built) {
    my $max = $config->max_export_rows or return;
    my $query = $built->{query};
    my $current = $query->limit_value;
    $built->{query} = $query->limit($max) if !defined($current) || $current > $max;
    return;
}

sub stream_export ($self, $controller, $format) {
    return undef unless $format eq 'csv' || $format eq 'tsv' || $format eq 'json';
    my $config = $self->config->for_request($controller);
    my $engine = $config->engine($controller);
    return undef unless $config->query_params_enabled($engine->domain);
    die "Adapter does not support bounded streaming exports\n" unless $engine->adapter->supports('stream')
        && $engine->adapter->can('stream_query');
    my $input = $self->input_from_controller($controller);
    my $state = Selecto::Components::State->from_input(
        $config, $engine->domain, $input,
    );
    die join('; ', @{$state->errors}) . "\n" unless $state->valid;
    my $built = Selecto::Components::QueryBuilder->build(
        $config, $engine->domain, $state,
        {paginate => 0, rollup => _rollup_supported($engine)},
    );
    # Grids need the bounded matrix transformation; their fallback export is
    # deliberately capped by max_grid_result_cells.
    die "Aggregate grid exports require a bounded job\n" if $built->{aggregate_grid};
    _cap_export($config, $built);
    my $budget = Selecto::Components::ExportBudget->new($config, $engine, $controller);
    my $stream = $engine->stream($built->{query}, fetch_size => 1, bounded => 1);
    $controller->on(finish => sub { eval { $stream->close }; eval { $budget->close } }) if $controller->can('on');
    my @result_columns = @{$stream->columns};
    my @columns = grep { !$_->{action_id} } @{$built->{columns}};
    my @headers = _unique_headers(map { $_->{label} } @columns);
    my $delimiter = $format eq 'csv' ? ',' : "\t";
    my $started = 0;
    my $finished = 0;
    my $closed = 0;
    my $first_json_row = 1;
    my $row_count = 0;
    my $next_record = sub {
        $budget->check;
        my $row = $stream->next;
        return undef unless $row;
        $budget->row($row);
        my %record;
        @record{@result_columns} = @$row;
        my @record = (\%record);
        _prepare_nested_records($built, \@record);
        _prepare_rollup_records($built, \@record);
        $row_count++;
        return \%record;
    };
    my $next_chunk = sub {
        return undef if $finished;
        my $chunk = '';
        unless ($started) {
            $started = 1;
            if ($format eq 'json') {
                $chunk = '{"scope":"all","row_limit":' . $config->max_export_rows . ',"page":1,"total_pages":1,"columns":' .
                    to_json(\@headers) . ',"rows":[';
            } else {
                $chunk = join($delimiter, map { _delimited_cell($_) } @headers) . "\r\n";
            }
        }
        my $batch_count = 0;
        while ($batch_count < 1) {
            my $record = $next_record->();
            unless ($record) {
                $finished = 1;
                $chunk .= $format eq 'json'
                    ? '],"row_count":' . $row_count . ',"total_count":' . $row_count . "}\n"
                    : '';
                last;
            }
            if ($format eq 'json') {
                my %row = map {
                    my $index = $_;
                    $headers[$index] => _json_value($record->{$columns[$index]{key}})
                } 0 .. $#columns;
                $chunk .= ',' unless $first_json_row;
                $chunk .= to_json(\%row);
                $first_json_row = 0;
            } else {
                $chunk .= join($delimiter, map {
                    _delimited_cell($record->{$_->{key}})
                } @columns) . "\r\n";
            }
            $batch_count++;
        }
        $budget->output($chunk);
        return length($chunk) ? $chunk : undef;
    };
    return {
        config => $config,
        next_chunk => $next_chunk,
        close => sub {
            return if $closed++;
            my $error;
            eval { $stream->close; 1 } or $error = $@;
            $budget->close;
            die $error if $error;
        },
    };
}

sub xlsx_file_export ($self, $controller) {
    my $config = $self->config->for_request($controller);
    my $engine = $config->engine($controller);
    return undef unless $config->query_params_enabled($engine->domain);
    die "Adapter does not support bounded streaming exports\n" unless $engine->adapter->supports('stream')
        && $engine->adapter->can('stream_query');
    my $input = $self->input_from_controller($controller);
    my $state = Selecto::Components::State->from_input(
        $config, $engine->domain, $input,
    );
    die join('; ', @{$state->errors}) . "\n" unless $state->valid;
    my $built = Selecto::Components::QueryBuilder->build(
        $config, $engine->domain, $state,
        {paginate => 0, rollup => _rollup_supported($engine)},
    );
    die "Aggregate grid exports require a bounded job\n" if $built->{aggregate_grid};
    _cap_export($config, $built);
    my $budget = Selecto::Components::ExportBudget->new($config, $engine, $controller);
    my $spool = File::Temp->newdir('selecto-xlsx-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my ($output_handle, $output_path) = tempfile(DIR => "$spool", SUFFIX => '.xlsx', UNLINK => 0);
    close $output_handle or die "could not prepare Excel export file\n";
    my ($stream, $workbook);
    my $spool_reserved = 262_144;
    my $reserve_cell = sub ($text) {
        $budget->check;
        $spool_reserved += 4 * (1024 + 6 * length(encode('UTF-8', $text)));
        die "Excel temporary disk limit exceeded\n" if $spool_reserved > $config->max_export_temp_bytes;
    };
    my $spool_check = sub {
        $budget->check;
        my $bytes = 0;
        File::Find::find(sub { $bytes += -s $_ if -f $_ }, "$spool");
        die "Excel temporary disk limit exceeded\n" if $bytes > $config->max_export_temp_bytes;
    };
    $controller->on(finish => sub { eval { $stream->close } if $stream; eval { $budget->close } }) if $controller->can('on');
    my $ok = eval {
        $stream = $engine->stream($built->{query}, fetch_size => 1, bounded => 1);
        my @result_columns = @{$stream->columns};
        my @columns = grep { !$_->{action_id} } @{$built->{columns}};
        require Excel::Writer::XLSX;
        $workbook = Excel::Writer::XLSX->new($output_path)
            or die "could not create Excel export\n";
        $workbook->set_tempdir("$spool");
        $workbook->set_optimization if $workbook->can('set_optimization');
        my $header_format = $workbook->add_format(
            bold => 1, bg_color => '#DCE6F1', bottom => 1,
        );
        my ($worksheet, $sheet_index, $row_index, @widths);
        my $start_sheet = sub {
            $sheet_index++;
            $worksheet = $workbook->add_worksheet(
                $sheet_index == 1 ? 'Export' : "Export $sheet_index",
            );
            @widths = ();
            for my $column_index (0 .. $#columns) {
                my $label = defined($columns[$column_index]{label})
                    ? "$columns[$column_index]{label}" : '';
                $reserve_cell->($label);
                $worksheet->write_string(0, $column_index, $label, $header_format);
                $widths[$column_index] = length($label);
            }
            $worksheet->freeze_panes(1, 0);
            $row_index = 1;
        };
        my $finish_sheet = sub {
            return unless $worksheet;
            $worksheet->autofilter(0, 0, $row_index - 1, $#columns) if @columns;
            for my $column_index (0 .. $#columns) {
                my $width = ($widths[$column_index] // 0) + 2;
                $width = 10 if $width < 10;
                $width = 60 if $width > 60;
                $worksheet->set_column($column_index, $column_index, $width);
            }
        };
        $start_sheet->();
        while (1) {
            $spool_check->();
            my $row = $stream->next or last;
            $budget->row($row);
            if ($row_index >= 1_048_576) {
                $finish_sheet->();
                $start_sheet->();
            }
            my %record;
            @record{@result_columns} = @$row;
            my @record = (\%record);
            _prepare_nested_records($built, \@record);
            _prepare_rollup_records($built, \@record);
            for my $column_index (0 .. $#columns) {
                my $value = $record{$columns[$column_index]{key}};
                if (!defined($value)) {
                    $reserve_cell->('');
                    $worksheet->write_blank($row_index, $column_index, undef);
                    next;
                }
                my $text = _flat_value($value);
                # XML escaping can expand bytes sixfold; reserve conservatively
                # before the writer retains or flushes the cell.
                $budget->output($text);
                $reserve_cell->($text);

                if (!ref($value) && looks_like_number($value) && $text !~ /\A[+-]?0\d/) {
                    $worksheet->write_number($row_index, $column_index, 0 + $value);
                } else {
                    $worksheet->write_string($row_index, $column_index, $text);
                }
                $widths[$column_index] = length($text)
                    if length($text) > ($widths[$column_index] // 0);
            }
            $row_index++;
        }
        $stream->close;
        undef $stream;
        $finish_sheet->();
        $workbook->close or die "could not finish Excel export\n";
        undef $workbook;
        $spool_check->();
        die "Excel output exceeds byte limit\n" if -s $output_path > $config->max_export_bytes;
        1;
    };
    unless ($ok) {
        my $error = $@ || 'could not create Excel export';
        eval { $stream->close } if $stream;
        eval { $workbook->close } if $workbook;
        unlink $output_path if -f $output_path;
        die $error;
    }
    # Keep both spool ownership and concurrency lease alive through delivery.
    return {config => $config, path => $output_path,
        close => sub { $budget->close; unlink $output_path if -f $output_path; undef $spool }};
}

sub export ($self, $model, $format) {
    return $self->csv($model) if $format eq 'csv';
    return $self->tsv($model) if $format eq 'tsv';
    return $self->json($model) if $format eq 'json';
    return $self->xlsx($model) if $format eq 'xlsx';
    die "unsupported export format\n";
}

sub csv ($self, $model) {
    return $self->_delimited($model, ',');
}

sub tsv ($self, $model) {
    return $self->_delimited($model, "\t");
}

sub json ($self, $model) {
    _assert_exportable($model);
    my ($columns, $records) = _export_dataset($model);
    my @columns = @$columns;
    my @headers = _unique_headers(map { $_->{label} } @columns);
    my @rows = map {
        my $record = $_;
        +{
            map {
                my $index = $_;
                $headers[$index] => _json_value($record->{$columns[$index]{key}})
            } 0 .. $#columns
        }
    } @$records;
    return to_json({
        scope => $model->{result}{all_rows} ? 'all' : 'page',
        page => $model->{result}{all_rows} ? 1 : $model->{state}->page,
        total_pages => $model->{result}{total_pages},
        total_count => $model->{result}{total_count},
        row_count => scalar(@rows),
        columns => \@headers,
        rows => \@rows,
    }) . "\n";
}

sub xlsx ($self, $model) {
    _assert_exportable($model);
    require Excel::Writer::XLSX;
    my ($columns, $records) = _export_dataset($model);
    my @columns = @$columns;
    my ($output_handle) = tempfile(SUFFIX => '.xlsx', UNLINK => 1);
    binmode $output_handle;
    my $workbook = Excel::Writer::XLSX->new($output_handle)
        or die "could not create Excel export\n";
    my $worksheet = $workbook->add_worksheet('Export');
    my $header_format = $workbook->add_format(
        bold => 1,
        bg_color => '#DCE6F1',
        bottom => 1,
    );
    my @widths;
    for my $column_index (0 .. $#columns) {
        my $label = defined($columns[$column_index]{label})
            ? "$columns[$column_index]{label}" : '';
        $worksheet->write_string(0, $column_index, $label, $header_format);
        $widths[$column_index] = length($label);
    }
    my $row_index = 1;
    for my $record (@$records) {
        for my $column_index (0 .. $#columns) {
            my $value = $record->{$columns[$column_index]{key}};
            if (!defined($value)) {
                $worksheet->write_blank($row_index, $column_index, undef);
                next;
            }
            my $text = _flat_value($value);
            if (!ref($value) && looks_like_number($value) && $text !~ /\A[+-]?0\d/) {
                $worksheet->write_number($row_index, $column_index, 0 + $value);
            } else {
                $worksheet->write_string($row_index, $column_index, $text);
            }
            $widths[$column_index] = length($text)
                if length($text) > ($widths[$column_index] // 0);
        }
        $row_index++;
    }
    if (@columns) {
        $worksheet->freeze_panes(1, $model->{result}{grid_data} ? 1 : 0);
        $worksheet->autofilter(0, 0, $row_index - 1, $#columns);
        for my $column_index (0 .. $#columns) {
            my $width = ($widths[$column_index] // 0) + 2;
            $width = 10 if $width < 10;
            $width = 60 if $width > 60;
            $worksheet->set_column($column_index, $column_index, $width);
        }
    }
    $workbook->close or die "could not finish Excel export\n";
    seek $output_handle, 0, 0 or die "could not rewind Excel export buffer\n";
    local $/;
    my $output = <$output_handle>;
    close $output_handle or die "could not close Excel export buffer\n";
    return $output;
}

sub _delimited ($self, $model, $delimiter) {
    _assert_exportable($model);
    die "cannot export an invalid query\n"
        unless $delimiter eq ',' || $delimiter eq "\t";
    my @lines;
    my ($columns, $records) = _export_dataset($model);
    my @columns = @$columns;
    push @lines, join($delimiter, map { _delimited_cell($_->{label}) } @columns);
    for my $record (@$records) {
        push @lines, join($delimiter, map {
            _delimited_cell($record->{$_->{key}})
        } @columns);
    }
    return join("\r\n", @lines) . "\r\n";
}

sub _assert_exportable ($model) {
    die "cannot export an invalid query\n"
        unless $model->{state} && $model->{state}->valid && $model->{result};
}

sub _export_columns ($model) {
    return grep { !$_->{action_id} } @{$model->{result}{columns}};
}

sub _export_dataset ($model) {
    my $grid = $model->{result}{grid_data};
    return ([ _export_columns($model) ], $model->{result}{records}) unless $grid;

    my @columns = ({
        key => '__selecto_grid_row',
        label => $grid->{row_axis}{label},
    });
    for my $column_index (0 .. $#{$grid->{columns}}) {
        push @columns, {
            key => '__selecto_grid_column_' . $column_index,
            label => _grid_export_label($grid->{columns}[$column_index]{value}),
        };
    }
    my @records;
    for my $row (@{$grid->{rows}}) {
        my %record = (__selecto_grid_row => _grid_export_label($row->{value}));
        for my $column_index (0 .. $#{$grid->{columns}}) {
            my $column = $grid->{columns}[$column_index];
            my $row_cells = $grid->{cells}{$row->{key}};
            my $cell = ref($row_cells) eq 'HASH' ? $row_cells->{$column->{key}} : undef;
            $record{'__selecto_grid_column_' . $column_index} = $cell
                ? $cell->{value} : undef;
        }
        push @records, \%record;
    }
    return (\@columns, \@records);
}

sub _grid_export_label ($value) {
    return defined($value) && !ref($value) ? "$value" : '[NULL]';
}

sub _unique_headers (@labels) {
    my %counts;
    return map {
        my $label = defined($_) ? "$_" : '';
        my $count = ++$counts{$label};
        $count == 1 ? $label : "$label ($count)"
    } @labels;
}

sub _json_value ($value) {
    return undef unless defined($value);
    return [map { _json_value($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _json_value($value->{$_}) } keys %$value}
        if ref($value) eq 'HASH';
    return "$value" if ref($value);
    return $value;
}

sub _flat_value ($value) {
    return '' unless defined($value);
    return to_json(_json_value($value)) if ref($value);
    return "$value";
}

sub _validate_result ($result) {
    die "adapter returned an invalid result\n" unless ref($result) eq 'HASH';
    die "adapter result columns must be an array\n" unless ref($result->{columns}) eq 'ARRAY';
    die "adapter result rows must be an array\n" unless ref($result->{rows}) eq 'ARRAY';
    for my $row (@{$result->{rows}}) {
        die "adapter result row must be an array\n" unless ref($row) eq 'ARRAY';
        die "adapter result row width does not match columns\n"
            unless @$row == @{$result->{columns}};
    }
}

sub _public_error ($error) {
    return $error->message if blessed($error) && $error->isa('Selecto::Error');
    return 'The query could not be completed.';
}

sub _delimited_cell ($value) {
    $value = _flat_value($value);
    $value = "'$value" if $value =~ /\A[=+\-@\t\r\n]/;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;

__END__

=head1 NAME

Selecto::Components::Explorer - Build, run and export one explorer's governed query

=head1 SYNOPSIS

    # Inside a Mojolicious action, with the plugin registered:
    my $explorer = $c->selecto_components_explorer('products');

    my $model = $explorer->model($c, {
        q => 1, view => 'detail',
        field => ['product_name', 'unit_price'],
        filter_field => 'unit_price', filter_op => 'gte', filter_value => 10,
    });

    if ($model->{state}->valid && !$model->{runtime_error}) {
        my $rows  = $model->{result}{records};
        my $total = $model->{result}{total_count};
        my $csv   = $explorer->export($model, 'csv');
    }

=head1 DESCRIPTION

An Explorer ties one L<Selecto::Components::Config> to query execution. It
parses the input into a L<Selecto::Components::State>, which validates it
against the domain. It then builds the L<Selecto::Query>, compiles it with the
request's engine, runs the data and count statements, and shapes the rows for
rendering or export.

The plugin creates one Explorer per configured explorer and uses it for every
route. Hosts use it directly mainly for dashboards
(L<Selecto::Components::Dashboard>) and for their own exports or reports that
must match the explorer's semantics exactly.

=head1 ATTRIBUTES

=head2 config

The L<Selecto::Components::Config> this explorer runs. Required by C<new>:

    my $explorer = Selecto::Components::Explorer->new(config => $config);

=head1 METHODS

=head2 model

    my $model = $explorer->model($controller);
    my $model = $explorer->model($controller, \%input);
    my $model = $explorer->model($controller, \%input, {result_cache => $cache});

Runs one request. Without C<\%input>, the state is read from the controller's
query parameters. In private URL mode those are ignored and the domain
defaults apply. C<\%input> uses the same parameter names as the canonical URL
(see L<Selecto::Components/URL STATE>). Scalars are single values and array
references are repeated values.

Options:

=over 4

=item result_cache

An object with C<fetch($key)> and C<store($key, $result)>, and optionally
C<bind_domain($fingerprint)>. Results are keyed by L</result_cache_key>, so
any difference in SQL or bound values, including scope, is a different
entry. L<Selecto::Components::ExplorerSession> is one implementation.

=item all_rows

Rejected. Use C<stream_export> or C<xlsx_file_export> with a bounded adapter.

=back

The returned hash contains C<config> (the request copy), C<input>, C<engine>,
C<domain>, C<state>, C<canonical_url>, C<runtime_error> (a user-safe message
or C<undef>) and C<result>. When the state is valid and the query succeeded,
C<result> holds C<records>, C<columns>, C<count>, C<total_count>,
C<total_pages>, C<has_more> and C<elapsed_ms>. It also holds C<sql>,
C<params> and C<debug> when C<show_sql> is on. Database errors are logged and
reported as a generic C<runtime_error>. C<model> does not die for query
failures.

=head2 input_from_controller

    my $input = $explorer->input_from_controller($c);

Collects the known state parameters from the request.

=head2 canonical_url

    my $url = $explorer->canonical_url($model->{state}, $model->{domain});

The explorer path plus the normalized query string. In private URL mode this
is the bare path.

=head2 export

    my $data = $explorer->export($model, $format);   # csv | tsv | json | xlsx

Serializes a successful model's rows. The C<csv>, C<tsv>, C<json> and C<xlsx>
methods do the same for one format. Text formats return a character string
for the caller to encode; C<xlsx> returns bytes. Hidden helper columns and
action columns are left out. Delimited formats neutralize spreadsheet formulas.

=head2 stream_export, xlsx_file_export

    my $stream = $explorer->stream_export($c, 'csv');   # or undef
    my $file   = $explorer->xlsx_file_export($c);       # or undef

These are the plugin's all-rows exports for the current request.
C<stream_export> returns C<< {config, next_chunk, close} >> when the adapter
supports streaming. C<xlsx_file_export> returns C<< {config, path} >> for a
temporary Excel file. Both return C<undef> when they do not apply, for example
in private URL mode or for an aggregate grid.

=head2 result_cache_key

    my $key = Selecto::Components::Explorer->result_cache_key($statement);

A SHA-256 over the adapter name, SQL, columns and bound values of a
L<Selecto::Statement>.

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::Components::Dashboard>,
L<Selecto::Components::ExplorerSession>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
