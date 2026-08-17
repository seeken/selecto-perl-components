package Selecto::Components::Explorer;

use Mojo::Base -base, -signatures;
use Mojo::URL ();
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use Selecto::Components::QueryBuilder ();
use Selecto::Components::State ();
use Selecto::Query ();
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

sub model ($self, $controller, $input = undef) {
    my $input_supplied = defined $input;
    my $engine;
    my $state;
    my $model = {
        config => $self->config,
        input => undef,
        result => undef,
        runtime_error => undef,
    };
    my $ok = eval {
        $engine = $self->config->engine($controller);
        $input = $input_supplied || $self->config->query_params_enabled($engine->domain)
            ? ($input // $self->input_from_controller($controller))
            : {};
        $model->{input} = $input;
        $state = Selecto::Components::State->from_input(
            $self->config, $engine->domain, $input
        );
        $model->{engine} = $engine;
        $model->{domain} = $engine->domain;
        $model->{state} = $state;
        $model->{canonical_url} = $self->canonical_url($state, $engine->domain);
        return 1 unless $state->valid;

        my $built = Selecto::Components::QueryBuilder->build(
            $self->config, $engine->domain, $state
        );
        my $started = time;
        my $statement = $engine->compile($built->{query});
        my $raw = $engine->adapter->execute_query($statement);
        my $elapsed_ms = int((time - $started) * 1000 + 0.5);
        _validate_result($raw);
        my $count_query = Selecto::Query->new(
            selections => $built->{query}->selections,
            predicate => $built->{query}->predicate,
            groups => $built->{query}->groups,
            grouping_mode => $built->{query}->grouping_mode,
        );
        my $count_source = $engine->compile($count_query);
        my $count_raw = $engine->adapter->execute_query(_count_statement($count_source));
        _validate_result($count_raw);
        my $total_count = _total_count($count_raw);
        my $total_pages = int(($total_count + $state->limit - 1) / $state->limit);
        $total_pages = 1 if $total_pages < 1;
        my @records = map {
            my %record;
            @record{@{$raw->{columns}}} = @$_;
            \%record;
        } @{$raw->{rows}};
        _prepare_rollup_records($built, \@records);
        my $drilldowns = _drilldowns($state, $built, \@records);
        $model->{result} = {
            %$built,
            columns => $built->{columns},
            records => \@records,
            drilldowns => $drilldowns,
            rows => [map { [@$_] } @{$raw->{rows}}],
            result_columns => [@{$raw->{columns}}],
            count => scalar(@records),
            total_count => $total_count,
            total_pages => $total_pages,
            has_more => $state->page < $total_pages ? 1 : 0,
            elapsed_ms => $elapsed_ms,
            adapter_name => $engine->adapter->name,
            ($self->config->show_sql ? (
                sql => $statement->sql,
                params => $statement->params,
            ) : ()),
        };
        1;
    };
    unless ($ok) {
        my $error = $@;
        $model->{runtime_error} = _public_error($error);
        if (!$state && $engine) {
            $state = Selecto::Components::State->from_input(
                $self->config, $engine->domain, {}
            );
            $model->{state} = $state;
            $model->{domain} = $engine->domain;
            $model->{canonical_url} = $self->canonical_url($state, $engine->domain);
        }
    }
    return $model;
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

sub _drilldowns ($state, $built, $records) {
    return [] if $state->view eq 'detail';
    my @groups = grep { !$_->{measure} } @{$built->{columns}};
    my %group_field = map { $_->{field} => 1 } @groups;
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
            my $value = $record->{$group->{key}};
            push @group_filters, {
                field => $group->{field},
                op => defined($value) ? 'eq' : 'is_null',
                value => defined($value) ? "$value" : '',
                value_end => '',
                grouped => 1,
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

sub csv ($self, $model) {
    die "cannot export an invalid query\n"
        unless $model->{state} && $model->{state}->valid && $model->{result};
    my @lines;
    push @lines, join(',', map { _csv_cell($_->{label}) } @{$model->{result}{columns}});
    for my $record (@{$model->{result}{records}}) {
        push @lines, join(',', map { _csv_cell($record->{$_->{key}}) } @{$model->{result}{columns}});
    }
    return join("\r\n", @lines) . "\r\n";
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

sub _csv_cell ($value) {
    $value = '' unless defined $value;
    $value = "$value";
    $value = "'$value" if $value =~ /\A[=+\-@]/;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
