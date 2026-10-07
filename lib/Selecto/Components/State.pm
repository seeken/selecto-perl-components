package Selecto::Components::State;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(from_json to_json);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Selecto::Components::BucketParser ();
use Selecto::Components::DateShortcut ();
use Selecto::Components::Graph::AxisPlanner ();
use Selecto::Components::RowActions ();
use Selecto::Components::Util qw(trim);
use Selecto::Analytics::UnitRegistry ();
use Selecto::Analytics::TransformRegistry ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Query ();
use Selecto::QueryLibrary ();
use Selecto::Components::InputBudget ();

has [qw(rows_of retarget retarget_auto view chart_type graph_show_table graph_series_group graph_palette graph_category_colors aggregate_grid aggregate_grid_colorize aggregate_grid_color_scale row_click_action fields field_configs field_config_list filters groups group_configs measures measure_configs measure_config_list measure orders order direction limit page errors query_library_view query_library_materialized_view query_library_segments query_library_parameters)];

sub parameter_names ($class) {
    return [qw(
        q query_signature rows_of rows_of_from view chart_type graph_show_table graph_series_group graph_palette graph_category_field graph_category_value graph_category_format graph_category_color aggregate_grid aggregate_grid_colorize aggregate_grid_color_scale row_click_action field field_alias field_format filter_field filter_op filter_value filter_values_json filter_value_end filter_group filter_clause filter_promote_field filter_promote_index grid_cell grid_axis
        group group_alias group_format group_bucket_ranges group_prefix_length group_exclude_articles
        measure measure_alias measure_function measure_bucket_ranges measure_ignore_nulls measure_series_id measure_chart_type measure_axis measure_stack measure_color measure_fill_opacity measure_transform measure_transform_window
        query_library_view query_library_materialized_view query_library_segment query_library_param_name query_library_param_value
        order direction limit page
    )];
}

