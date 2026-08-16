package Selecto::Components::QueryBuilder;

use Mojo::Base -base, -signatures;
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
    my @columns = map {
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
    my $measure = $config->measure($state->measure);
    my $expression = $measure->{aggregate} eq 'count'
        ? Selecto::Expression->count
        : Selecto::Expression->can($measure->{aggregate})->('Selecto::Expression', $measure->{field});
    push @columns, {
        key => $measure->{id},
        field => $measure->{field},
        label => $measure->{label},
        type => $measure->{aggregate} eq 'count' ? 'integer' : $field_map->{$measure->{field}}{type},
        measure => 1,
    };
    my @selections = (
        (map { _column_expression($_)->as($_->{key}) } @columns[0 .. $#columns - 1]),
        $expression->as($measure->{id}),
    );
    my @groups = map { _column_expression($_) } @columns[0 .. $#columns - 1];
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

sub _column_expression ($column) {
    return $column->{format}
        ? Selecto::Expression->datetime_format($column->{field}, $column->{format})
        : Selecto::Expression->field($column->{field});
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
