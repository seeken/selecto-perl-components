package Selecto::Components::QueryBuilder;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Components::BucketParser ();
use Selecto::Components::DateShortcut ();
use Selecto::Components::RowActions ();
use Selecto::Components::Util qw(humanize trim);
use Selecto::Expression ();
use Selecto::QueryLibrary ();
use Selecto::Components::InputBudget ();

sub build ($class, $config, $domain, $state, $options = undef) {
    die "cannot build an invalid explorer state\n" unless $state->valid;
    $options //= {};
    die "query builder options must be an object\n" unless ref($options) eq 'HASH';
    my $built = $state->view eq 'detail'
        ? $class->_detail($config, $domain, $state, $options)
        : $class->_aggregate($config, $domain, $state, $options);
    Selecto::Components::InputBudget->query($config->limits, $built->{query});
    my $retarget = $state->retarget;
    return $built unless defined $retarget;
    # Explorer state names fields from the root. A retargeted grain keeps the
    # filters and saved segments as root context and re-roots the rest.
    $built->{query} = _retargeted($built->{query}, $retarget);
    $built->{count_selections} = [map { _rerooted($_, $retarget) } @{$built->{count_selections}}]
        if $built->{count_selections};
    my $target = $config->retarget_target($domain, $retarget);
    $built->{retarget} = {
        path => $retarget,
        label => $target->{label},
        auto => $state->retarget_auto ? 1 : 0,
    };
    return $built;
}

sub _retargeted ($query, $path) {
    my $retargeted = $query->retarget($path)
        ->select(map { _rerooted($_, $path) } @{$query->selections});
    my @groups = map { _rerooted($_, $path) } @{$query->groups};
    if (@groups) {
        my $mode = $query->grouping_mode;
        # The rerooted groups keep their order, so declared sets keep their positions.
        $retargeted = $mode eq 'rollup' ? $retargeted->group_by_rollup(\@groups)
            : $mode eq 'cube' ? $retargeted->group_by_cube(\@groups)
            : $mode eq 'grouping_sets'
                ? $retargeted->group_by_grouping_sets(map { [@groups[@$_]] } @{$query->grouping_sets})
            : $retargeted->group_by(\@groups);
    }
    $retargeted = $retargeted->order_by(_rerooted($_->[0], $path), $_->[1]) for @{$query->orders};
    $retargeted = $retargeted->limit($query->limit_value) if defined $query->limit_value;
    $retargeted = $retargeted->offset($query->offset_value) if defined $query->offset_value;
    return $retargeted;
}

