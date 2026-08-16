package Selecto::Components::State;

use Mojo::Base -base, -signatures;
use Selecto::Components::DateShortcut ();

has [qw(view fields field_configs filters groups group_configs measure orders order direction limit page errors)];

sub parameter_names ($class) {
    return [qw(
        q view field field_alias field_format filter_field filter_op filter_value filter_value_end
        group group_alias group_format measure order direction limit page
    )];
}

sub from_input ($class, $config, $domain, $input) {
    $input = {} unless ref($input) eq 'HASH';
    $config->validate_domain($domain);
    my $field_map = $config->field_map($domain);
    my @errors;
    my $configured = _first($input, 'q') ? 1 : 0;

    my $view = _first($input, 'view') // $config->default_view;
    if (!$config->allows_view($view)) {
        push @errors, 'Choose an available view.';
        $view = $config->default_view;
    }

    my $field_values = _values($input, 'field');
    my $field_aliases = _values($input, 'field_alias');
    my $field_formats = _values($input, 'field_format');
    $field_values = [@{$config->resolved_default_fields($domain)}]
        if !$configured && !grep { length(_scalar($_)) } @$field_values;
    my @valid_fields;
    my %field_configs;
    my %seen_field;
    for my $index (0 .. $#$field_values) {
        my $field = _scalar($field_values->[$index]);
        next unless length($field) && !$seen_field{$field}++;
        unless ($field_map->{$field}) {
            push @errors, 'A selected detail field is not available.';
            next;
        }
        my $alias = _trim($field_aliases->[$index]);
        if (length($alias) > 80 || $alias =~ /[\x00-\x1f\x7f]/) {
            push @errors, 'A selected column alias is not available.';
            $alias = '';
        }
        my $format = _scalar($field_formats->[$index]);
        if (!$config->allows_date_format($format)
            || (length($format) && !$config->temporal_type($field_map->{$field}{type}))) {
            push @errors, 'A selected column format is not available.';
            $format = '';
        }
        push @valid_fields, $field;
        $field_configs{$field} = { alias => $alias, format => $format };
    }
    push @errors, 'Choose at least one detail field.' unless @valid_fields;
    unless (@valid_fields) {
        @valid_fields = @{$config->resolved_default_fields($domain)};
        %field_configs = map { $_ => { alias => '', format => '' } } @valid_fields;
    }

    my $group_values = _values($input, 'group');
    my $group_aliases = _values($input, 'group_alias');
    my $group_formats = _values($input, 'group_format');
    $group_values = [@{$config->resolved_default_group($domain)}]
        if !$configured && !grep { length(_scalar($_)) } @$group_values;
    my @valid_groups;
    my %group_configs;
    my %seen_group;
    for my $index (0 .. $#$group_values) {
        my $group = _scalar($group_values->[$index]);
        next unless length($group) && !$seen_group{$group}++;
        if (!$field_map->{$group}) {
            push @errors, 'A selected group field is not available.';
        } elsif (@valid_groups >= 3) {
            push @errors, 'Choose no more than three group fields.';
        } else {
            my $alias = _trim($group_aliases->[$index]);
            if (length($alias) > 80 || $alias =~ /[\x00-\x1f\x7f]/) {
                push @errors, 'A group column alias is not available.';
                $alias = '';
            }
            my $format = _scalar($group_formats->[$index]);
            if (!$config->allows_date_format($format)
                || (length($format) && !$config->temporal_type($field_map->{$group}{type}))) {
                push @errors, 'A group column format is not available.';
                $format = '';
            }
            push @valid_groups, $group;
            $group_configs{$group} = { alias => $alias, format => $format };
        }
    }
    if (($view eq 'aggregate' || $view eq 'graph') && !@valid_groups) {
        push @errors, 'Choose at least one group field.';
        @valid_groups = @{$config->resolved_default_group($domain)};
        %group_configs = map { $_ => { alias => '', format => '' } } @valid_groups;
    }

    my $measure = _first($input, 'measure') // $config->measures->[0]{id};
    unless ($config->measure($measure)) {
        push @errors, 'Choose an available measure.';
        $measure = $config->measures->[0]{id};
    }

    my $order_fields = _values($input, 'order');
    my $order_directions = _values($input, 'direction');
    $order_fields = [$valid_fields[0]] unless grep { length(_scalar($_)) } @$order_fields;
    my @orders;
    my %seen_order;
    for my $index (0 .. $#$order_fields) {
        my $field = _scalar($order_fields->[$index]);
        next unless length($field);
        if (@orders >= $config->max_orders) {
            push @errors, 'Too many sort fields were submitted.';
            last;
        }
        unless ($field_map->{$field}) {
            push @errors, 'Choose an available sort field.';
            next;
        }
        if ($seen_order{$field}++) {
            push @errors, 'A sort field can be set only once.';
            next;
        }
        my $dir = lc(_scalar($order_directions->[$index]) || 'asc');
        unless ($dir eq 'asc' || $dir eq 'desc') {
            push @errors, 'Sort direction must be ascending or descending.';
            $dir = 'asc';
        }
        push @orders, { field => $field, direction => $dir };
    }
    @orders = ({ field => $valid_fields[0], direction => 'asc' }) unless @orders;
    my $order = $orders[0]{field};
    my $direction = $orders[0]{direction};

    my $limit_input = _first($input, 'limit');
    push @errors, 'Row limit must be a positive integer.'
        if defined($limit_input) && $limit_input !~ /\A[1-9]\d*\z/;
    my $limit = _positive_integer($limit_input, $config->default_limit);
    if ($limit > $config->max_limit) {
        push @errors, 'Row limit is above the configured maximum.';
        $limit = $config->max_limit;
    }
    my $page_input = _first($input, 'page');
    push @errors, 'Page must be a positive integer.'
        if defined($page_input) && $page_input !~ /\A[1-9]\d*\z/;
    my $page = _positive_integer($page_input, 1);
    if ($page > 100_000) {
        push @errors, 'Page is outside the supported range.';
        $page = 1;
    }

    my $filter_fields = _values($input, 'filter_field');
    my $filter_ops = _values($input, 'filter_op');
    my $filter_values = _values($input, 'filter_value');
    my $filter_end_values = _values($input, 'filter_value_end');
    my $filter_count = @$filter_fields;
    $filter_count = @$filter_ops if @$filter_ops > $filter_count;
    $filter_count = @$filter_values if @$filter_values > $filter_count;
    $filter_count = @$filter_end_values if @$filter_end_values > $filter_count;
    my @filters;
    my %seen_filter_field;
    for my $index (0 .. $filter_count - 1) {
        my $field = _scalar($filter_fields->[$index]);
        my $op = lc(_scalar($filter_ops->[$index]) || 'eq');
        my $value = _scalar($filter_values->[$index]);
        my $value_end = _scalar($filter_end_values->[$index]);
        next unless length($field) || length($value) || length($value_end);
        if (@filters >= $config->max_filters) {
            push @errors, 'Too many filters were submitted.';
            last;
        }
        unless ($field_map->{$field}) {
            push @errors, 'A filter field is not available.';
            next;
        }
        if ($seen_filter_field{$field}++) {
            push @errors, 'A filter field can be set only once.';
            next;
        }
        my $field_type = $field_map->{$field}{type};
        unless ($config->allows_filter_operator($field_type, $op)) {
            push @errors, 'A filter operator is not available.';
            next;
        }
        ($value, $value_end) = ('', '') if $op =~ /_null\z/;
        if ($op eq 'in' && length($value)
            && !grep { length } map { _trim($_) } split /,/, $value, -1) {
            push @errors, 'Membership filters require at least one value.';
            next;
        }
        if ($op eq 'date_shortcut' && length($value)
            && !Selecto::Components::DateShortcut->valid($value)) {
            push @errors, 'A date shortcut is not available.';
            next;
        }
        if ($config->temporal_type($field_type) && $op ne 'date_shortcut' && $op !~ /_null\z/) {
            if (length($value) && !_valid_temporal_value($value)) {
                push @errors, 'A date filter value is not available.';
                next;
            }
            if ($op eq 'between' && length($value_end) && !_valid_temporal_value($value_end)) {
                push @errors, 'A date filter end value is not available.';
                next;
            }
        }
        if ($config->boolean_type($field_type) && $op eq 'eq'
            && length($value) && $value !~ /\A(?:true|false|0|1)\z/i) {
            push @errors, 'A boolean filter value is not available.';
            next;
        }
        my $filter = {
            field => $field,
            op => $op,
            value => $value,
            value_end => $value_end,
        };
        $filter->{draft} = 1 if $op !~ /_null\z/
            && (!length($value) || ($op eq 'between' && !length($value_end)));
        push @filters, $filter;
    }

    return $class->new(
        view => $view,
        fields => \@valid_fields,
        field_configs => \%field_configs,
        filters => \@filters,
        groups => \@valid_groups,
        group_configs => \%group_configs,
        measure => $measure,
        orders => \@orders,
        order => $order,
        direction => $direction,
        limit => $limit,
        page => $page,
        errors => \@errors,
    );
}

