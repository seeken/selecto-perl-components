package Selecto::Components::Explorer;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL ();
use File::Temp qw(tempfile);
use Scalar::Util qw(blessed looks_like_number);
use Time::HiRes qw(time);
use Selecto::Components::QueryBuilder ();
use Selecto::Components::State ();
use Selecto::Statement ();

has 'config';

sub input_from_controller ($self, $controller) {
    my %input;
    for my $name (@{Selecto::Components::State->parameter_names}) {
        my @values = $controller->every_param($name);
        next unless @values;
        $input{$name} = @values == 1 ? $values[0] : \@values;
    }
    return \%input;
}

sub model ($self, $controller, $input = undef, $options = undef) {
    $options //= {};
    die "explorer model options must be an object\n" unless ref($options) eq 'HASH';
    my $input_supplied = defined $input;
    my $config = $self->config->for_request($controller);
    my $engine;
    my $state;
    my $all_rows = 0;
    my $model = {
        config => $config,
        input => undef,
        result => undef,
        runtime_error => undef,
    };
    my $ok = eval {
        $engine = $config->engine($controller);
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
        return 1 unless $state->valid;

        my $built = Selecto::Components::QueryBuilder->build(
            $config, $engine->domain, $state, {paginate => !$all_rows}
        );
        my $started = time;
        my $compile_started = time;
        my $statement = $engine->compile($built->{query});
        my $compile_ms = _elapsed_ms($compile_started);
        my $data_started = time;
        my $raw = $engine->adapter->execute_query($statement);
        my $data_query_ms = _elapsed_ms($data_started);
        _validate_result($raw);
        my $total_count;
        my ($count_statement, $count_compile_ms, $count_query_ms);
        if ($all_rows) {
            $total_count = scalar @{$raw->{rows}};
        } else {
            my $count_query = defined($built->{count_selections})
                ? $built->{query}->count_query($built->{count_selections})
                : $built->{query}->count_query;
            my $count_compile_started = time;
            my $count_source = $engine->compile($count_query);
            $count_statement = _count_statement($count_source);
            $count_compile_ms = _elapsed_ms($count_compile_started);
            my $count_started = time;
            my $count_raw = $engine->adapter->execute_query($count_statement);
            $count_query_ms = _elapsed_ms($count_started);
            _validate_result($count_raw);
            $total_count = _total_count($count_raw);
        }
        my $elapsed_ms = _elapsed_ms($started);
        my $total_pages = $all_rows ? 1
            : int(($total_count + $state->limit - 1) / $state->limit);
        $total_pages = 1 if $total_pages < 1;
        my @records = map {
            my %record;
            @record{@{$raw->{columns}}} = @$_;
            \%record;
        } @{$raw->{rows}};
        my $returned_count = scalar(@records);
        _prepare_nested_records($built, \@records);
        _prepare_rollup_records($built, \@records);
        _prepend_continued_rollup_records($built, \@records)
            if !$all_rows && $state->page > 1;
        my $drilldowns = _drilldowns($state, $built, \@records);
        $model->{result} = {
            %$built,
            columns => $built->{columns},
            records => \@records,
            drilldowns => $drilldowns,
            rows => [map { [@$_] } @{$raw->{rows}}],
            result_columns => [@{$raw->{columns}}],
            count => $returned_count,
            total_count => $total_count,
            total_pages => $total_pages,
            has_more => !$all_rows && $state->page < $total_pages ? 1 : 0,
            all_rows => $all_rows,
            elapsed_ms => $elapsed_ms,
            adapter_name => $engine->adapter->name,
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
                        page => $all_rows ? 1 : $state->page,
                        total_pages => $total_pages,
                        page_size => $all_rows ? scalar(@records) : $state->limit,
                        compile_ms => $compile_ms + ($count_compile_ms // 0),
                        data_query_ms => $data_query_ms,
                        count_compile_ms => $count_compile_ms,
                        count_query_ms => $count_query_ms,
                        total_ms => $elapsed_ms,
                    },
                },
            ) : ()),
        };
        1;
    };
    unless ($ok) {
        my $error = $@;
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

sub _elapsed_ms ($started) {
    return int((time - $started) * 1000 + 0.5);
}

sub _prepare_nested_records ($built, $records) {
    my @columns = grep { $_->{nested} } @{$built->{columns} // []};
    return unless @columns;
    for my $record (@$records) {
        for my $column (@columns) {
            my $value = $record->{$column->{key}};
            if (defined($value) && !ref($value)) {
                my $decoded;
                my $ok = eval { $decoded = decode_json($value); 1 };
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

sub _drilldowns ($state, $built, $records) {
    return [] if $state->view eq 'detail';
    my @groups = grep { !$_->{measure} } @{$built->{columns}};
    my %group_field = map {
        ($_->{field} => 1, (defined($_->{drilldown_field}) ? ($_->{drilldown_field} => 1) : ()))
    } @groups;
    my @drilldowns;
    for my $record (@$records) {
        my $available_levels = $built->{rollup}
            ? $record->{__selecto_rollup_level} : scalar(@groups);
        my @base_filters = map { { %$_ } }
            grep { !$group_field{$_->{field}} } @{$state->filters};
        my @group_filters;
        my @row_drilldowns;
        for my $group_index (0 .. $available_levels - 1) {
            my $group = $groups[$group_index];
            my $value_key = $group->{drilldown_key} // $group->{key};
            my $value = $record->{$value_key};
            push @group_filters, {
                field => $group->{drilldown_field} // $group->{field},
                op => defined($value) ? 'eq' : 'is_null',
                value => defined($value) ? "$value" : '',
                value_end => '',
                grouped => exists($group->{drilldown_grouped})
                    ? $group->{drilldown_grouped} : 1,
            };
            my $drilldown = Selecto::Components::State->new(
                %{$state->as_hash},
                view => 'detail',
                filters => [map { { %$_ } } (@base_filters, @group_filters)],
                page => 1,
                errors => [],
            );
            push @row_drilldowns, $drilldown->query_pairs;
        }
        push @drilldowns, \@row_drilldowns;
    }
    return \@drilldowns;
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
    my @columns = _export_columns($model);
    my @headers = _unique_headers(map { $_->{label} } @columns);
    my @rows = map {
        my $record = $_;
        +{
            map {
                my $index = $_;
                $headers[$index] => _json_value($record->{$columns[$index]{key}})
            } 0 .. $#columns
        }
    } @{$model->{result}{records}};
    return encode_json({
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
    my @columns = _export_columns($model);
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
    for my $record (@{$model->{result}{records}}) {
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
        $worksheet->freeze_panes(1, 0);
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
    my @columns = _export_columns($model);
    push @lines, join($delimiter, map { _delimited_cell($_->{label}) } @columns);
    for my $record (@{$model->{result}{records}}) {
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
    return encode_json(_json_value($value)) if ref($value);
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
    $value = "'$value" if $value =~ /\A[=+\-@]/;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