# A copy of an expression with each root-relative field under $path renamed
# relative to the target relation.
sub _rerooted ($value, $path) {
    if (blessed($value) && $value->isa('Selecto::Expression')) {
        if ($value->kind eq 'field') {
            my $name = $value->arguments->[0];
            die "field $name is outside the retarget target $path\n"
                unless index($name, "$path.") == 0;
            my $field = Selecto::Expression->field(substr($name, length($path) + 1));
            return defined($value->alias_name) ? $field->as($value->alias_name) : $field;
        }
        my $copy = Selecto::Expression->new(
            $value->kind, map { _rerooted($_, $path) } @{$value->arguments},
        );
        return defined($value->alias_name) ? $copy->as($value->alias_name) : $copy;
    }
    return [map { _rerooted($_, $path) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => _rerooted($value->{$_}, $path)) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}

sub _detail ($class, $config, $domain, $state, $options) {
    my $retarget = $state->retarget;
    my $field_map = $config->query_field_map($domain, $retarget);
    my $detail_map = $config->detail_column_map($domain, undef, $retarget);
    # A retargeted grain resolves its columns against the target relation.
    my $target = defined($retarget) ? $config->retarget_target($domain, $retarget) : undef;
    my (@columns, %nested_column);
    my %field_key_count;
    for my $field_index (0 .. $#{$state->fields}) {
        my $field = $state->fields->[$field_index];
        my $catalog = $detail_map->{$field};
        if ($catalog->{action_id}) {
            push @columns, {
                key => '__selecto_action_column_' . $catalog->{action_id},
                field => $field,
                label => $catalog->{label},
                type => 'action',
                action_id => $catalog->{action_id},
            };
            next;
        }
        my $resolved = $target
            ? $target->{domain}->resolve(substr($field, length($retarget) + 1))
            : $domain->resolve($field);
        if ($resolved->{association} && $resolved->{association}->cardinality eq 'many') {
            my $association = $resolved->{association};
            my $name = $association->name;
            my $nested = $nested_column{$name};
            unless ($nested) {
                $nested = {
                    key => '__selecto_nested_' . _field_alias($name),
                    field => $name,
                    label => $config->localize(
                        $domain, "associations.$name.label", _humanize($name),
                        {kind => 'association', id => $name, attribute => 'label'},
                    ),
                    type => 'nested',
                    nested => 1,
                    association => $name,
                    nested_fields => [],
                };
                $nested_column{$name} = $nested;
                push @columns, $nested;
            }
            my $column_config = $state->field_config_list->[$field_index]
                // $state->field_configs->{$field} // {};
            push @{$nested->{nested_fields}}, {
                field => $resolved->{field},
                path => $field,
                label => $column_config->{alias} || $config->localize(
                    $domain, "fields.$field.nested_label", _humanize($resolved->{field}),
                    {kind => 'nested_field', path => $field, attribute => 'label'},
                ),
                type => $field_map->{$field}{type},
                (defined($field_map->{$field}{html_format})
                    ? (html_format => $field_map->{$field}{html_format}) : ()),
            };
            next;
        }
        my $column_config = $state->field_config_list->[$field_index]
            // $state->field_configs->{$field} // {};
        my $base_key = _field_alias($field);
        my $occurrence = ++$field_key_count{$base_key};
        push @columns, {
            key => $occurrence == 1 ? $base_key : $base_key . '__' . $occurrence,
            field => $field,
            label => $column_config->{alias} || $field_map->{$field}{label},
            (defined($field_map->{$field}{description})
                ? (description => $field_map->{$field}{description}) : ()),
            type => $column_config->{format} ? 'string' : $field_map->{$field}{type},
            source_type => $field_map->{$field}{type},
            format => $column_config->{format} // '',
            (defined($field_map->{$field}{link})
                ? (link => {%{$field_map->{$field}{link}}}) : ()),
            (defined($field_map->{$field}{html_format})
                ? (html_format => $field_map->{$field}{html_format}) : ()),
        };
    }
    my @query_columns = grep { !$_->{action_id} } @columns;
    my @action_ids = map { $_->{action_id} } grep { $_->{action_id} } @columns;
    my $action_key;
    if (@action_ids) {
        my $primary_key = $config->primary_key($domain, $retarget);
        my ($selected_primary_key) = grep {
            $_->{field} eq $primary_key && !$_->{format}
        } @query_columns;
        if ($selected_primary_key) {
            $action_key = $selected_primary_key->{key};
        } else {
            $action_key = '__selecto_action_target';
            push @query_columns, {
                key => $action_key,
                field => $primary_key,
                label => $primary_key,
                type => $field_map->{$primary_key}{type},
                format => '',
                hidden => 1,
            };
        }
    }
    my %query_key = map {
        (!$_->{format} && !$_->{nested} ? ($_->{field} => $_->{key}) : ())
    } @query_columns;
    my %used_key = map { $_->{key} => 1 } @query_columns;
    my %action_eligibility_fields;
    my $action_specs = $domain->actions;
    for my $action_id (@action_ids) {
        my $selection = ref($action_specs) eq 'HASH'
            && ref($action_specs->{$action_id}) eq 'HASH'
            ? $action_specs->{$action_id}{selection} : undef;
        next unless ref($selection) eq 'HASH';
        my $field = $selection->{eligibility_field};
        next unless defined($field) && !ref($field) && length("$field");
        if ("$field" =~ /\A__/) {
            $action_eligibility_fields{$action_id} = "$field";
            next;
        }
        my $key = $query_key{$field};
        unless (defined($key)) {
            my $base_key = _field_alias($field);
            $key = $base_key;
            my $suffix = 1;
            $key = $base_key . '_' . ++$suffix while $used_key{$key};
            push @query_columns, {
                key => $key,
                field => "$field",
                label => $field_map->{$field}{label},
                type => $field_map->{$field}{type},
                format => '',
                hidden => 1,
            };
            $query_key{$field} = $key;
            $used_key{$key} = 1;
        }
        $action_eligibility_fields{$action_id} = $key;
    }
    my %action_row_details;
    for my $action_id (@action_ids) {
        my $selection = ref($action_specs) eq 'HASH' && ref($action_specs->{$action_id}) eq 'HASH'
            ? $action_specs->{$action_id}{selection} : undef;
        next unless ref($selection) eq 'HASH' && ($selection->{mode} // '') eq 'groups'
            && ref($selection->{row_details}) eq 'ARRAY';
        my (@details, %seen_detail);
        for my $detail (@{$selection->{row_details}}) {
            next unless ref($detail) eq 'HASH';
            my $id = defined($detail->{id}) && !ref($detail->{id}) ? "$detail->{id}" : '';
            my $field = defined($detail->{field}) && !ref($detail->{field}) ? "$detail->{field}" : '';
            next unless $id =~ /\A[a-z][a-z0-9_]*\z/ && !$seen_detail{$id}++
                && $field =~ /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/
                && $field_map->{$field};
            my $key = $query_key{$field};
            unless (defined($key)) {
                my $base_key = '__selecto_action_' . _field_alias($action_id) . '_' . _field_alias($id);
                $key = $base_key;
                my $suffix = 1;
                $key = $base_key . '_' . ++$suffix while $used_key{$key};
                push @query_columns, {
                    key => $key,
                    field => $field,
                    label => $field_map->{$field}{label},
                    type => $field_map->{$field}{type},
                    format => '',
                    hidden => 1,
                };
                $query_key{$field} = $key;
                $used_key{$key} = 1;
            }
            my $label = defined($detail->{label}) && !ref($detail->{label})
                ? "$detail->{label}" : _humanize($id);
            $label = $config->localize(
                $domain, "actions.$action_id.selection.row_details.$id.label", $label,
                {
                    kind => 'action_row_detail', action_id => $action_id,
                    id => $id, attribute => 'label',
                },
            );
            push @details, {id => $id, label => $label, key => $key};
        }
        $action_row_details{$action_id} = \@details if @details;
    }
    for my $column (grep { $_->{link} } @columns) {
        my $id_field = $column->{link}{id_field};
        my $link_key = $query_key{$id_field};
        unless (defined($link_key)) {
            my $base_key = '__selecto_link_' . _field_alias($id_field);
            $link_key = $base_key;
            my $suffix = 1;
            $link_key = $base_key . '_' . ++$suffix while $used_key{$link_key};
            push @query_columns, {
                key => $link_key,
                field => $id_field,
                label => $id_field,
                type => $field_map->{$id_field}{type},
                format => '',
                hidden => 1,
            };
            $query_key{$id_field} = $link_key;
            $used_key{$link_key} = 1;
        }
        $column->{link_key} = $link_key;
    }
    my $row_click_action = Selecto::Components::RowActions->find(
        $domain, $state->row_click_action, $config,
    );
    my @row_click_fields;
    if ($row_click_action) {
        for my $field (@{$row_click_action->{required_fields} // []}) {
            my $key = $query_key{$field};
            unless (defined($key)) {
                my $base_key = '__selecto_row_click_' . _field_alias($field);
                $key = $base_key;
                my $suffix = 1;
                $key = $base_key . '_' . ++$suffix while $used_key{$key};
                push @query_columns, {
                    key => $key,
                    field => $field,
                    label => $field_map->{$field}{label},
                    type => $field_map->{$field}{type},
                    format => '',
                    hidden => 1,
                };
                $query_key{$field} = $key;
                $used_key{$key} = 1;
            }
            push @row_click_fields, {field => $field, key => $key};
        }
    }
    my $query = Selecto::Query->new->select(map {
        _column_expression($_)->as($_->{key})
    } @query_columns);
    $query = _with_filters($query, $state, $config, $domain);
    for my $order (@{$state->orders}) {
        $query = $query->order_by($order->{field}, $order->{direction});
    }
    # One row beyond the page says whether another follows: a page that ends
    # the results gives the total, and only one with more after it is counted
    # (Explorer model, peek and count_beyond_page).
    my $paginate = !exists($options->{paginate}) || $options->{paginate} ? 1 : 0;
    $query = $query->limit($state->limit + 1)
        ->offset(($state->page - 1) * $state->limit)
        if $paginate;
    $query = _with_query_library($query, $domain, $state, $config->limits);
    return {
        query => $query,
        peek => $paginate,
        count_beyond_page => 1,
        columns => \@columns,
        query_columns => \@query_columns,
        action_key => $action_key,
        action_ids => \@action_ids,
        action_eligibility_fields => \%action_eligibility_fields,
        action_row_details => \%action_row_details,
        row_click_action => $row_click_action,
        row_click_fields => \@row_click_fields,
        count_selections => [Selecto::Expression->field($config->primary_key($domain, $retarget))],
        graph => 0,
    };
}

sub _aggregate ($class, $config, $domain, $state, $options) {
    my $field_map = $config->field_map($domain, $state->retarget);
    # The summary table with one group shown as columns: the table itself is
    # the ordinary summary of the other groups (its rollup rows, order and
    # pages, with measures that are each row's total across the columns), and
    # the cells under each column value are fetched for the page shown
    # (pivot_cells). The grid has its own pivot below.
    if ($state->view eq 'aggregate' && !$state->aggregate_grid && defined($state->pivot_column)
        && !$options->{pivot_part} && @{$state->groups} >= 2 && @{$state->measures}) {
        require Selecto::Components::State;
        my $rows_state = Selecto::Components::State->new(
            %{$state->as_hash},
            groups => [grep { $_ ne $state->pivot_column } @{$state->groups}],
            filter_groups => [@{$state->groups}],
            pivot_column => undef,
        );
        # Without the Total columns the rows query only finds the page's rows.
        my $totals = ($state->pivot_totals // 1) ? 1 : 0;
        my $built = $class->_aggregate($config, $domain, $rows_state,
            {%$options, pivot_part => 1, measure_values => $totals});
        my ($column_index) = grep { $state->groups->[$_] eq $state->pivot_column } 0 .. $#{$state->groups};
        $built->{pivot} = {
            column_field => $state->pivot_column,
            column_index => $column_index,
            row_indexes => [grep { $_ != $column_index } 0 .. $#{$state->groups}],
            totals => $totals,
        };
        return $built;
    }
    # Subtotal rows need the adapter's GROUP BY ROLLUP; callers pass
    # rollup => 0 for adapters without it, which then group plainly.
    my $rollup = $state->view eq 'aggregate' && @{$state->groups}
        && ($options->{rollup} // 1) ? 1 : 0;
    my @group_columns = map {
        my $field = $_;
        my $column_config = $state->group_configs->{$field} // {};
        my $dimension = $field_map->{$field}{dimension};
        {
            key => _field_alias($field),
            field => $field,
            label => $column_config->{alias}
                || ($dimension ? $dimension->{label} : $field_map->{$field}{label}),
            (defined($field_map->{$field}{description})
                ? (description => $field_map->{$field}{description}) : ()),
            type => $dimension ? $dimension->{display_type}
                : $column_config->{format} ? 'string' : $field_map->{$field}{type},
            source_type => $field_map->{$field}{type},
            format => $column_config->{format} // '',
            drilldown_grouped => length($column_config->{format} // '')
                && ($column_config->{format} // '') ne 'default' ? 1 : 0,
            _bucket_order($column_config),
            (@{$column_config->{pivot_values} // []} ? (
                pivot_values => $column_config->{pivot_values},
                pivot_other => $column_config->{pivot_other},
                pivot_other_value => $column_config->{pivot_other_value},
                pivot_labels => $column_config->{pivot_labels},
                drilldown_grouped => 1,
                drilldown_key => '__selecto_dimension_key_' . _field_alias($field),
            ) : ()),
            (defined($field_map->{$field}{html_format})
                ? (html_format => $field_map->{$field}{html_format}) : ()),
            ($dimension ? (
                dimension => {%$dimension},
                drilldown_field => $dimension->{key_field},
                drilldown_key => '__selecto_dimension_key_' . _field_alias($field),
            ) : ()),
        }
    } @{$state->groups};
    my (
        @groups, @group_selections, @group_orders,
        @group_sort_selections, @dimension_key_selections,
    );
    my $group_index = 0;
    for my $column (@group_columns) {
        $group_index++;
        if (my $dimension = $column->{dimension}) {
            my $pivot = $state->group_configs->{$column->{field}}{pivot_values};
            my $key = $pivot ? _group_expression($column, $state->group_configs->{$column->{field}})
                : Selecto::Expression->field($dimension->{key_field});
            if ($pivot) { $column->{drilldown_field} = $column->{field}; }
            my $display = $rollup
                ? Selecto::Expression->dimension_display(
                    $dimension->{display_field}, $key
                )
                : Selecto::Expression->min($dimension->{display_field});
            push @groups, $key;
            push @group_selections, $display->as($column->{key});
            push @group_orders, Selecto::Expression->min(Selecto::Expression->value(
                ['case', [['is_null', $dimension->{key_field}], ['literal', 1]], ['else', ['literal', 0]]]))
                if $options->{top_ranking};
            push @group_orders, $display, $key;
            push @dimension_key_selections, $key->as($column->{drilldown_key});
        } else {
            my $group = _group_expression(
                $column, $state->group_configs->{$column->{field}} // {}
            );
            push @groups, $group;
            push @group_selections, $group->as($column->{key});
            push @dimension_key_selections, $group->as($column->{drilldown_key}) if $column->{pivot_values};
            my $natural_order = _group_natural_order_expression(
                $column, $state->group_configs->{$column->{field}} // {},
            );
            if ($natural_order) {
                my $sort_key = '__selecto_group_sort_' . $group_index;
                my $aggregate_order = $rollup
                    && Selecto::Components::BucketParser->group_kind($column->{format})
                    ? Selecto::Expression->dimension_display($natural_order, $group)
                    : Selecto::Expression->min($natural_order);
                $column->{sort_key} = $sort_key;
                push @group_sort_selections, $aggregate_order->as($sort_key);
                if (!$rollup && ($column->{bucket_order} // '') eq 'lower_bound') {
                    my $missing = Selecto::Expression->max(Selecto::Expression->value(
                        ['case', [['is_null', $column->{field}], ['literal', 1]], ['else', ['literal', 0]]],
                    ));
                    push @group_sort_selections, $missing->as($sort_key . '_missing');
                    push @group_orders, $missing;
                }
                push @group_orders, $aggregate_order;
            } else {
                push @group_orders, Selecto::Expression->min(Selecto::Expression->value(
                    ['case', [['is_null', $column->{field}], ['literal', 1]], ['else', ['literal', 0]]]))
                    if $options->{top_ranking};
                push @group_orders, $group;
            }
        }
    }
    my @selections = (@group_selections, @group_sort_selections);
    # measure_values => 0 describes the measures without selecting them.
    my $measure_values = $options->{measure_values} // 1;
    my @measure_columns;
    my %measure_occurrence;
    for my $measure_index (0 .. $#{$state->measures}) {
        my $measure_id = $state->measures->[$measure_index];
        my $measure = $config->measure($measure_id, $domain, $state->retarget);
        my $measure_config = ($state->measure_config_list // [])->[$measure_index]
            // $state->measure_configs->{$measure_id} // {};
        my $function = $measure_config->{function} // $measure->{aggregate};
        my $alias = $measure_config->{alias} // '';
        my $measure_key = _measure_key(
            $measure_id, ++$measure_occurrence{$measure_id},
        );
        if ($function eq 'buckets' || $function eq 'age_buckets') {
            # A duration is already an age. Numeric age buckets compare its
            # value directly; date fields first become elapsed calendar days.
            my $bucket_function = $config->numeric_type($field_map->{$measure->{field}}{type})
                ? 'buckets' : $function;
            my $ranges = Selecto::Components::BucketParser->parse($measure_config->{bucket_ranges});
            my $index = 0;
            for my $range (@$ranges) {
                next if !defined($range->{minimum}) && !defined($range->{maximum});
                next if defined($range->{minimum}) && $range->{minimum} !~ /\A\d+\z/;
                my $key = $measure_key . '__bucket_' . ++$index;
                my $label = _bucket_measure_label($range->{label}, $bucket_function, $alias, $index);
                my $expression = Selecto::Expression->count_bucket(
                    $measure->{field},
                    $range->{minimum},
                    $range->{maximum},
                    $bucket_function eq 'age_buckets' ? 'elapsed_days' : 'numeric',
                );
                push @measure_columns, {
                    key => $key, field => $measure->{field}, label => $label,
                    raw_label => _bucket_measure_label(
                        $range->{label}, $bucket_function, '', $index,
                    ),
                    type => 'integer', measure => 1, function => $function,
                    series => {
                        id => ($measure_config->{series_id} // 'series_' . ($measure_index + 1)) .
                            '_bucket_' . $index,
                        chart_type => $measure_config->{chart_type} // 'auto',
                        axis => $measure_config->{resolved_axis} // 'left',
                        stack => $measure_config->{stack} // '',
                        color => $measure_config->{color} // '',
                        (defined($measure_config->{fill_opacity})
                            ? (fill_opacity => $measure_config->{fill_opacity}) : ()),
                        transforms => $measure_config->{transforms} // [],
                        raw_unit => {kind => 'count'},
                        unit => $measure_config->{unit} // {kind => 'count'},
                        behavior => 'flow',
                    },
                };
                push @selections, $expression->as($key) if $measure_values;
            }
            next;
        }
        my $label = length($alias) ? $alias : _measure_label($measure, $function, $field_map);
        push @measure_columns, {
            key => $measure_key,
            field => $measure->{field},
            label => $label,
            raw_label => _measure_label($measure, $function, $field_map),
            type => $function =~ /\A(?:count|count_distinct|true_count|false_count)\z/
                ? 'integer' : $function eq 'true_percentage'
                    ? 'decimal' : $field_map->{$measure->{field}}{type},
            measure => 1,
            function => $function,
            (defined($measure->{field}) && ref($field_map->{$measure->{field}}{display}) eq 'HASH'
                ? (display => $field_map->{$measure->{field}}{display}) : ()),
            series => {
                id => $measure_config->{series_id} // 'series_' . ($measure_index + 1),
                chart_type => $measure_config->{chart_type} // 'auto',
                axis => $measure_config->{resolved_axis} // 'left',
                stack => $measure_config->{stack} // '',
                color => $measure_config->{color} // '',
                (defined($measure_config->{fill_opacity})
                    ? (fill_opacity => $measure_config->{fill_opacity}) : ()),
                transforms => $measure_config->{transforms} // [],
                (defined($measure_config->{raw_unit})
                    ? (raw_unit => $measure_config->{raw_unit}) : ()),
                (defined($measure_config->{unit})
                    ? (unit => $measure_config->{unit}) : ()),
                (defined($measure_config->{behavior})
                    ? (behavior => $measure_config->{behavior}) : ()),
            },
        };
        push @selections, _measure_expression($measure, $measure_config)->as($measure_key)
            if $measure_values;
    }
    my @columns = (@group_columns, @measure_columns);
    # The grid pivots one group into columns. A group marked with pivot_column
    # may do that for any number of row groups and measures; without one, the
    # grid is the original shape: two groups, the second across, one measure.
    my $grid_column_field = $state->view eq 'aggregate' && $state->aggregate_grid
        ? $state->pivot_column : undef;
    my ($grid_column_index) = defined($grid_column_field)
        ? grep { $group_columns[$_]{field} eq $grid_column_field } 0 .. $#group_columns : ();
    my $aggregate_grid = $state->view eq 'aggregate' && $state->aggregate_grid
        && (defined($grid_column_index)
            ? @group_columns >= 2 && @measure_columns >= 1
            : @group_columns == 2 && @measure_columns == 1) ? 1 : 0;
    $grid_column_index = $#group_columns if $aggregate_grid && !defined($grid_column_index);
    my @grid_row_indexes = $aggregate_grid ? grep { $_ != $grid_column_index } 0 .. $#group_columns : ();
    push @selections, @dimension_key_selections;
    my $rollup_key = '__selecto_rollup_grouping';
    push @selections, Selecto::Expression->grouping(\@groups)->as($rollup_key) if $rollup;
    my $query = Selecto::Query->new->select(@selections);
    my $peek = 0;
    # The grid is a matrix of two dimensions. A cube adds what a rollup lacks
    # there: a total for every column as well as for every row. Callers pass
    # cube => 1 only for adapters that support it.
    # Totals need four grouping sets: every group (the cells), the row groups
    # (row totals), the column group (column totals) and none (the grand
    # total). For two groups that is exactly a cube. Callers pass cube and
    # grouping_sets only for adapters that support them; without the one a
    # grid needs it keeps its rollup query and shows no totals.
    # A pivot without its Total columns needs neither the row totals nor the
    # grand total: only the cells and the Total row.
    my $total_columns = defined($grid_column_field) && !($state->pivot_totals // 1) ? 0 : 1;
    my $cube = $rollup && $aggregate_grid && @groups == 2 && $options->{cube}
        && ($total_columns || !$options->{grouping_sets}) ? 1 : 0;
    my $grid_sets = $rollup && $aggregate_grid && !$cube && $options->{grouping_sets} ? 1 : 0;
    $query = $cube ? $query->group_by_cube(\@groups)
        : $grid_sets ? $query->group_by_grouping_sets(
            [@groups], ($total_columns ? [@groups[@grid_row_indexes]] : ()),
            [$groups[$grid_column_index]], ($total_columns ? [] : ()))
        : $rollup ? $query->group_by_rollup(\@groups) : $query->group_by(\@groups);
    $query = _with_filters($query, $state, $config, $domain);
    # An explicitly selected measure ordering precedes natural group order.
    # Resolve only governed selections; never treat a request as an SQL alias.
    my %measure_selections = map { ($_->alias_name => $_) }
        grep { defined($_->alias_name) } @selections;
    for my $order (@{$state->orders // []}) {
        next unless $order->{field} =~ /\Ameasure:(.+)\z/;
        my $expression = $measure_selections{_measure_key($1)} or next;
        $query = $query->order_by($expression, $order->{direction});
    }
    $query = $query->order_by($_, 'asc') for @group_orders;
    if ($aggregate_grid) {
        # A pair of high-cardinality dimensions can otherwise materialize an
        # effectively unbounded matrix in both PostgreSQL and the browser.
        $query = $query->limit($config->max_grid_result_cells + 1);
    } elsif (!exists($options->{paginate}) || $options->{paginate}) {
        # An aggregate page is counted from its own rows rather than a second, equally
        # expensive count query: one row beyond the page says whether another follows
        # (Explorer model, peek).
        $peek = $state->view eq 'aggregate' ? 1 : 0;
        $query = $query->limit($state->limit + $peek)
            ->offset(($state->page - 1) * $state->limit);
    }
    $query = _with_query_library($query, $domain, $state, $config->limits);
    return {
        query => $query,
        columns => \@columns,
        peek => $peek,
        graph => $state->view eq 'graph' ? 1 : 0,
        aggregate_grid => $aggregate_grid,
        rollup => $rollup,
        # Rows may drop any group, not only trailing ones.
        cube => $cube || $grid_sets ? 1 : 0,
        ($aggregate_grid ? (grid => {
            column => $grid_column_index, rows => \@grid_row_indexes, totals => $cube || $grid_sets ? 1 : 0,
            total_columns => $total_columns,
            explicit => defined($grid_column_field) ? 1 : 0,
        }) : ()),
        rollup_key => $rollup ? $rollup_key : undef,
        group_count => scalar(@groups),
    };
}

# The cells of a summary pivot at one rollup level: the first $level row
# groups and the column group, grouped plainly, for the given row keys only.
# $keys is a list of rows, each a list of {field, value, grouped} for its row
# groups; level 0 takes none and returns every column value with the whole
# result's measures, which are both the column list and the Total row.
sub pivot_cells ($class, $config, $domain, $state, $level, $keys = undef) {
    my $column_field = $state->pivot_column;
    my @row_groups = grep { $_ ne $column_field } @{$state->groups};
    require Selecto::Components::State;
    my $cells_state = Selecto::Components::State->new(
        %{$state->as_hash},
        groups => [@row_groups[0 .. $level - 1], $column_field],
        filter_groups => [@{$state->groups}],
        pivot_column => undef,
        page => 1,
    );
    my $built = $class->_aggregate($config, $domain, $cells_state, {paginate => 0, rollup => 0, pivot_part => 1,
        top_ranking => !$level && $state->pivot_column_top && !@{$state->group_configs->{$column_field}{pivot_values} // []}});
    if ($level > 0) {
        my $field_map = $config->field_map($domain, $state->retarget);
        my @alternatives = map {
            my @conditions = map {
                my $type = ($field_map->{$_->{field}} // {})->{type};
                my $operand = $_->{grouped}
                    ? _group_expression({field => $_->{field}, type => $type}, $state->group_configs->{$_->{field}} // {})
                    : _temporal_expression($_->{field}, $type);
                defined($_->{value}) ? Selecto::Expression->eq($operand, "$_->{value}")
                    : Selecto::Expression->is_null($operand)
            } @$_;
            @conditions == 1 ? $conditions[0] : Selecto::Expression->all(\@conditions)
        } @$keys;
        $built->{query} = $built->{query}->where(
            @alternatives == 1 ? $alternatives[0] : Selecto::Expression->any(\@alternatives));
    }
    return $built;
}

sub _measure_expression ($measure, $config) {
    my $function = $config->{function} // $measure->{aggregate};
    return defined($measure->{field})
        ? Selecto::Expression->count_field($measure->{field})
        : Selecto::Expression->count
        if $function eq 'count';
    return Selecto::Expression->sum_zero($measure->{field})
        if $function eq 'sum' && $config->{ignore_nulls};
    return Selecto::Expression->can($function)->('Selecto::Expression', $measure->{field});
}

sub _measure_label ($measure, $function, $field_map) {
    return $measure->{label} if $measure->{curated} && $function eq $measure->{aggregate};
    return $measure->{label} unless defined($measure->{field});
    my $field_label = defined($measure->{field})
        ? $field_map->{$measure->{field}}{label} : 'Rows';
    my %labels = (
        count => 'Count', count_distinct => 'Count distinct', avg => 'Average', sum => 'Sum',
        min => 'Minimum', max => 'Maximum', true_count => 'True count', false_count => 'False count',
        true_percentage => 'Percent true',
    );
    return $field_label . ' ' . ($labels{$function} // $function);
}

sub _measure_key ($measure_id, $occurrence = 1) {
    my $key = $measure_id =~ /\A[A-Za-z][A-Za-z0-9_]*\z/
        ? $measure_id : 'measure__' . _field_alias($measure_id);
    return $occurrence > 1 ? $key . '__' . $occurrence : $key;
}

sub _bucket_measure_label ($label, $function, $alias, $index) {
    my $display = $function eq 'age_buckets'
        ? ($label =~ /\A1\z/ ? '1 day' : "$label days") : $label;
    return $index == 1 && length($alias) ? "$alias: $display" : $display;
}

sub _column_expression ($column) {
    return Selecto::Expression->related_collection(
        $column->{association},
        [map { $_->{field} } @{$column->{nested_fields}}],
    ) if $column->{nested};
    my $field = _temporal_expression($column->{field}, $column->{source_type} // $column->{type});
    return $column->{format}
        ? Selecto::Expression->datetime_format($field, $column->{format})
        : $field;
}

sub _group_expression ($column, $config) {
    if (@{$config->{pivot_values} // []}) {
        my $field = $config->{pivot_key_field} // $column->{field};
        return Selecto::Expression->value(['case',
            (map { [(defined($config->{pivot_null_value}) && $_ eq $config->{pivot_null_value}
                ? ['is_null', $field] : ['eq', $field, "$_"]), ['literal', "$_", 'string']] } @{$config->{pivot_values}}),
            ['else', ['literal', $config->{pivot_other_value}, 'string']]]);
    }
    my $format = $config->{format} // '';
    my $field = _temporal_expression($column->{field}, $column->{source_type} // $column->{type});
    return $field unless length($format) && $format ne 'default';
    if (my $kind = Selecto::Components::BucketParser->group_kind($format)) {
        $kind = 'numeric_ranges' if $format eq 'age_buckets'
            && ($column->{source_type} // $column->{type} // '') =~ /\A(?:integer|int|smallint|bigint|decimal|number|numeric|float|double|real)\z/i;
        my $specification = Selecto::Components::BucketParser->specification(
            $config->{bucket_ranges}, $kind
        );
        return Selecto::Expression->bucket($field, $specification);
    }
    if ($format eq 'text_prefix') {
        return Selecto::Expression->bucket($field, {
            kind => 'text_prefix',
            prefix_length => $config->{prefix_length} // 2,
            exclude_articles => $config->{exclude_articles} ? 1 : 0,
            ignore_case => 1,
        });
    }
    return Selecto::Expression->datetime_format($field, $format);
}

# How a bucketed group's labels are ordered where they are laid out side by
# side (the grid): ranges in the order they were given, and stepped buckets
# (*/10) by their lower bound. Text order would put 10-20 before 5-9.
sub _bucket_order ($config) {
    my $format = $config->{format} // '';
    my $kind = Selecto::Components::BucketParser->group_kind($format) or return ();
    my $specification = Selecto::Components::BucketParser->specification($config->{bucket_ranges}, $kind);
    return () unless ref($specification) eq 'HASH';
    return (bucket_order => 'lower_bound') unless ref($specification->{ranges}) eq 'ARRAY';
    my ($rank, %rank) = (0);
    for my $range (@{$specification->{ranges}}) {
        $rank{$range->{label}} //= $rank++ if defined $range->{label};
    }
    return (bucket_order => \%rank);
}

sub _group_natural_order_expression ($column, $config) {
    my $format = $config->{format} // '';
    my $field = _temporal_expression(
        $column->{field}, $column->{source_type} // $column->{type},
    );
    # Rank the same ranges used by the label expression, preserving first-match
    # semantics for overlapping ranges. The SQL key also orders paged results.
    if (my $kind = Selecto::Components::BucketParser->group_kind($format)) {
        $kind = 'numeric_ranges' if $format eq 'age_buckets'
            && ($column->{source_type} // $column->{type} // '') =~ /\A(?:integer|int|smallint|bigint|decimal|number|numeric|float|double|real)\z/i;
        my $specification = Selecto::Components::BucketParser->specification($config->{bucket_ranges}, $kind);
        return undef unless $specification;
        # For stepped numeric/year buckets MIN(source) has exactly the order
        # of the lower bounds, including negative numeric buckets. It avoids
        # parsing display labels or adding dialect SQL to Components.
        return $field unless ref($specification->{ranges}) eq 'ARRAY';
        my $rank = 0;
        return Selecto::Expression->bucket($field, {%$specification,
            ranges => [map { {%$_, label => sprintf('%04d', $rank++)} } @{$specification->{ranges}}]});
    }
    return undef unless $format eq 'day_of_week';
    return Selecto::Expression->datetime_format($field, 'day_of_week_num');
}

sub _temporal_expression ($field, $type) {
    return Selecto::Expression->epoch_datetime($field)
        if defined($type) && !ref($type) && lc("$type") eq 'epoch_datetime';
    return Selecto::Expression->field($field);
}

sub _with_filters ($query, $state, $config, $domain) {
    my @expressions;
    my %clause_expressions;
    my @clause_order;
    my $field_map = $config->filter_map($domain, $state->retarget);
    for my $filter (@{$state->filters}) {
        my ($field, $op, $value, $value_end) = @{$filter}{qw(field op value value_end)};
        next if $filter->{draft};
        my $type = $field_map->{$field}{type};
        my $catalog_field = $field_map->{$field};
        my $expression;
        if (ref($catalog_field->{conditional}) eq 'HASH') {
            my $conditional = $catalog_field->{conditional};
            my $when = Selecto::Expression->field($conditional->{when_field});
            my $present = _filter_expression(
                Selecto::Expression->field($conditional->{present_field}),
                $op, $value, $value_end, $filter->{values},
            );
            my $absent = _filter_expression(
                Selecto::Expression->field($conditional->{absent_field}),
                $op, $value, $value_end, $filter->{values},
            );
            $expression = Selecto::Expression->any([
                Selecto::Expression->all([
                    Selecto::Expression->not_null($when), $present,
                ]),
                Selecto::Expression->all([
                    Selecto::Expression->is_null($when), $absent,
                ]),
            ]);
        } else {
            my $operand = $filter->{grouped}
                ? _group_expression({field => $field, type => $type}, $state->group_configs->{$field} // {})
                : _temporal_expression($field, $type);
            $expression = _filter_expression($operand, $op, $value, $value_end, $filter->{values});
        }
        if (defined($filter->{clause})) {
            push @clause_order, $filter->{clause}
                unless exists($clause_expressions{$filter->{clause}});
            push @{$clause_expressions{$filter->{clause}}}, $expression;
        } else {
            push @expressions, $expression;
        }
    }
    if (@clause_order) {
        my @alternatives = map {
            my $items = $clause_expressions{$_};
            @$items == 1 ? $items->[0] : Selecto::Expression->all($items)
        } @clause_order;
        push @expressions, @alternatives == 1
            ? $alternatives[0] : Selecto::Expression->any(\@alternatives);
    }
    if ($state->view ne 'detail') {
        # A group that leaves out rows with no value filters them out, so
        # subtotals and totals leave them out as well.
        my $group_map = $config->field_map($domain, $state->retarget);
        push @expressions, map {
            my $type = ($group_map->{$_->{field}} // {})->{type};
            $_->{grouped}
                ? Selecto::Expression->ne(_group_expression({field => $_->{field}, type => $type},
                    $state->group_configs->{$_->{field}} // {}), $_->{value})
                : Selecto::Expression->not_null(_temporal_expression($_->{field}, $type))
        } @{$state->group_filters($group_map)};
    }
    return $query unless @expressions;
    return $query->where(@expressions == 1 ? $expressions[0] : Selecto::Expression->all(\@expressions));
}

sub _filter_expression ($operand, $op, $value, $value_end, $membership_values = undef) {
    if ($op eq 'in') {
        my @values = ref($membership_values) eq 'ARRAY'
            ? @$membership_values
            : grep { length } map { _trim($_) } split /,/, $value;
        return Selecto::Expression->in($operand, \@values);
    }
    if ($op eq 'not_in') {
        my @values = ref($membership_values) eq 'ARRAY'
            ? @$membership_values
            : grep { length } map { _trim($_) } split /,/, $value;
        return Selecto::Expression->not(Selecto::Expression->in($operand, \@values));
    }
    return Selecto::Expression->between($operand, $value, $value_end)
        if $op eq 'between';
    if ($op eq 'date_shortcut') {
        return Selecto::Components::DateShortcut->expression($operand, $value);
    }
    return Selecto::Expression->can($op)->('Selecto::Expression', $operand)
        if $op eq 'is_null' || $op eq 'not_null';
    return Selecto::Expression->can($op)->('Selecto::Expression', $operand, $value);
}

sub _with_query_library ($query, $domain, $state, $limits) {
    my @segments;
    push @segments, @{Selecto::QueryLibrary->view_segments(
        $domain, $state->query_library_view,
    )} if defined($state->query_library_view) && length($state->query_library_view);
    push @segments, @{$state->query_library_segments // []};
    my %seen;
    @segments = grep { !$seen{$_}++ } @segments;

    return Selecto::QueryLibrary->apply_segments(
        $domain,
        $query,
        \@segments,
        $state->query_library_parameters // {}, $limits,
    );
}

sub _field_alias ($field) {
    my $alias = "$field";
    $alias =~ s/[^A-Za-z0-9_]+/__/g;
    return $alias;
}

sub _trim ($value) { return trim($value); }

sub _humanize ($value) { return humanize($value); }

1;

__END__

=head1 NAME

Selecto::Components::QueryBuilder - Build the Selecto query for a validated Explorer state

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
