package Selecto::Components::QueryBuilder;

use Mojo::Base -base, -signatures;
use Selecto::Components::BucketParser ();
use Selecto::Components::DateShortcut ();
use Selecto::Expression ();
use Selecto::QueryLibrary ();

sub build ($class, $config, $domain, $state, $options = undef) {
    die "cannot build an invalid explorer state\n" unless $state->valid;
    $options //= {};
    die "query builder options must be an object\n" unless ref($options) eq 'HASH';
    return $state->view eq 'detail'
        ? $class->_detail($config, $domain, $state, $options)
        : $class->_aggregate($config, $domain, $state, $options);
}

sub _detail ($class, $config, $domain, $state, $options) {
    my $field_map = $config->field_map($domain);
    my $detail_map = $config->detail_column_map($domain);
    my (@columns, %nested_column);
    for my $field (@{$state->fields}) {
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
        my $resolved = $domain->resolve($field);
        if ($resolved->{association} && $resolved->{association}->cardinality eq 'many') {
            my $association = $resolved->{association};
            my $name = $association->name;
            my $nested = $nested_column{$name};
            unless ($nested) {
                $nested = {
                    key => '__selecto_nested_' . _field_alias($name),
                    field => $name,
                    label => _humanize($name),
                    type => 'nested',
                    nested => 1,
                    association => $name,
                    nested_fields => [],
                };
                $nested_column{$name} = $nested;
                push @columns, $nested;
            }
            my $column_config = $state->field_configs->{$field} // {};
            push @{$nested->{nested_fields}}, {
                field => $resolved->{field},
                path => $field,
                label => $column_config->{alias} || _humanize($resolved->{field}),
                type => $field_map->{$field}{type},
                (defined($field_map->{$field}{html_format})
                    ? (html_format => $field_map->{$field}{html_format}) : ()),
            };
            next;
        }
        my $column_config = $state->field_configs->{$field} // {};
        push @columns, {
            key => _field_alias($field),
            field => $field,
            label => $column_config->{alias} || $field_map->{$field}{label},
            type => $column_config->{format} ? 'string' : $field_map->{$field}{type},
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
        my $primary_key = $config->primary_key($domain);
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
    my %action_row_details;
    my $action_specs = $domain->actions;
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
    my $query = Selecto::Query->new->select(map {
        _column_expression($_)->as($_->{key})
    } @query_columns);
    $query = _with_filters($query, $state);
    for my $order (@{$state->orders}) {
        $query = $query->order_by($order->{field}, $order->{direction});
    }
    $query = $query->limit($state->limit)
        ->offset(($state->page - 1) * $state->limit)
        if !exists($options->{paginate}) || $options->{paginate};
    $query = _with_query_library($query, $domain, $state);
    return {
        query => $query,
        columns => \@columns,
        query_columns => \@query_columns,
        action_key => $action_key,
        action_ids => \@action_ids,
        action_row_details => \%action_row_details,
        count_selections => [Selecto::Expression->field($config->primary_key($domain))],
        graph => 0,
    };
}

sub _aggregate ($class, $config, $domain, $state, $options) {
    my $field_map = $config->field_map($domain);
    my $rollup = $state->view eq 'aggregate' && @{$state->groups} ? 1 : 0;
    my @group_columns = map {
        my $field = $_;
        my $column_config = $state->group_configs->{$field} // {};
        my $dimension = $field_map->{$field}{dimension};
        {
            key => _field_alias($field),
            field => $field,
            label => $column_config->{alias} || $field_map->{$field}{label},
            type => $dimension ? $dimension->{display_type}
                : $column_config->{format} ? 'string' : $field_map->{$field}{type},
            format => $column_config->{format} // '',
            (defined($field_map->{$field}{html_format})
                ? (html_format => $field_map->{$field}{html_format}) : ()),
            ($dimension ? (
                dimension => {%$dimension},
                drilldown_field => $dimension->{key_field},
                drilldown_key => '__selecto_dimension_key_' . _field_alias($field),
                drilldown_grouped => 0,
            ) : ()),
        }
    } @{$state->groups};
    my (@groups, @group_selections, @group_orders, @dimension_key_selections);
    for my $column (@group_columns) {
        if (my $dimension = $column->{dimension}) {
            my $key = Selecto::Expression->field($dimension->{key_field});
            my $display = $rollup
                ? Selecto::Expression->dimension_display(
                    $dimension->{display_field}, $dimension->{key_field}
                )
                : Selecto::Expression->min($dimension->{display_field});
            push @groups, $key;
            push @group_selections, $display->as($column->{key});
            push @group_orders, $display;
            push @dimension_key_selections, $key->as($column->{drilldown_key});
        } else {
            my $group = _group_expression(
                $column, $state->group_configs->{$column->{field}} // {}
            );
            push @groups, $group;
            push @group_selections, $group->as($column->{key});
            push @group_orders, $group;
        }
    }
    my @selections = @group_selections;
    my @measure_columns;
    for my $measure_id (@{$state->measures}) {
        my $measure = $config->measure($measure_id, $domain);
        my $measure_config = $state->measure_configs->{$measure_id} // {};
        my $function = $measure_config->{function} // $measure->{aggregate};
        my $alias = $measure_config->{alias} // '';
        my $measure_key = _measure_key($measure_id);
        if ($function eq 'buckets' || $function eq 'age_buckets') {
            my $ranges = Selecto::Components::BucketParser->parse($measure_config->{bucket_ranges});
            my $index = 0;
            for my $range (@$ranges) {
                next if !defined($range->{minimum}) && !defined($range->{maximum});
                next if defined($range->{minimum}) && $range->{minimum} !~ /\A\d+\z/;
                my $key = $measure_key . '__bucket_' . ++$index;
                my $label = _bucket_measure_label($range->{label}, $function, $alias, $index);
                my $expression = Selecto::Expression->count_bucket(
                    $measure->{field},
                    $range->{minimum},
                    $range->{maximum},
                    $function eq 'age_buckets' ? 'elapsed_days' : 'numeric',
                );
                push @measure_columns, {
                    key => $key, field => $measure->{field}, label => $label,
                    type => 'integer', measure => 1,
                };
                push @selections, $expression->as($key);
            }
            next;
        }
        my $expression = _measure_expression($measure, $measure_config);
        my $label = length($alias) ? $alias : _measure_label($measure, $function, $field_map);
        push @measure_columns, {
            key => $measure_key,
            field => $measure->{field},
            label => $label,
            type => $function =~ /\A(?:count|count_distinct|true_count|false_count)\z/
                ? 'integer' : $field_map->{$measure->{field}}{type},
            measure => 1,
        };
        push @selections, $expression->as($measure_key);
    }
    my @columns = (@group_columns, @measure_columns);
    push @selections, @dimension_key_selections;
    my $rollup_key = '__selecto_rollup_grouping';
    push @selections, Selecto::Expression->grouping(\@groups)->as($rollup_key) if $rollup;
    my $query = Selecto::Query->new->select(@selections);
    $query = $rollup ? $query->group_by_rollup(\@groups) : $query->group_by(\@groups);
    $query = _with_filters($query, $state);
    $query = $query->order_by($_, 'asc') for @group_orders;
    $query = $query->limit($state->limit)
        ->offset(($state->page - 1) * $state->limit)
        if !exists($options->{paginate}) || $options->{paginate};
    $query = _with_query_library($query, $domain, $state);
    return {
        query => $query,
        columns => \@columns,
        graph => $state->view eq 'graph' ? 1 : 0,
        rollup => $rollup,
        rollup_key => $rollup ? $rollup_key : undef,
        group_count => scalar(@groups),
    };
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
    );
    return $field_label . ' ' . ($labels{$function} // $function);
}

sub _measure_key ($measure_id) {
    return $measure_id if $measure_id =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
    return 'measure__' . _field_alias($measure_id);
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
    return $column->{format}
        ? Selecto::Expression->datetime_format($column->{field}, $column->{format})
        : Selecto::Expression->field($column->{field});
}

sub _group_expression ($column, $config) {
    my $format = $config->{format} // '';
    return Selecto::Expression->field($column->{field}) unless length($format) && $format ne 'default';
    if ($format eq 'buckets' || $format eq 'age_buckets'
        || $format eq 'custom_buckets' || $format eq 'year_buckets') {
        my $kind = $format eq 'buckets' ? 'numeric_ranges'
            : $format eq 'age_buckets' ? 'elapsed_days_ranges'
            : $format eq 'custom_buckets' ? 'date_relative_ranges' : 'year_ranges';
        my $specification = Selecto::Components::BucketParser->specification(
            $config->{bucket_ranges}, $kind
        );
        return Selecto::Expression->bucket($column->{field}, $specification);
    }
    if ($format eq 'text_prefix') {
        return Selecto::Expression->bucket($column->{field}, {
            kind => 'text_prefix',
            prefix_length => $config->{prefix_length} // 2,
            exclude_articles => $config->{exclude_articles} ? 1 : 0,
            ignore_case => 1,
        });
    }
    return Selecto::Expression->datetime_format($column->{field}, $format);
}

sub _with_filters ($query, $state) {
    my @expressions;
    for my $filter (@{$state->filters}) {
        my ($field, $op, $value, $value_end) = @{$filter}{qw(field op value value_end)};
        next if $filter->{draft};
        my $operand = $filter->{grouped}
            ? _group_expression({field => $field}, $state->group_configs->{$field} // {})
            : $field;
        my $expression;
        if ($op eq 'in') {
            my @values = grep { length } map { _trim($_) } split /,/, $value;
            $expression = Selecto::Expression->in($field, \@values);
        } elsif ($op eq 'between') {
            $expression = Selecto::Expression->between($field, $value, $value_end);
        } elsif ($op eq 'date_shortcut') {
            my ($start, $end) = Selecto::Components::DateShortcut->bounds($value);
            $expression = Selecto::Expression->all([
                Selecto::Expression->gte($field, $start),
                Selecto::Expression->lt($field, $end),
            ]);
        } elsif ($op eq 'is_null' || $op eq 'not_null') {
            $expression = Selecto::Expression->can($op)->('Selecto::Expression', $operand);
        } else {
            $expression = Selecto::Expression->can($op)->('Selecto::Expression', $operand, $value);
        }
        push @expressions, $expression;
    }
    return $query unless @expressions;
    return $query->where(@expressions == 1 ? $expressions[0] : Selecto::Expression->all(\@expressions));
}

sub _with_query_library ($query, $domain, $state) {
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
        $state->query_library_parameters // {},
    );
}

sub _field_alias ($field) {
    my $alias = "$field";
    $alias =~ s/[^A-Za-z0-9_]+/__/g;
    return $alias;
}

sub _trim ($value) {
    $value = "$value";
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

sub _humanize ($value) {
    my $text = "$value";
    $text =~ s/_/ /g;
    return join ' ', map { ucfirst lc $_ } split /\s+/, $text;
}

1;