sub from_input ($class, $config, $domain, $input) {
    $input = {} unless ref($input) eq 'HASH';
    my $budget_ok = eval { Selecto::Components::InputBudget->input($config->limits, $input); 1 };
    $input = {} unless $budget_ok;
    $config->validate_domain($domain);
    my $field_map = $config->field_map($domain);
    my $detail_map = $config->detail_column_map($domain);
    my @errors = $budget_ok ? () : ('Query state exceeds the configured input budget.');
    my $configured = _first($input, 'q') ? 1 : 0;
    my $query_library = _query_library_state($domain, $input, \@errors, $config->limits);
    my $view = _parse_view($config, $input, $query_library, \@errors);
    my $rows_of = _parse_rows_of($config, $domain, $input, \@errors);
    my $retarget = $rows_of eq '' || $rows_of eq '-' ? undef : $rows_of;
    # A changed "Rows of" choice keeps only the selections its grain offers.
    # rows_of_from names the explicit grain the submitted selections describe.
    if (defined(_first($input, 'rows_of_from'))
        && _scalar(_first($input, 'rows_of_from')) ne ($retarget // '')) {
        $input = _retain_available($config, $domain, $input, $retarget, $view);
    }
    if (defined $retarget) {
        $field_map = $config->field_map($domain, $retarget);
        $detail_map = $config->detail_column_map($domain, undef, $retarget);
        # Saved projections and orderings describe root rows.
        $query_library = {%$query_library, materialize => 0};
    }
    my $chart_type = _parse_chart_type($input, \@errors);
    my $graph_show_table = _truthy(_first($input, 'graph_show_table'), 0);
    my ($graph_palette, $graph_category_colors) = _parse_graph_colors(
        $config, $view, $input, \@errors,
    );
    my ($aggregate_grid, $aggregate_grid_colorize, $aggregate_grid_color_scale) =
        _parse_aggregate_grid($view, $input);
    my $row_click_action = defined($retarget) ? '' : _parse_row_click_action(
        $config, $domain, $input, $configured,
    );
    my ($valid_fields, $field_configs, $field_config_list) = _parse_fields(
        $config, $domain, $input, $detail_map, $field_map, $query_library, $configured, \@errors,
        $retarget,
    );
    my $retarget_auto = 0;
    if (!defined($retarget) && $rows_of eq '' && $view eq 'detail'
        && defined(my $auto = __PACKAGE__->auto_retarget($config, $domain, $valid_fields))) {
        $retarget = $auto;
        $retarget_auto = 1;
        $row_click_action = '';
        $input = _retain_available($config, $domain, $input, $retarget, $view, ['order']);
    }
    # An explicit grain summarizes its own fields. Its detail view also
    # carries the root grain's groups and measures, which grouped drilldown
    # filters and a return to the root summary still need.
    my $grain = $retarget_auto ? undef : $retarget;
    my $carry = defined($grain) && $view eq 'detail' ? 1 : 0;
    $input = _retain_available($config, $domain, $input, $grain, $view, ['group', 'measure'])
        if defined($grain) && !$carry;
    my $group_map = $carry
        ? {%{$config->field_map($domain)}, %{$config->field_map($domain, $grain)}}
        : $config->field_map($domain, $grain);
    my ($valid_groups, $group_configs) = _parse_groups(
        $config, $domain, $input, $group_map, $view, $configured, \@errors,
        $carry ? undef : $grain,
    );
    my $graph_series_group = _parse_graph_series_group(
        $view, $input, $valid_groups, \@errors,
    );
    my ($valid_measures, $measure_configs, $measure_config_list, $measure) = _parse_measures(
        $config, $domain, $input, $group_map, $view, \@errors, $grain, $carry,
    );
    my ($orders, $order, $direction) = _parse_orders(
        $config, $domain, $input, $config->field_map($domain, $retarget), $valid_fields,
        $query_library, \@errors, $retarget,
    );
    my ($limit, $page) = _parse_pagination($config, $input, $view, \@errors);
    my $filters = _parse_filters(
        $config, $input, $config->filter_map($domain, $grain),
        $valid_groups, $group_configs, \@errors,
    );

    my $state = $class->new(
        rows_of => $rows_of,
        retarget => $retarget,
        retarget_auto => $retarget_auto,
        view => $view,
        chart_type => $chart_type,
        graph_show_table => $graph_show_table,
        graph_series_group => $graph_series_group,
        graph_palette => $graph_palette,
        graph_category_colors => $graph_category_colors,
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
        measure_config_list => $measure_config_list,
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

# The explicitly chosen row grain, whose fields the pickers offer. An
# automatic retarget keeps the root pickers.
sub grain ($self) { return $self->retarget_auto ? undef : $self->retarget; }

sub query_pairs ($self) {
    my @pairs = (q => 1, view => $self->view);
    push @pairs, rows_of => $self->rows_of if length($self->rows_of // '');
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
    push @pairs, chart_type => $self->chart_type;
    push @pairs, graph_show_table => 1
        if $self->graph_show_table;
    push @pairs, graph_palette => $self->graph_palette // 'default';
    for my $override (@{$self->graph_category_colors // []}) {
        push @pairs,
            graph_category_field => $override->{field},
            graph_category_value => $override->{value},
            graph_category_format => $override->{format} // '',
            graph_category_color => $override->{color};
    }
    push @pairs, graph_series_group => $self->graph_series_group
        if $self->view eq 'graph' && length($self->graph_series_group // '');
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
            filter_values_json => ref($filter->{values}) eq 'ARRAY'
                ? to_json($filter->{values}) : '',
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
    for my $index (0 .. $#{$self->measures}) {
        my $measure = $self->measures->[$index];
        my $measure_config = ($self->measure_config_list // [])->[$index]
            // $self->measure_configs->{$measure} // {};
        my $transform = ref($measure_config->{transforms}) eq 'ARRAY'
            && ref($measure_config->{transforms}[0]) eq 'HASH'
            ? $measure_config->{transforms}[0] : {};
        push @pairs,
            measure => $measure,
            measure_alias => $measure_config->{alias} // '',
            measure_function => $measure_config->{function} // 'count',
            measure_bucket_ranges => $measure_config->{bucket_ranges} // '',
            measure_ignore_nulls => ($measure_config->{null_handling} // '') eq 'auto'
                ? 'auto' : ($measure_config->{ignore_nulls} ? 1 : 0),
            measure_series_id => $measure_config->{series_id} // "series_" . ($index + 1),
            measure_chart_type => $measure_config->{chart_type} // 'auto',
            measure_axis => $measure_config->{axis} // 'auto',
            measure_stack => $measure_config->{stack} // '',
            measure_color => $measure_config->{color} // '',
            measure_fill_opacity => $measure_config->{fill_opacity} // '',
            measure_transform => $transform->{type} // '',
            measure_transform_window => ref($transform->{parameters}) eq 'HASH'
                ? $transform->{parameters}{window} // '' : '';
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
    return sha256_hex(encode('UTF-8', join('|', @parts)));
}

sub api_query_payload ($self, $config, $domain) {
    return undef unless $self->valid && $self->view eq 'detail';
    return undef if defined $self->retarget;
    return undef if grep {
        !$_->{draft} && ($_->{grouped} || defined($_->{clause}))
    } @{$self->filters};

    my $detail_map = $config->detail_column_map($domain);
    my $field_map = $config->field_map($domain);
    my (@select, %nested);
    for my $index (0 .. $#{$self->fields}) {
        my $field = $self->fields->[$index];
        next if $detail_map->{$field}{action_id};
        my $column = $self->field_config_list->[$index]
            // $self->field_configs->{$field} // {};
        my $alias = $column->{alias} // '';
        # Explorer presentation labels may contain spaces, while canonical API
        # aliases are identifiers. Do not silently change a configured alias.
        return undef if length($alias) && $alias !~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        my $format = $column->{format} // '';
        my $selection = length($alias) || length($format)
            ? {
                field => $field,
                (length($alias) ? (alias => $alias) : ()),
                (length($format) ? (format => $format) : ()),
            }
            : $field;
        if ($field_map->{$field}{denormalizing}) {
            my ($association) = split /\./, $field, 2;
            unless ($nested{$association}) {
                $nested{$association} = [];
                push @select, $nested{$association};
            }
            push @{$nested{$association}}, $selection;
            next;
        }
        push @select, $selection;
    }
    return undef unless @select;

    my @filters;
    for my $filter (grep { !$_->{draft} } @{$self->filters}) {
        my $translated = {field => $filter->{field}, op => $filter->{op}};
        unless ($filter->{op} =~ /\A(?:is_null|not_null)\z/) {
            $translated->{value} = $filter->{op} eq 'in' || $filter->{op} eq 'not_in'
                ? [grep { length } map { _trim($_) } split /,/, $filter->{value}, -1]
                : $filter->{value};
        }
        $translated->{end} = $filter->{value_end}
            if $filter->{op} eq 'between';
        push @filters, $translated;
    }

    my @segments = @{$self->query_library_segments // []};
    if (defined($self->query_library_view) && length($self->query_library_view)) {
        unshift @segments,
            @{Selecto::QueryLibrary->view_segments($domain, $self->query_library_view)};
    }
    my %seen_segment;
    @segments = grep { !$seen_segment{$_}++ } @segments;

    return {
        select => \@select,
        (@segments ? (segments => \@segments) : ()),
        (%{$self->query_library_parameters // {}}
            ? (parameters => {%{$self->query_library_parameters}}) : ()),
        (@filters ? (filters => \@filters) : ()),
        (@{$self->orders}
            ? (order_by => [map { {%$_} } @{$self->orders}]) : ()),
        row_format => 'objects',
        limit => 0 + $self->limit,
        offset => ($self->page - 1) * $self->limit,
    };
}

sub as_hash ($self) {
    return {
        rows_of => $self->rows_of,
        retarget => $self->retarget,
        retarget_auto => $self->retarget_auto,
        view => $self->view,
        chart_type => $self->chart_type,
        graph_show_table => $self->graph_show_table,
        graph_series_group => $self->graph_series_group,
        graph_palette => $self->graph_palette,
        graph_category_colors => [map { {%$_} } @{$self->graph_category_colors // []}],
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
        measure_config_list => [map { {%$_} } @{$self->measure_config_list // []}],
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
    return $requested if Selecto::Components::RowActions->find($domain, $requested);
    return '' if $configured;
    my $available = Selecto::Components::RowActions->catalog($domain, $config);
    return @$available ? $available->[0]{id} : '';
}

sub _parse_fields ($config, $domain, $input, $detail_map, $field_map, $query_library, $configured, $errors, $rows_of = undef) {
    my $field_values = _values($input, 'field');
    my $field_aliases = _values($input, 'field_alias');
    my $field_formats = _values($input, 'field_format');
    if ($query_library->{materialize} && @{$query_library->{projection_fields}}) {
        $field_values = [@{$query_library->{projection_fields}}];
        $field_aliases = [];
        $field_formats = [];
    }
    $field_values = [@{$config->resolved_default_fields($domain, $rows_of)}]
        if !$configured && !grep { length(_scalar($_)) } @$field_values;
    if (@$field_values > $config->limits->get('max_fields')) {
        push @$errors, 'Too many detail columns were submitted.';
        $field_values = [];
    }
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
        @valid_fields = @{$config->resolved_default_fields($domain, $rows_of)};
        %field_configs = map { $_ => { alias => '', format => '' } } @valid_fields;
        @field_config_list = map { $field_configs{$_} } @valid_fields;
    }
    return (\@valid_fields, \%field_configs, \@field_config_list);
}

sub _parse_groups ($config, $domain, $input, $field_map, $view, $configured, $errors, $rows_of = undef) {
    my $group_values = _values($input, 'group');
    my $group_aliases = _values($input, 'group_alias');
    my $group_formats = _values($input, 'group_format');
    my $group_bucket_ranges = _values($input, 'group_bucket_ranges');
    my $group_prefix_lengths = _values($input, 'group_prefix_length');
    my $group_exclude_articles = _values($input, 'group_exclude_articles');
    $group_values = [@{$config->resolved_default_group($domain, $rows_of)}]
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
        @valid_groups = @{$config->resolved_default_group($domain, $rows_of)};
        %group_configs = map { $_ => {
            alias => '', format => '', bucket_ranges => '', prefix_length => 2,
            exclude_articles => 1,
        } } @valid_groups;
    }
    return (\@valid_groups, \%group_configs);
}

sub _parse_graph_series_group ($view, $input, $groups, $errors) {
    return '' unless $view eq 'graph';
    my $field = _scalar(_first($input, 'graph_series_group'));
    return '' unless length($field);
    unless (grep { $_ eq $field } @$groups) {
        push @$errors, 'The graph series group must be one of the selected group fields.';
        return '';
    }
    return $field;
}

sub _parse_measures ($config, $domain, $input, $field_map, $view, $errors, $rows_of = undef, $carry = 0) {
    my $measure_values = _values($input, 'measure');
    my $measure_aliases = _values($input, 'measure_alias');
    my $measure_functions = _values($input, 'measure_function');
    my $measure_bucket_ranges = _values($input, 'measure_bucket_ranges');
    my $measure_ignore_nulls = _values($input, 'measure_ignore_nulls');
    my $measure_series_ids = _values($input, 'measure_series_id');
    my $measure_chart_types = _values($input, 'measure_chart_type');
    my $measure_axes = _values($input, 'measure_axis');
    my $measure_stacks = _values($input, 'measure_stack');
    my $measure_colors = _values($input, 'measure_color');
    my $measure_fill_opacities = _values($input, 'measure_fill_opacity');
    my $measure_transforms = _values($input, 'measure_transform');
    my $measure_transform_windows = _values($input, 'measure_transform_window');
    my $default_measure = $config->default_measure($domain, $carry ? undef : $rows_of);
    $measure_values = [$default_measure->{id}]
        unless grep { length(_scalar($_)) } @$measure_values;
    my @valid_measures;
    my %measure_configs;
    my @measure_config_list;
    my %series_ids;
    for my $index (0 .. $#$measure_values) {
        my $measure_id = _scalar($measure_values->[$index]);
        next unless length($measure_id);
        if (@valid_measures >= $config->max_measures) {
            push @$errors, 'Too many measures were submitted.';
            last;
        }
        my $measure = $config->measure($measure_id, $domain, $rows_of)
            // ($carry ? $config->measure($measure_id, $domain) : undef);
        unless ($measure) {
            push @$errors, 'Choose an available measure.';
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
        my $null_input = _scalar($measure_ignore_nulls->[$index]);
        my $null_handling = length($null_input) ? lc($null_input) : 'auto';
        $null_handling = 'sql' if $null_handling eq '0';
        $null_handling = 'zero' if $null_handling eq '1';
        unless ($null_handling =~ /\A(?:auto|sql|zero)\z/) {
            push @$errors, 'A measure NULL-handling option is not available.';
            $null_handling = 'auto';
        }
        my $series_id = _scalar($measure_series_ids->[$index]) || 'series_' . ($index + 1);
        if ($series_id !~ /\A[a-z][a-z0-9_]{0,63}\z/ || $series_ids{$series_id}++) {
            push @$errors, 'A graph series identifier is not available.';
            $series_id = 'series_' . ($index + 1);
            $series_id .= '_' while $series_ids{$series_id}++;
        }
        my $series_chart_type = lc(_scalar($measure_chart_types->[$index]) || 'auto');
        unless ($series_chart_type =~ /\A(?:auto|bar|line|area)\z/) {
            push @$errors, 'A graph series chart type is not available.';
            $series_chart_type = 'auto';
        }
        my $axis = lc(_scalar($measure_axes->[$index]) || 'auto');
        unless ($axis =~ /\A(?:auto|left|right)\z/) {
            push @$errors, 'A graph series axis is not available.';
            $axis = 'auto';
        }
        my $stack = lc(_scalar($measure_stacks->[$index]));
        if (length($stack) && $stack !~ /\A[a-z][a-z0-9_]{0,31}\z/) {
            push @$errors, 'A graph series stack group is not available.';
            $stack = '';
        }
        my $color = lc(_scalar($measure_colors->[$index]));
        if (length($color) && $color !~ /\A#[0-9a-f]{6}\z/) {
            push @$errors, 'A graph series color must use #RRGGBB format.';
            $color = '';
        }
        my $fill_opacity = _scalar($measure_fill_opacities->[$index]);
        if (length($fill_opacity)
            && ($fill_opacity !~ /\A(?:0(?:\.\d+)?|1(?:\.0+)?)\z/
                || $fill_opacity < 0 || $fill_opacity > 1)) {
            push @$errors, 'A graph fill opacity must be from 0 through 1.';
            $fill_opacity = '';
        }
        my $aggregate_unit = Selecto::Analytics::UnitRegistry->aggregate_unit(
            $measure->{source_unit}, $function,
        );
        my $behavior = $function eq 'true_percentage' ? 'ratio'
            : $function =~ /\A(?:count|count_distinct|true_count|false_count|buckets|age_buckets)\z/
                ? 'flow' : $measure->{source_behavior};
        my $unit = $aggregate_unit;
        my @transforms;
        my $transform = lc(_scalar($measure_transforms->[$index]));
        if (length($transform)) {
            if (!defined($aggregate_unit)
                || !Selecto::Analytics::TransformRegistry->allows(
                    $transform, $aggregate_unit, $behavior,
                )) {
                push @$errors, 'A measure transform is not available for its result unit.';
            } else {
                my %parameters;
                if ($transform eq 'moving_average') {
                    my $window = _scalar($measure_transform_windows->[$index]) || 3;
                    if ($window !~ /\A\d+\z/ || $window < 2 || $window > 365) {
                        push @$errors, 'A moving-average window must be from 2 through 365.';
                        $window = 3;
                    }
                    $parameters{window} = 0 + $window;
                }
                push @transforms, {type => $transform, parameters => \%parameters};
                $unit = Selecto::Analytics::TransformRegistry->result_unit(
                    $transform, $aggregate_unit, $behavior,
                );
            }
        }
        my $normalized = {
            alias => $alias,
            function => $function,
            bucket_ranges => $bucket_ranges,
            null_handling => $null_handling,
            ignore_nulls => $function eq 'sum' && (
                $null_handling eq 'zero'
                || ($null_handling eq 'auto' && $view =~ /\A(?:aggregate|graph)\z/)
            ) ? 1 : 0,
            series_id => $series_id,
            chart_type => $series_chart_type,
            axis => $axis,
            stack => $stack,
            (length($color) ? (color => $color) : ()),
            (length($fill_opacity) ? (fill_opacity => 0 + $fill_opacity) : ()),
            transforms => \@transforms,
            (defined($aggregate_unit) ? (raw_unit => $aggregate_unit) : ()),
            (defined($unit) ? (unit => $unit) : ()),
            (defined($behavior) ? (behavior => $behavior) : ()),
        };
        push @valid_measures, $measure_id;
        push @measure_config_list, $normalized;
        $measure_configs{$measure_id} //= $normalized;
    }
    unless (@valid_measures) {
        my $fallback = $default_measure;
        @valid_measures = ($fallback->{id});
        my $normalized = {
            alias => '', function => $fallback->{aggregate}, bucket_ranges => '',
            null_handling => 'auto',
            ignore_nulls => $fallback->{aggregate} eq 'sum'
                && $view =~ /\A(?:aggregate|graph)\z/ ? 1 : 0,
            series_id => 'series_1', chart_type => 'auto', axis => 'auto', stack => '',
            transforms => [],
            (defined($fallback->{unit}) ? (raw_unit => $fallback->{unit}) : ()),
            (defined($fallback->{unit}) ? (unit => $fallback->{unit}) : ()),
            behavior => $fallback->{aggregate} eq 'count'
                ? 'flow' : $fallback->{source_behavior},
        };
        $measure_configs{$fallback->{id}} = $normalized;
        @measure_config_list = ($normalized);
    }
    if ($view eq 'graph') {
        my $plan = Selecto::Components::Graph::AxisPlanner->plan(\@measure_config_list);
        @measure_config_list = @{$plan->{series}};
        push @$errors, @{$plan->{errors}};
        my %stack_contract;
        for my $series (@measure_config_list) {
            my $stack = $series->{stack} // '';
            next unless length($stack);
            my $signature = defined($series->{unit})
                ? Selecto::Analytics::UnitRegistry->signature($series->{unit}) : '__untyped__';
            my $contract = join "\x1f", $series->{resolved_axis} // 'left', $signature;
            if (defined($stack_contract{$stack}) && $stack_contract{$stack} ne $contract) {
                push @$errors,
                    "Graph stack group $stack requires compatible units on one Y axis.";
                next;
            }
            $stack_contract{$stack} = $contract;
        }
        %measure_configs = ();
        for my $index (0 .. $#valid_measures) {
            $measure_configs{$valid_measures[$index]} //= $measure_config_list[$index];
        }
    }
    my $measure = $valid_measures[0];
    return (\@valid_measures, \%measure_configs, \@measure_config_list, $measure);
}

sub _parse_graph_colors ($config, $view, $input, $errors) {
    my $assistant = $config->query_assistant // {};
    require Selecto::Components::Graph::Colors;
    my $palettes = Selecto::Components::Graph::Colors->palettes($assistant->{palettes});
    my $palette = lc(_scalar(_first($input, 'graph_palette')) || 'default');
    if ($palette ne 'auto' && !exists($palettes->{$palette})) {
        push @$errors, 'A graph palette is not available.';
        $palette = 'default';
    }
    my $fields = _values($input, 'graph_category_field');
    my $values = _values($input, 'graph_category_value');
    my $formats = _values($input, 'graph_category_format');
    my $colors = _values($input, 'graph_category_color');
    my $count = @$fields;
    $count = @$values if @$values > $count;
    $count = @$colors if @$colors > $count;
    my @overrides;
    my %seen;
    for my $index (0 .. $count - 1) {
        last if @overrides >= 50;
        my $field = _scalar($fields->[$index]);
        my $value = _scalar($values->[$index]);
        my $format = _scalar($formats->[$index]);
        my $color = Selecto::Components::Graph::Colors->normalize_hex(
            _scalar($colors->[$index]),
        );
        next unless length($field) || length($value) || defined($color);
        unless (length($field) && defined($color)) {
            push @$errors, 'A category color requires a grouping field and #RRGGBB color.';
            next;
        }
        my $key = join "\x1f", $field, $format, $value;
        if ($seen{$key}++) {
            push @$errors, 'A category color can be configured only once.';
            next;
        }
        push @overrides, {field => $field, value => $value, format => $format, color => $color};
    }
    push @$errors, 'Too many category colors were submitted.' if $count > 50;
    return ($palette, \@overrides);
}

sub _parse_orders ($config, $domain, $input, $field_map, $valid_fields, $query_library, $errors, $rows_of = undef) {
    my $order_fields = _values($input, 'order');
    my $order_directions = _values($input, 'direction');
    if ($query_library->{materialize} && @{$query_library->{orders}}) {
        $order_fields = [map { $_->[0] } @{$query_library->{orders}}];
        $order_directions = [map { $_->[1] } @{$query_library->{orders}}];
    }
    my ($default_order) = grep {
        $field_map->{$_} && !$field_map->{$_}{denormalizing}
    } @$valid_fields;
    $default_order //= $config->primary_key($domain, $rows_of);
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

sub _parse_pagination ($config, $input, $view, $errors) {
    my $limit_input = _first($input, 'limit');
    my $limit_label = $view eq 'graph' ? 'Point' : 'Row';
    push @$errors, "$limit_label limit must be a positive integer."
        if defined($limit_input) && $limit_input !~ /\A[1-9]\d*\z/;
    my $default_limit = $view eq 'graph'
        ? ($config->max_limit < 500 ? $config->max_limit : 500)
        : $config->default_limit;
    my $limit = _positive_integer($limit_input, $default_limit);
    if ($view eq 'graph') {
        my $minimum = $config->max_limit < 250 ? $config->max_limit : 250;
        $limit = $minimum if $limit < $minimum;
    }
    if ($limit > $config->max_limit) {
        push @$errors, "$limit_label limit is above the configured maximum.";
        $limit = $config->max_limit;
    }
    return ($limit, 1) if $view eq 'graph';
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
    my $filter_values_json = _values($input, 'filter_values_json');
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
    $filter_count = @$filter_values_json if @$filter_values_json > $filter_count;
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
        my $values_json = _scalar($filter_values_json->[$index]);
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
        my $membership_values;
        if (($op eq 'in' || $op eq 'not_in') && length($values_json)) {
            my $decoded = eval {
                $config->limits->check_bytes('max_parameter_bytes', $values_json, 'invalid_query', 'Membership JSON');
                my $items = from_json($values_json);
                die "invalid membership" unless ref($items) eq 'ARRAY';
                Selecto::Components::InputBudget->membership($config->limits, $items);
                $items;
            };
            if (ref($decoded) ne 'ARRAY' || !@$decoded
                || grep { !defined($_) || ref($_) } @$decoded) {
                push @$errors, 'Membership filter values must be a non-empty JSON array of scalars.';
                next;
            }
            $membership_values = [map { "$_" } @$decoded];
            $value = '';
        } elsif (($op eq 'in' || $op eq 'not_in') && length($value)) {
            my @legacy;
            my $bounded = eval {
                $config->limits->check_bytes('max_parameter_bytes', $value, 'invalid_query', 'Membership input');
                @legacy = grep { length } map { _trim($_) } split /,/, $value, $config->limits->get('max_filter_values') + 1;
                Selecto::Components::InputBudget->membership($config->limits, \@legacy);
                1;
            };
            if (!$bounded) { push @$errors, 'Membership filter exceeds the configured budget.'; next; }
            unless (@legacy) {
                push @$errors, 'Membership filters require at least one value.';
                next;
            }
        }
        # A choice filter over an internal field reads it only through the
        # domain's declared choices: any other value, a range or a null test
        # would probe it.
        if ($field_map->{$field}{choices_only} && !_declared_choice($field_map->{$field}, $op, $value, $membership_values)) {
            push @$errors, 'Choose an available filter value.';
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
        $filter->{values} = $membership_values if $membership_values;
        $filter->{grouped} = 1 if $group_filter;
        $filter->{clause} = 0 + $clause if length($clause);
        $filter->{promoted} = 1 if !length($clause)
            && ($promoted_filter_index{$index + 1} || $promoted_filter_field{$field});
        $filter->{draft} = 1 if $op !~ /_null\z/
            && ($op =~ /in\z/ ? !length($value) && !$membership_values
                : !length($value) || ($op eq 'between' && !length($value_end)));
        push @filters, $filter;
    }
    my %draft_clause = map { $_->{clause} => 1 }
        grep { $_->{draft} && defined($_->{clause}) } @filters;
    for my $filter (@filters) {
        $filter->{draft} = 1
            if defined($filter->{clause}) && $draft_clause{$filter->{clause}};
    }
    for my $clause (keys %seen_clause) {
        my @conditions = grep {
            defined($_->{clause}) && $_->{clause} == $clause
        } @filters;
        if (!@conditions || @conditions > 5) {
            push @$errors, 'Each alternative filter clause must contain one to five conditions.';
            last;
        }
    }
    return \@filters;
}

sub _declared_choice ($catalog, $op, $value, $membership_values = undef) {
    return 0 unless $op =~ /\A(?:eq|ne|in|not_in)\z/;
    my %declared = map { ("$_->{value}" => 1) } @{$catalog->{filter_choices} // []};
    my @values = $op =~ /in\z/
        ? (ref($membership_values) eq 'ARRAY' ? @$membership_values : (map { _trim($_) } split /,/, $value))
        : ($value);
    return !grep { !$declared{$_} } @values if ref($membership_values) eq 'ARRAY';
    return !grep { length($_) && !$declared{$_} } @values;
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
        my $axis = eval { from_json($encoded) };
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
        my $values = eval { from_json($encoded) };
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

# The "Rows of" choice: '' lets a detail view choose its grain from its
# columns, '-' keeps root rows, and an association path names a retarget
# target the domain allows.
sub _parse_rows_of ($config, $domain, $input, $errors) {
    my $rows_of = _trim(_scalar(_first($input, 'rows_of')));
    return $rows_of if $rows_of eq '' || $rows_of eq '-';
    return $rows_of if $config->retarget_target($domain, $rows_of);
    push @$errors, 'The selected row grain is not available.';
    return '';
}

# The to-many association whose rows a detail view shows when every selected
# column comes from it: one row per related row rather than one root row with
# nested lists. Undefined when the columns include the root or span several
# associations, or when the domain does not allow that target.
sub auto_retarget ($class, $config, $domain, $fields) {
    my %associations;
    for my $field (@$fields) {
        return undef unless "$field" =~ /\A([^.]+)\.[^.]/;
        $associations{$1} = 1;
    }
    return undef unless keys(%associations) == 1;
    my ($path) = keys %associations;
    my $target = $config->retarget_target($domain, $path);
    return $target && $target->{to_many} ? $path : undef;
}

# The grain an aggregate's rows count: the single to-many association that
# its groups and measures read, if any. Its drilldown shows those rows.
sub aggregate_grain ($class, $config, $domain, $state) {
    return $state->retarget if defined $state->retarget;
    my %associations;
    my @fields = @{$state->groups};
    for my $measure_id (@{$state->measures}) {
        my $measure = $config->measure($measure_id, $domain);
        push @fields, $measure->{field} if $measure && defined $measure->{field};
    }
    for my $field (@fields) {
        next unless "$field" =~ /\A([^.]+)\./;
        my $target = $config->retarget_target($domain, $1);
        $associations{$1} = 1 if $target && $target->{to_many};
    }
    return keys(%associations) == 1 ? (keys %associations)[0] : undef;
}

# Submitted selections restricted to those a grain offers, with defaults
# where none remain, so changing the grain never strands invalid columns.
sub _retain_available ($config, $domain, $input, $rows_of, $view, $kinds = undef) {
    my %kinds = map { $_ => 1 } @{$kinds // [qw(field group measure order)]};
    my %copy = %$input;
    my $field_map = $config->field_map($domain, $rows_of);
    my $detail_map = $config->detail_column_map($domain, undef, $rows_of);
    my $keep = sub ($keys, $available) {
        my $values = _values(\%copy, $keys->[0]);
        my @indexes = grep { $available->(_scalar($values->[$_])) } 0 .. $#$values;
        for my $key (@$keys) {
            my $aligned = _values(\%copy, $key);
            $copy{$key} = [map { $aligned->[$_] // '' } @indexes];
        }
        return scalar @indexes;
    };
    if ($kinds{field}) {
        $keep->([qw(field field_alias field_format)], sub ($field) { $detail_map->{$field} })
            or $copy{field} = [@{$config->resolved_default_fields($domain, $rows_of)}];
    }
    if ($kinds{group}) {
        $keep->([qw(group group_alias group_format group_bucket_ranges group_prefix_length
            group_exclude_articles)], sub ($field) { $field_map->{$field} })
            or $view eq 'detail'
            or $copy{group} = [@{$config->resolved_default_group($domain, $rows_of)}];
        my %groups = map { $_ => 1 } @{_values(\%copy, 'group')};
        delete $copy{graph_series_group}
            unless $groups{_scalar(_first(\%copy, 'graph_series_group'))};
        my $filter_fields = _values(\%copy, 'filter_field');
        my $filter_groups = _values(\%copy, 'filter_group');
        $copy{filter_group} = [map {
            $groups{$filter_fields->[$_] // ''} ? $filter_groups->[$_] : 0
        } 0 .. $#$filter_groups];
    }
    if ($kinds{measure}) {
        $keep->([qw(measure measure_alias measure_function measure_bucket_ranges
            measure_ignore_nulls measure_series_id measure_chart_type measure_axis
            measure_stack measure_color measure_transform measure_transform_window)],
            sub ($id) { $config->measure($id, $domain, $rows_of) });
    }
    $keep->([qw(order direction)], sub ($field) { $field_map->{$field} }) if $kinds{order};
    return \%copy;
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

sub _query_library_state ($domain, $input, $errors, $limits) {
    my $library = Selecto::QueryLibrary->library($domain);
    my $view = _trim(_first($input, 'query_library_view'));
    my $materialized_view = _trim(_first($input, 'query_library_materialized_view'));
    my @segments = grep { length } map { _trim($_) }
        @{_values($input, 'query_library_segment')};
    for my $group (@{Selecto::QueryLibrary->segment_picker_groups($domain)}) {
        my $name = 'query_library_segment_choice_' . $group->{id};
        next unless exists $input->{$name};
        push @$errors, 'Choose only one segment-group option.'
            if @{_values($input, $name)} != 1;
        my %choices = map { $_->{segment} => 1 } @{$group->{choices}};
        @segments = grep { !$choices{$_} } @segments;
        my $choice = _trim(_first($input, $name));
        if (length($choice)) {
            if ($choices{$choice}) { push @segments, $choice }
            else { push @$errors, 'Choose an available segment-group option.' }
        }
    }
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
    my @effective_segments = @segments;
    push @effective_segments, @{Selecto::QueryLibrary->view_segments($domain, $view)}
        if length($view);
    my %seen_effective;
    @effective_segments = grep { !$seen_effective{$_}++ } @effective_segments;
    for my $group (@{Selecto::QueryLibrary->segment_picker_groups($domain)}) {
        my %choices = map { $_->{segment} => 1 } @{$group->{choices}};
        push @$errors, "$group->{label} allows only one choice."
            if (grep { $choices{$_} } @effective_segments) > 1;
    }

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
            $domain, $selection, \%parameters, $limits,
        );
        1;
    };
    push @$errors, 'Complete the query-library parameters with valid values.' unless $ok;
    # An authored segment may filter on internal fields: that is an internal
    # use. A segment that takes parameters may not, since a caller could probe
    # an internal value through them.
    if ($ok && @effective_segments && %$specs) {
        my @paths = eval {
            Selecto::Expression->field_references(Selecto::QueryLibrary->apply_segments(
                $domain, Selecto::Query->new, \@effective_segments, $normalized, $limits,
            )->predicate);
        };
        push @$errors, 'Choose an available query-library segment.'
            if grep { !eval { $domain->field_is_public($_) } } @paths;
    }

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

__END__

=head1 NAME

Selecto::Components::State - Parse and validate Explorer query-builder state

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

Every Explorer request, whether GET, POST or WebSocket, is parsed by
C<< Selecto::Components::State->from_input($config, $domain, \%input) >>.
Code that works with an explorer model mostly reads C<valid>, C<errors>,
C<view>, C<fields>, C<filters>, C<page> and C<query_pairs> from the result.
C<parameter_names> lists the recognized URL parameters (see
L<Selecto::Components/URL STATE>).

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
