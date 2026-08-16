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
    my @columns = map {
        my $field = $_;
        my $column_config = $state->field_configs->{$field} // {};
        {
            key => _field_alias($field),
            field => $field,
            label => $column_config->{alias} || $field_map->{$field}{label},
            type => $column_config->{format} ? 'string' : $field_map->{$field}{type},
            format => $column_config->{format} // '',
        }
    } @{$state->fields};
    my $query = Selecto::Query->new->select(map {
        _column_expression($_)->as($_->{key})
    } @columns);
    $query = _with_filters($query, $state);
    for my $order (@{$state->orders}) {
        $query = $query->order_by($order->{field}, $order->{direction});
    }
    $query = $query->limit($state->limit)
        ->offset(($state->page - 1) * $state->limit);
    return { query => $query, columns => \@columns, graph => 0 };
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
        my $measure = $config->measure($measure_id);
        my $measure_config = $state->measure_configs->{$measure_id} // {};
        my $function = $measure_config->{function} // $measure->{aggregate};
        my $alias = $measure_config->{alias} // '';
        if ($function eq 'buckets' || $function eq 'age_buckets') {
            my $ranges = Selecto::Components::BucketParser->parse($measure_config->{bucket_ranges});
            my $index = 0;
            for my $range (@$ranges) {
                next if !defined($range->{minimum}) && !defined($range->{maximum});
                next if defined($range->{minimum}) && $range->{minimum} !~ /\A\d+\z/;
                my $key = $measure_id . '__bucket_' . ++$index;
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
            key => $measure_id,
            field => $measure->{field},
            label => $label,
            type => $function =~ /\A(?:count|count_distinct|true_count|false_count)\z/
                ? 'integer' : $field_map->{$measure->{field}}{type},
            measure => 1,
        };
        push @selections, $expression->as($measure_id);
    }
    my @columns = (@group_columns, @measure_columns);
    my $query = Selecto::Query->new
        ->select(@selections)
        ->group_by(\@groups);
    $query = _with_filters($query, $state);
    $query = $query
        ->order_by($groups[0], 'asc')
        ->limit($state->limit)
        ->offset(($state->page - 1) * $state->limit);
    return { query => $query, columns => \@columns, graph => $state->view eq 'graph' ? 1 : 0 };
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
    return $measure->{label} if $function eq $measure->{aggregate};
    my $field_label = defined($measure->{field})
        ? $field_map->{$measure->{field}}{label} : 'Rows';
    my %labels = (
        count => 'Count', count_distinct => 'Count distinct', avg => 'Average', sum => 'Sum',
        min => 'Minimum', max => 'Maximum', true_count => 'True count', false_count => 'False count',
    );
    return $field_label . ' ' . ($labels{$function} // $function);
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
            $expression = Selecto::Expression->can($op)->('Selecto::Expression', $field);
        } else {
            $expression = Selecto::Expression->can($op)->('Selecto::Expression', $field, $value);
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