sub valid ($self) { return @{$self->errors} ? 0 : 1; }

sub query_pairs ($self) {
    my @pairs = (q => 1, view => $self->view);
    for my $field (@{$self->fields}) {
        my $column = $self->field_configs->{$field} // {};
        push @pairs,
            field => $field,
            field_alias => $column->{alias} // '',
            field_format => $column->{format} // '';
    }
    for my $filter (@{$self->filters}) {
        push @pairs,
            filter_field => $filter->{field},
            filter_op => $filter->{op},
            filter_value => $filter->{value},
            filter_value_end => $filter->{value_end} // '';
    }
    for my $group (@{$self->groups}) {
        my $column = $self->group_configs->{$group} // {};
        push @pairs,
            group => $group,
            group_alias => $column->{alias} // '',
            group_format => $column->{format} // '';
    }
    push @pairs, measure => $self->measure;
    for my $order (@{$self->orders}) {
        push @pairs, order => $order->{field}, direction => $order->{direction};
    }
    push @pairs,
        limit => $self->limit,
        page => $self->page;
    return \@pairs;
}

sub as_hash ($self) {
    return {
        view => $self->view,
        fields => [@{$self->fields}],
        field_configs => { map { $_ => { %{$self->field_configs->{$_}} } } keys %{$self->field_configs} },
        filters => [map { { %$_ } } @{$self->filters}],
        groups => [@{$self->groups}],
        group_configs => { map { $_ => { %{$self->group_configs->{$_}} } } keys %{$self->group_configs} },
        measure => $self->measure,
        orders => [map { { %$_ } } @{$self->orders}],
        order => $self->order,
        direction => $self->direction,
        limit => $self->limit,
        page => $self->page,
    };
}

sub with_page ($self, $page) {
    return ref($self)->new(%{$self->as_hash}, page => $page, errors => [@{$self->errors}]);
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

sub _trim ($value) {
    $value = _scalar($value);
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

sub _valid_temporal_value ($value) {
    return 0 unless defined($value) && !ref($value)
        && "$value" =~ /\A(\d{4}-\d{2}-\d{2})(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)?\z/;
    return Selecto::Components::DateShortcut->valid_date($1);
}

1;
