package Selecto::Components::State;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(decode_json);
use Digest::SHA qw(sha256_hex);
use Selecto::Components::BucketParser ();
use Selecto::Components::DateShortcut ();
use Selecto::Components::RowActions ();
use Selecto::Components::Util qw(trim);
use Selecto::Error ();
use Selecto::QueryLibrary ();

has [qw(view chart_type aggregate_grid aggregate_grid_colorize aggregate_grid_color_scale row_click_action fields field_configs field_config_list filters groups group_configs measures measure_configs measure orders order direction limit page errors query_library_view query_library_materialized_view query_library_segments query_library_parameters)];

sub parameter_names ($class) {
    return [qw(
        q query_signature view chart_type aggregate_grid aggregate_grid_colorize aggregate_grid_color_scale row_click_action field field_alias field_format filter_field filter_op filter_value filter_value_end filter_group filter_clause filter_promote_field filter_promote_index grid_cell grid_axis
        group group_alias group_format group_bucket_ranges group_prefix_length group_exclude_articles
        measure measure_alias measure_function measure_bucket_ranges measure_ignore_nulls
        query_library_view query_library_materialized_view query_library_segment query_library_param_name query_library_param_value
        order direction limit page
    )];
}

sub from_input ($class, $config, $domain, $input) {
    $input = {} unless ref($input) eq 'HASH';
    $config->validate_domain($domain);
    my $field_map = $config->field_map($domain);
    my $detail_map = $config->detail_column_map($domain);
    my @errors;
    my $configured = _first($input, 'q') ? 1 : 0;
    my $query_library = _query_library_state($domain, $input, \@errors);
    my $view = _parse_view($config, $input, $query_library, \@errors);
    my $chart_type = _parse_chart_type($input, \@errors);
    my ($aggregate_grid, $aggregate_grid_colorize, $aggregate_grid_color_scale) =
        _parse_aggregate_grid($view, $input);
    my $row_click_action = _parse_row_click_action(
        $config, $domain, $input, $configured,
    );
    my ($valid_fields, $field_configs, $field_config_list) = _parse_fields(
        $config, $domain, $input, $detail_map, $field_map, $query_library, $configured, \@errors,
    );
    my ($valid_groups, $group_configs) = _parse_groups(
        $config, $domain, $input, $field_map, $view, $configured, \@errors,
    );
    my ($valid_measures, $measure_configs, $measure) = _parse_measures(
        $config, $domain, $input, $field_map, \@errors,
    );
    my ($orders, $order, $direction) = _parse_orders(
        $config, $domain, $input, $field_map, $valid_fields, $query_library, \@errors,
    );
    my ($limit, $page) = _parse_pagination($config, $input, \@errors);
    my $filters = _parse_filters(
        $config, $input, $field_map, $valid_groups, $group_configs, \@errors,
    );

    my $state = $class->new(
        view => $view,
        chart_type => $chart_type,
        aggregate_grid => $aggregate_grid,
        aggregate_grid_colorize => $aggregate_grid_colorize,
        aggregate_grid_color_scale => $aggregate_grid_color_scale,
        row_click_action => $row_click_action,
        fields => $valid_fields,
        field_configs => $field_configs,
        field_config_list => $field_config_list,
        filters => $filters,
        groups => $valid_groups,
        group_configs => $group_configs,
        measures => $valid_measures,
        measure_configs => $measure_configs,
        measure => $measure,
        orders => $orders,
        order => $order,
        direction => $direction,
        limit => $limit,
        page => $page,
        errors => \@errors,
        query_library_view => $query_library->{view},
        query_library_materialized_view => $query_library->{view},
        query_library_segments => $query_library->{segments},
        query_library_parameters => $query_library->{parameters},
    );
    my $query_signature = _first($input, 'query_signature');
    $state->page(1) if defined($query_signature) && !ref($query_signature)
        && "$query_signature" =~ /\A[0-9a-f]{64}\z/
        && "$query_signature" ne $state->query_signature;
    return $state;
}

sub valid ($self) { return @{$self->errors} ? 0 : 1; }

