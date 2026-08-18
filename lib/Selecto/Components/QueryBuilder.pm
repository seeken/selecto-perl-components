package Selecto::Components::QueryBuilder;

use Mojo::Base -base, -signatures;
use Selecto::Components::BucketParser ();
use Selecto::Components::DateShortcut ();
use Selecto::Expression ();

sub build ($class, $config, $domain, $state) {
    die "cannot build an invalid explorer state\n" unless $state->valid;
    return $state->view eq 'detail'
        ? $class->_detail($config, $domain, $state)
        : $class->_aggregate($config, $domain, $state);
}

sub _detail ($class, $config, $domain, $state) {
    my $field_map = $config->field_map($domain);
    my $detail_map = $config->detail_column_map($domain);
    my @columns = map {
        my $field = $_;
        my $catalog = $detail_map->{$field};
        if ($catalog->{action_id}) {
            +{
                key => '__selecto_action_column_' . $catalog->{action_id},
                field => $field,
                label => $catalog->{label},
                type => 'action',
                action_id => $catalog->{action_id},
            };
        } else {
            my $column_config = $state->field_configs->{$field} // {};
            +{
                key => _field_alias($field),
                field => $field,
                label => $column_config->{alias} || $field_map->{$field}{label},
                type => $column_config->{format} ? 'string' : $field_map->{$field}{type},
                format => $column_config->{format} // '',
                (defined($field_map->{$field}{link})
                    ? (link => {%{$field_map->{$field}{link}}}) : ()),
            };
        }
    } @{$state->fields};
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
        (!$_->{format} ? ($_->{field} => $_->{key}) : ())
    } @query_columns;
    my %used_key = map { $_->{key} => 1 } @query_columns;
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
        ->offset(($state->page - 1) * $state->limit);
    return {
        query => $query,
        columns => \@columns,
        query_columns => \@query_columns,
        action_key => $action_key,
        action_ids => \@action_ids,
        graph => 0,
    };
}

sub _aggregate ($class, $config, $domain, $state) {
    my $field_map = $config->field_map($domain);
    my @group_columns = map {
        my $field = $_;
        my $column_config = $state->group_configs->{$field} // {};
        {
            key => _field_alias($field),
            field => $field,
            label => $column_config->{alias} || $field_map->{$field}{label},
            type => $column_config->{format} ? 'string' : $field_map->{$field}{type},
            format => $column_config->{format} // '',
        }
    } @{$state->groups};
    my @groups = map { _group_expression($_, $state->group_configs->{$_->{field}} // {}) } @group_columns;
    my @selections = map { $groups[$_]->as($group_columns[$_]{key}) } 0 .. $#group_columns;
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
    my $rollup = $state->view eq 'aggregate' && @groups ? 1 : 0;
    my $rollup_key = '__selecto_rollup_grouping';
    push @selections, Selecto::Expression->grouping(\@groups)->as($rollup_key) if $rollup;
    my $query = Selecto::Query->new->select(@selections);
    $query = $rollup ? $query->group_by_rollup(\@groups) : $query->group_by(\@groups);
    $query = _with_filters($query, $state);
    $query = $query->order_by($_, 'asc') for @groups;
    $query = $query->limit($state->limit)
        ->offset(($state->page - 1) * $state->limit);
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

1;