sub query_pairs ($self) {
    my @pairs = (q => 1, view => $self->view);
    push @pairs, query_library_view => $self->query_library_view
        if defined($self->query_library_view) && length($self->query_library_view);
    push @pairs, query_library_materialized_view => $self->query_library_materialized_view
        if defined($self->query_library_materialized_view)
        && length($self->query_library_materialized_view);
    push @pairs, query_library_segment => $_ for @{$self->query_library_segments // []};
    for my $name (sort keys %{$self->query_library_parameters // {}}) {
        push @pairs,
            query_library_param_name => $name,
            query_library_param_value => $self->query_library_parameters->{$name};
    }
    push @pairs, chart_type => $self->chart_type if $self->view eq 'graph';
    if ($self->view eq 'aggregate' && $self->aggregate_grid) {
        push @pairs, aggregate_grid => 1;
        push @pairs, aggregate_grid_colorize => 1 if $self->aggregate_grid_colorize;
        push @pairs, aggregate_grid_color_scale => $self->aggregate_grid_color_scale;
    }
    push @pairs, row_click_action => $self->row_click_action
        if defined($self->row_click_action) && length($self->row_click_action);
    for my $index (0 .. $#{$self->fields}) {
        my $field = $self->fields->[$index];
        my $column = $self->field_config_list->[$index]
            // $self->field_configs->{$field} // {};
        push @pairs,
            field => $field,
            field_alias => $column->{alias} // '',
            field_format => $column->{format} // '';
    }
    my %filter_field_count;
    $filter_field_count{$_->{field}}++ for @{$self->filters};
    for my $filter_index (0 .. $#{$self->filters}) {
        my $filter = $self->filters->[$filter_index];
        push @pairs,
            filter_field => $filter->{field},
            filter_op => $filter->{op},
            filter_value => $filter->{value},
            filter_value_end => $filter->{value_end} // '',
            filter_group => $filter->{grouped} ? 1 : 0,
            filter_clause => $filter->{clause} // '';
        if ($filter->{promoted}) {
            push @pairs, $filter_field_count{$filter->{field}} == 1
                ? (filter_promote_field => $filter->{field})
                : (filter_promote_index => $filter_index + 1);
        }
    }
    for my $group (@{$self->groups}) {
        my $column = $self->group_configs->{$group} // {};
        push @pairs,
            group => $group,
            group_alias => $column->{alias} // '',
            group_format => $column->{format} // '',
            group_bucket_ranges => $column->{bucket_ranges} // '',
            group_prefix_length => $column->{prefix_length} // 2,
            group_exclude_articles => $column->{exclude_articles} ? 1 : 0;
    }
    for my $measure (@{$self->measures}) {
        my $measure_config = $self->measure_configs->{$measure} // {};
        push @pairs,
            measure => $measure,
            measure_alias => $measure_config->{alias} // '',
            measure_function => $measure_config->{function} // 'count',
            measure_bucket_ranges => $measure_config->{bucket_ranges} // '',
            measure_ignore_nulls => $measure_config->{ignore_nulls} ? 1 : 0;
    }
    for my $order (@{$self->orders}) {
        push @pairs, order => $order->{field}, direction => $order->{direction};
    }
    push @pairs,
        limit => $self->limit,
        page => $self->page;
    return \@pairs;
}

sub query_signature ($self) {
    my $pairs = $self->query_pairs;
    my @parts;
    for (my $index = 0; $index < @$pairs; $index += 2) {
        next if $pairs->[$index] eq 'page';
        my $key = defined($pairs->[$index]) ? "$pairs->[$index]" : '';
        my $value = defined($pairs->[$index + 1]) ? "$pairs->[$index + 1]" : '';
        push @parts, length($key) . ":$key", length($value) . ":$value";
    }
    return sha256_hex(join('|', @parts));
}

sub as_hash ($self) {
    return {
        view => $self->view,
        chart_type => $self->chart_type,
        aggregate_grid => $self->aggregate_grid,
        aggregate_grid_colorize => $self->aggregate_grid_colorize,
        aggregate_grid_color_scale => $self->aggregate_grid_color_scale,
        row_click_action => $self->row_click_action,
        fields => [@{$self->fields}],
        field_configs => { map { $_ => { %{$self->field_configs->{$_}} } } keys %{$self->field_configs} },
        field_config_list => [map { {%$_} } @{$self->field_config_list // []}],
        filters => [map { { %$_ } } @{$self->filters}],
        groups => [@{$self->groups}],
        group_configs => { map { $_ => { %{$self->group_configs->{$_}} } } keys %{$self->group_configs} },
        measures => [@{$self->measures}],
        measure_configs => { map { $_ => { %{$self->measure_configs->{$_}} } } keys %{$self->measure_configs} },
        measure => $self->measure,
        orders => [map { { %$_ } } @{$self->orders}],
        order => $self->order,
        direction => $self->direction,
        limit => $self->limit,
        page => $self->page,
        query_library_view => $self->query_library_view,
        query_library_materialized_view => $self->query_library_materialized_view,
        query_library_segments => [@{$self->query_library_segments // []}],
        query_library_parameters => {%{$self->query_library_parameters // {}}},
    };
}

sub with_page ($self, $page) {
    return ref($self)->new(%{$self->as_hash}, page => $page, errors => [@{$self->errors}]);
}

sub _parse_view ($config, $input, $query_library, $errors) {
    my $view = _first($input, 'view') // $config->default_view;
    $view = 'detail' if @{$query_library->{projection_fields}}
        || @{$query_library->{orders}};
    if (!$config->allows_view($view)) {
        push @$errors, 'Choose an available view.';
        $view = $config->default_view;
    }
    return $view;
}

sub _parse_chart_type ($input, $errors) {
    my $chart_type = lc(_scalar(_first($input, 'chart_type')) || 'bar');
    my %chart_types = map { $_ => 1 } qw(
        bar horizontal_bar stacked_bar line area pie doughnut scatter
    );
    unless ($chart_types{$chart_type}) {
        push @$errors, 'Choose an available chart type.';
        $chart_type = 'bar';
    }
    return $chart_type;
}

sub _parse_aggregate_grid ($view, $input) {
    return (0, 0, 'linear') unless $view eq 'aggregate';
    my $enabled = _truthy(_first($input, 'aggregate_grid'), 0);
    my $colorize = _truthy(_first($input, 'aggregate_grid_colorize'), 0);
    my $scale = lc(_scalar(_first($input, 'aggregate_grid_color_scale')) || 'linear');
    $scale = 'linear' unless $scale eq 'linear' || $scale eq 'log';
    return ($enabled, $colorize, $scale);
}

sub _parse_row_click_action ($config, $domain, $input, $configured) {
    my $requested = $configured
        ? _scalar(_first($input, 'row_click_action'))
        : _scalar($config->default_row_click_action);
    return '' unless length($requested);
    return Selecto::Components::RowActions->find($domain, $requested) ? $requested : '';
}

sub _parse_fields ($config, $domain, $input, $detail_map, $field_map, $query_library, $configured, $errors) {
    my $field_values = _values($input, 'field');
    my $field_aliases = _values($input, 'field_alias');
    my $field_formats = _values($input, 'field_format');
    if ($query_library->{materialize} && @{$query_library->{projection_fields}}) {
        $field_values = [@{$query_library->{projection_fields}}];
        $field_aliases = [];
        $field_formats = [];
    }
    $field_values = [@{$config->resolved_default_fields($domain)}]
        if !$configured && !grep { length(_scalar($_)) } @$field_values;
    my @valid_fields;
    my %field_configs;
    my @field_config_list;
    my %seen_action;
    for my $index (0 .. $#$field_values) {
        my $field = _scalar($field_values->[$index]);
        next unless length($field);
        unless ($detail_map->{$field}) {
            push @$errors, 'A selected detail column is not available.';
            next;
        }
        if ($detail_map->{$field}{action_id}) {
            next if $seen_action{$field}++;
            push @valid_fields, $field;
            $field_configs{$field} = {alias => '', format => ''};
            push @field_config_list, $field_configs{$field};
            next;
        }
        my $alias = _trim($field_aliases->[$index]);
        if (length($alias) > 80 || $alias =~ /[\x00-\x1f\x7f]/) {
            push @$errors, 'A selected column alias is not available.';
            $alias = '';
        }
        my $format = _scalar($field_formats->[$index]);
        if (!$config->allows_date_format($format)
            || (length($format) && !$config->temporal_type($field_map->{$field}{type}))) {
            push @$errors, 'A selected column format is not available.';
            $format = '';
        }
        push @valid_fields, $field;
        my $field_config = { alias => $alias, format => $format };
        $field_configs{$field} //= $field_config;
        push @field_config_list, $field_config;
    }
    push @$errors, 'Choose at least one detail column.' unless @valid_fields;
    unless (@valid_fields) {
        @valid_fields = @{$config->resolved_default_fields($domain)};
        %field_configs = map { $_ => { alias => '', format => '' } } @valid_fields;
        @field_config_list = map { $field_configs{$_} } @valid_fields;
    }
    return (\@valid_fields, \%field_configs, \@field_config_list);
}

sub _parse_groups ($config, $domain, $input, $field_map, $view, $configured, $errors) {
    my $group_values = _values($input, 'group');
    my $group_aliases = _values($input, 'group_alias');
    my $group_formats = _values($input, 'group_format');
    my $group_bucket_ranges = _values($input, 'group_bucket_ranges');
    my $group_prefix_lengths = _values($input, 'group_prefix_length');
    my $group_exclude_articles = _values($input, 'group_exclude_articles');
    $group_values = [@{$config->resolved_default_group($domain)}]
        if !$configured && !grep { length(_scalar($_)) } @$group_values;
    my @valid_groups;
    my %group_configs;
    my %seen_group;
    my %seen_group_identity;
    for my $index (0 .. $#$group_values) {
        my $group = _scalar($group_values->[$index]);
        next unless length($group) && !$seen_group{$group}++;
        if (!$field_map->{$group}) {
            push @$errors, 'A selected group field is not available.';
        } elsif (@valid_groups >= 3) {
            push @$errors, 'Choose no more than three group fields.';
        } else {
            my $dimension = $field_map->{$group}{dimension};
            my $group_identity = $dimension ? $dimension->{key_field} : $group;
            if ($seen_group_identity{$group_identity}++) {
                push @$errors, 'Choose a star dimension only once.';
                next;
            }
            my $alias = _trim($group_aliases->[$index]);
            if (length($alias) > 80 || $alias =~ /[\x00-\x1f\x7f]/) {
                push @$errors, 'A group column alias is not available.';
                $alias = '';
            }
            my $format = _scalar($group_formats->[$index]);
            my $field_type = $field_map->{$group}{type};
            if ($field_map->{$group}{dimension} && length($format)) {
                push @$errors, 'A star dimension cannot use a group format.';
                $format = '';
            } elsif (!$config->allows_group_format($field_type, $format)) {
                push @$errors, 'A group column format is not available.';
                $format = '';
            }
            my $bucket_ranges = _trim($group_bucket_ranges->[$index]);
            my $bucket_kind = $format eq 'buckets' ? 'numeric_ranges'
                : $format eq 'age_buckets' ? 'elapsed_days_ranges'
                : $format eq 'custom_buckets' ? 'date_relative_ranges'
                : $format eq 'year_buckets' ? 'year_ranges' : '';
            if (length($bucket_kind)
                && !Selecto::Components::BucketParser->valid($bucket_ranges, $bucket_kind)) {
                push @$errors, 'A group bucket range is not available.';
                $format = '';
                $bucket_ranges = '';
            }
            my $prefix_length = _scalar($group_prefix_lengths->[$index]);
            $prefix_length = 2 unless $prefix_length =~ /\A(?:[1-9]|10)\z/;
            my $exclude_articles = _truthy($group_exclude_articles->[$index], 1);
            push @valid_groups, $group;
            $group_configs{$group} = {
                alias => $alias,
                format => $format,
                bucket_ranges => $bucket_ranges,
                prefix_length => 0 + $prefix_length,
                exclude_articles => $exclude_articles,
            };
        }
    }
    if (($view eq 'aggregate' || $view eq 'graph') && !@valid_groups) {
        push @$errors, 'Choose at least one group field.';
        @valid_groups = @{$config->resolved_default_group($domain)};
        %group_configs = map { $_ => {
            alias => '', format => '', bucket_ranges => '', prefix_length => 2,
            exclude_articles => 1,
        } } @valid_groups;
    }
    return (\@valid_groups, \%group_configs);
}

sub _parse_measures ($config, $domain, $input, $field_map, $errors) {
    my $measure_values = _values($input, 'measure');
    my $measure_aliases = _values($input, 'measure_alias');
    my $measure_functions = _values($input, 'measure_function');
    my $measure_bucket_ranges = _values($input, 'measure_bucket_ranges');
    my $measure_ignore_nulls = _values($input, 'measure_ignore_nulls');
    my $default_measure = $config->default_measure($domain);
    $measure_values = [$default_measure->{id}]
        unless grep { length(_scalar($_)) } @$measure_values;
    my @valid_measures;
    my %measure_configs;
    my %seen_measure;
    for my $index (0 .. $#$measure_values) {
        my $measure_id = _scalar($measure_values->[$index]);
        next unless length($measure_id);
        if (@valid_measures >= $config->max_measures) {
            push @$errors, 'Too many measures were submitted.';
            last;
        }
        my $measure = $config->measure($measure_id, $domain);
        unless ($measure) {
            push @$errors, 'Choose an available measure.';
            next;
        }
        if ($seen_measure{$measure_id}++) {
            push @$errors, 'A measure can be set only once.';
            next;
        }
        my $alias = _trim($measure_aliases->[$index]);
        if (length($alias) > 80 || $alias =~ /[\x00-\x1f\x7f]/) {
            push @$errors, 'A measure alias is not available.';
            $alias = '';
        }
        my $field = $measure->{field};
        my $type = defined($field) ? $field_map->{$field}{type} : 'rows';
        my $function = lc(_scalar($measure_functions->[$index]) || $measure->{aggregate});
        unless ($config->allows_measure_function($type, $function, !defined($field))) {
            push @$errors, 'A measure function is not available.';
            $function = $measure->{aggregate};
        }
        my $bucket_ranges = _trim($measure_bucket_ranges->[$index]);
        my $bucket_kind = $function eq 'buckets' ? 'numeric_ranges'
            : $function eq 'age_buckets' ? 'elapsed_days_ranges' : '';
        if (length($bucket_kind)
            && !Selecto::Components::BucketParser->valid($bucket_ranges, $bucket_kind)) {
            push @$errors, 'A measure bucket range is not available.';
            $function = $measure->{aggregate};
            $bucket_ranges = '';
        }
        push @valid_measures, $measure_id;
        $measure_configs{$measure_id} = {
            alias => $alias,
            function => $function,
            bucket_ranges => $bucket_ranges,
            ignore_nulls => $function eq 'sum'
                ? _truthy($measure_ignore_nulls->[$index], 0) : 0,
        };
    }
    unless (@valid_measures) {
        my $fallback = $default_measure;
        @valid_measures = ($fallback->{id});
        $measure_configs{$fallback->{id}} = {
            alias => '', function => $fallback->{aggregate}, bucket_ranges => '', ignore_nulls => 0,
        };
    }
    my $measure = $valid_measures[0];
    return (\@valid_measures, \%measure_configs, $measure);
}

sub _parse_orders ($config, $domain, $input, $field_map, $valid_fields, $query_library, $errors) {
    my $order_fields = _values($input, 'order');
    my $order_directions = _values($input, 'direction');
    if ($query_library->{materialize} && @{$query_library->{orders}}) {
        $order_fields = [map { $_->[0] } @{$query_library->{orders}}];
        $order_directions = [map { $_->[1] } @{$query_library->{orders}}];
    }
    my ($default_order) = grep {
        $field_map->{$_} && !$field_map->{$_}{denormalizing}
    } @$valid_fields;
    $default_order //= $config->primary_key($domain);
    $order_fields = [$default_order] unless grep { length(_scalar($_)) } @$order_fields;
    my @orders;
    my %seen_order;
    for my $index (0 .. $#$order_fields) {
        my $field = _scalar($order_fields->[$index]);
        next unless length($field);
        if (@orders >= $config->max_orders) {
            push @$errors, 'Too many sort fields were submitted.';
            last;
        }
        unless ($field_map->{$field}) {
            push @$errors, 'Choose an available sort field.';
            next;
        }
        if ($field_map->{$field}{denormalizing}) {
            push @$errors, 'A to-many field cannot order root detail rows.';
            next;
        }
        if ($seen_order{$field}++) {
            push @$errors, 'A sort field can be set only once.';
            next;
        }
        my $dir = lc(_scalar($order_directions->[$index]) || 'asc');
        unless ($dir eq 'asc' || $dir eq 'desc') {
            push @$errors, 'Sort direction must be ascending or descending.';
            $dir = 'asc';
        }
        push @orders, { field => $field, direction => $dir };
    }
    @orders = ({ field => $default_order, direction => 'asc' }) unless @orders;
    my $order = $orders[0]{field};
    my $direction = $orders[0]{direction};
    return (\@orders, $order, $direction);
}

sub _parse_pagination ($config, $input, $errors) {
    my $limit_input = _first($input, 'limit');
    push @$errors, 'Row limit must be a positive integer.'
        if defined($limit_input) && $limit_input !~ /\A[1-9]\d*\z/;
    my $limit = _positive_integer($limit_input, $config->default_limit);
    if ($limit > $config->max_limit) {
        push @$errors, 'Row limit is above the configured maximum.';
        $limit = $config->max_limit;
    }
    my $page_input = _first($input, 'page');
    push @$errors, 'Page must be a positive integer.'
        if defined($page_input) && $page_input !~ /\A[1-9]\d*\z/;
    my $page = _positive_integer($page_input, 1);
    if ($page > 100_000) {
        push @$errors, 'Page is outside the supported range.';
        $page = 1;
    }
    return ($limit, $page);
}

sub _parse_filters ($config, $input, $field_map, $valid_groups, $group_configs, $errors) {
    my $filter_fields = _values($input, 'filter_field');
    my $filter_ops = _values($input, 'filter_op');
    my $filter_values = _values($input, 'filter_value');
    my $filter_end_values = _values($input, 'filter_value_end');
    my $filter_groups = _values($input, 'filter_group');
    my $filter_clauses = _values($input, 'filter_clause');
    my $grid_cells = _values($input, 'grid_cell');
    my $grid_axes = _values($input, 'grid_axis');
    if ((@$grid_cells || @$grid_axes) && grep { length(_scalar($_)) } @$filter_clauses) {
        push @$errors, 'A grid selection cannot be combined with existing alternative filters.';
        $grid_cells = [];
        $grid_axes = [];
    }
    for my $filter (@{_grid_cell_filter_inputs(
        $config, $grid_cells, $grid_axes, $field_map, $valid_groups, $group_configs, $errors,
    )}) {
        push @$filter_fields, $filter->{field};
        push @$filter_ops, $filter->{op};
        push @$filter_values, $filter->{value};
        push @$filter_end_values, '';
        push @$filter_groups, $filter->{grouped};
        push @$filter_clauses, $filter->{clause};
    }
    my %promoted_filter_field = map { $_ => 1 } grep { length } map { _scalar($_) }
        @{_values($input, 'filter_promote_field')};
    my %promoted_filter_index = map { $_ => 1 }
        grep { /\A[1-9]\d*\z/ } map { _scalar($_) }
        @{_values($input, 'filter_promote_index')};
    my $filter_count = @$filter_fields;
    $filter_count = @$filter_ops if @$filter_ops > $filter_count;
    $filter_count = @$filter_values if @$filter_values > $filter_count;
    $filter_count = @$filter_end_values if @$filter_end_values > $filter_count;
    $filter_count = @$filter_groups if @$filter_groups > $filter_count;
    $filter_count = @$filter_clauses if @$filter_clauses > $filter_count;
    my @filters;
    my %seen_filter_field;
    my %seen_clause;
    my %valid_group_field = map { $_ => 1 } @$valid_groups;
    my $regular_filter_count = 0;
    my $clause_condition_count = 0;
    for my $index (0 .. $filter_count - 1) {
        my $field = _scalar($filter_fields->[$index]);
        my $op = lc(_scalar($filter_ops->[$index]) || 'eq');
        my $value = _scalar($filter_values->[$index]);
        my $value_end = _scalar($filter_end_values->[$index]);
        my $group_filter = _truthy($filter_groups->[$index], 0);
        my $clause = _scalar($filter_clauses->[$index]);
        next unless length($field) || length($value) || length($value_end);
        if (length($clause) && ($clause !~ /\A[1-9]\d*\z/
            || $clause > $config->max_grid_cells)) {
            push @$errors, 'An alternative filter clause is outside the supported range.';
            next;
        }
        if (length($clause)) {
            $seen_clause{$clause} = 1;
            $clause_condition_count++;
            if (keys(%seen_clause) > $config->max_grid_cells
                || $clause_condition_count > $config->max_grid_cells * 2) {
                push @$errors, 'Too many alternative filter clauses were submitted.';
                last;
            }
        } elsif (!$group_filter && $regular_filter_count >= $config->max_filters) {
            push @$errors, 'Too many filters were submitted.';
            last;
        }
        unless ($field_map->{$field}) {
            push @$errors, 'A filter field is not available.';
            next;
        }
        my $filter_identity = "clause:$clause\0$field";
        if (length($clause) && $seen_filter_field{$filter_identity}++) {
            push @$errors, 'A filter field can be set only once.';
            next;
        }
        my $field_type = $field_map->{$field}{type};
        unless ($config->allows_filter_operator($field_type, $op)) {
            push @$errors, 'A filter operator is not available.';
            next;
        }
        if ($group_filter && (!$valid_group_field{$field} || ($op ne 'eq' && $op ne 'is_null'))) {
            push @$errors, 'An aggregate drilldown filter is not available.';
            next;
        }
        $regular_filter_count++ unless $group_filter || length($clause);
        ($value, $value_end) = ('', '') if $op =~ /_null\z/;
        if ($op eq 'in' && length($value)
            && !grep { length } map { _trim($_) } split /,/, $value, -1) {
            push @$errors, 'Membership filters require at least one value.';
            next;
        }
        if ($op eq 'date_shortcut' && length($value)
            && !Selecto::Components::DateShortcut->valid($value)) {
            push @$errors, 'A date shortcut is not available.';
            next;
        }
        if (!$group_filter && $config->temporal_type($field_type)
            && $op ne 'date_shortcut' && $op !~ /_null\z/) {
            if (length($value) && !_valid_temporal_value($value)) {
                push @$errors, 'A date filter value is not available.';
                next;
            }
            if ($op eq 'between' && length($value_end) && !_valid_temporal_value($value_end)) {
                push @$errors, 'A date filter end value is not available.';
                next;
            }
        }
        if (!$group_filter && $config->boolean_type($field_type) && $op eq 'eq'
            && length($value) && $value !~ /\A(?:true|false|0|1)\z/i) {
            push @$errors, 'A boolean filter value is not available.';
            next;
        }
        my $filter = {
            field => $field,
            op => $op,
            value => $value,
            value_end => $value_end,
        };
        $filter->{grouped} = 1 if $group_filter;
        $filter->{clause} = 0 + $clause if length($clause);
        $filter->{promoted} = 1 if !length($clause)
            && ($promoted_filter_index{$index + 1} || $promoted_filter_field{$field});
        $filter->{draft} = 1 if $op !~ /_null\z/
            && (!length($value) || ($op eq 'between' && !length($value_end)));
        push @filters, $filter;
    }
    my %draft_clause = map { $_->{clause} => 1 }
        grep { $_->{draft} && defined($_->{clause}) } @filters;
    for my $filter (@filters) {
        $filter->{draft} = 1
            if defined($filter->{clause}) && $draft_clause{$filter->{clause}};
    }
    if (keys %seen_clause) {
        if (@$valid_groups != 2) {
            push @$errors, 'Alternative filter clauses require the two grid group fields.';
        } else {
            my @expected = @{_grid_group_filters($field_map, $valid_groups, $group_configs)};
            my %expected = map { $_->{field} => $_->{grouped} ? 1 : 0 } @expected;
            for my $clause (keys %seen_clause) {
                my @conditions = grep {
                    defined($_->{clause}) && $_->{clause} == $clause
                } @filters;
                my %found = map { $_->{field} => $_->{grouped} ? 1 : 0 } @conditions;
                if (!@conditions || @conditions > 2 || keys(%found) != @conditions
                    || grep { !exists($expected{$_}) || $found{$_} != $expected{$_} }
                        keys %found) {
                    push @$errors, 'Each alternative filter clause must contain a grid row, column, or paired cell condition.';
                    last;
                }
            }
        }
    }
    return \@filters;
}

sub _grid_cell_filter_inputs ($config, $grid_cells, $grid_axes, $field_map, $valid_groups, $group_configs, $errors) {
    return [] unless @$grid_cells || @$grid_axes;
    if (@$valid_groups != 2) {
        push @$errors, 'Grid cell filters require exactly two selected groups.';
        return [];
    }
    if (@$grid_cells + @$grid_axes > $config->max_grid_cells * 2) {
        push @$errors, 'Too many grid selections were submitted.';
        return [];
    }
    my @group_filters = @{_grid_group_filters($field_map, $valid_groups, $group_configs)};
    my @filters;
    my $clause = 0;
    my %selected_axis;
    for my $encoded (@$grid_axes) {
        my $axis = eval { decode_json($encoded) };
        if ($@ || ref($axis) ne 'HASH' || !exists($axis->{axis}) || !exists($axis->{value})
            || $axis->{axis} !~ /\A[01]\z/ || ref($axis->{value})
            || (defined($axis->{value}) && length("$axis->{value}") > 1_000)) {
            push @$errors, 'A selected grid axis is invalid.';
            next;
        }
        my $key = $axis->{axis} . "\0" . (defined($axis->{value}) ? "v$axis->{value}" : 'n');
        next if $selected_axis{$key}++;
        push @filters, {
            %{$group_filters[$axis->{axis}]},
            op => defined($axis->{value}) ? 'eq' : 'is_null',
            value => defined($axis->{value}) ? "$axis->{value}" : '',
            clause => ++$clause,
        };
    }
    for my $encoded (@$grid_cells) {
        my $values = eval { decode_json($encoded) };
        if ($@ || ref($values) ne 'ARRAY' || @$values != 2
            || grep { defined($_) && ref($_) } @$values
            || grep { defined($_) && length("$_") > 1_000 } @$values) {
            push @$errors, 'A selected grid cell is invalid.';
            next;
        }
        next if grep {
            my $value = $values->[$_];
            my $key = $_ . "\0" . (defined($value) ? "v$value" : 'n');
            $selected_axis{$key}
        } (0, 1);
        ++$clause;
        for my $group_index (0, 1) {
            my $value = $values->[$group_index];
            push @filters, {
                %{$group_filters[$group_index]},
                op => defined($value) ? 'eq' : 'is_null',
                value => defined($value) ? "$value" : '',
                clause => $clause,
            };
        }
    }
    if ($clause > $config->max_grid_cells) {
        push @$errors, 'Too many grid filter alternatives were selected.';
        return [];
    }
    return \@filters;
}

sub _grid_group_filters ($field_map, $valid_groups, $group_configs) {
    return [map {
        my $group = $_;
        my $dimension = $field_map->{$group}{dimension};
        my $format = $group_configs->{$group}{format} // '';
        {
            field => $dimension ? $dimension->{key_field} : $group,
            grouped => !$dimension && length($format) && $format ne 'default' ? 1 : 0,
        }
    } @$valid_groups];
}

sub _values ($input, $key) {
    return [] unless exists $input->{$key} && defined $input->{$key};
    return [map { defined($_) && !ref($_) ? "$_" : '' } @{$input->{$key}}]
        if ref($input->{$key}) eq 'ARRAY';
    return [] if ref($input->{$key});
    return ["$input->{$key}"];
}

sub _first ($input, $key) {
    my $values = _values($input, $key);
    return @$values ? $values->[0] : undef;
}

sub _scalar ($value) { return defined($value) && !ref($value) ? "$value" : ''; }

sub _positive_integer ($value, $default) {
    return $default unless defined($value) && !ref($value) && "$value" =~ /\A[1-9]\d*\z/;
    return int($value);
}

sub _unique (@values) {
    my %seen;
    return grep { !$seen{$_}++ } @values;
}

sub _trim ($value) { return trim($value); }

sub _truthy ($value, $default = 0) {
    return $default unless defined($value) && !ref($value) && length("$value");
    return "$value" =~ /\A(?:1|true|on|yes)\z/i ? 1 : 0;
}

sub _valid_temporal_value ($value) {
    return 0 unless defined($value) && !ref($value)
        && "$value" =~ /\A(\d{4}-\d{2}-\d{2})(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)?\z/;
    return Selecto::Components::DateShortcut->valid_date($1);
}

sub _query_library_state ($domain, $input, $errors) {
    my $library = Selecto::QueryLibrary->library($domain);
    my $view = _trim(_first($input, 'query_library_view'));
    my $materialized_view = _trim(_first($input, 'query_library_materialized_view'));
    my @segments = grep { length } map { _trim($_) }
        @{_values($input, 'query_library_segment')};
    my %seen_segment;
    @segments = grep { !$seen_segment{$_}++ } @segments;

    if (length($view) && !_library_definition_exists($library->{views}, $view)) {
        push @$errors, 'Choose an available query-library view.';
        $view = '';
    }
    for my $segment (@segments) {
        push @$errors, 'Choose an available query-library segment.'
            unless _library_definition_exists($library->{segments}, $segment);
    }
    @segments = grep { _library_definition_exists($library->{segments}, $_) } @segments;

    my $parameter_names = _values($input, 'query_library_param_name');
    my $parameter_values = _values($input, 'query_library_param_value');
    my %parameters;
    for my $index (0 .. $#$parameter_names) {
        my $name = _trim($parameter_names->[$index]);
        next unless length($name);
        if (exists($parameters{$name})) {
            push @$errors, 'A query-library parameter can be submitted only once.';
            next;
        }
        $parameters{$name} = _scalar($parameter_values->[$index]);
    }

    my $selection = {
        (length($view) ? (view => $view) : ()),
        segments => \@segments,
    };
    my ($normalized, $specs) = ({}, {});
    my $ok = eval {
        $specs = Selecto::QueryLibrary->parameter_specs($domain, %$selection);
        my @unknown = grep { !exists($specs->{$_}) } keys %parameters;
        Selecto::Error->throw(
            'invalid_query_library', 'unknown query-library parameters', {names => \@unknown}
        ) if @unknown;
        $normalized = Selecto::QueryLibrary->normalize_parameters_for_selection(
            $domain, $selection, \%parameters,
        );
        1;
    };
    push @$errors, 'Complete the query-library parameters with valid values.' unless $ok;

    my (@projection_fields, @orders);
    if (length($view)) {
        my $view_spec = Selecto::QueryLibrary->definition($domain, 'views', $view);
        if (defined($view_spec->{projection}) && !ref($view_spec->{projection})
            && length("$view_spec->{projection}")) {
            @projection_fields = @{Selecto::QueryLibrary->projection_fields(
                $domain, $view_spec->{projection},
            )};
        }
        if (defined($view_spec->{ordering}) && !ref($view_spec->{ordering})
            && length("$view_spec->{ordering}")) {
            @orders = @{Selecto::QueryLibrary->ordering_entries(
                $domain, $view_spec->{ordering},
            )};
        }
    }

    return {
        view => length($view) ? $view : undef,
        materialize => length($view) && $view ne $materialized_view ? 1 : 0,
        segments => \@segments,
        parameters => $ok ? $normalized : \%parameters,
        projection_fields => \@projection_fields,
        orders => \@orders,
    };
}

sub _library_definition_exists ($registry, $id) {
    return scalar grep { "$_" eq "$id" && ref($registry->{$_}) eq 'HASH' } keys %$registry;
}

1;
