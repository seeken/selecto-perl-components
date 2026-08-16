package Selecto::Components::State;

use Mojo::Base -base, -signatures;

has [qw(view fields filters groups measure order direction limit page errors)];

sub parameter_names ($class) {
    return [qw(q view field filter_field filter_op filter_value group measure order direction limit page)];
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

    my @fields = _unique(grep { length } map { _scalar($_) } @{_values($input, 'field')});
    @fields = @{$config->resolved_default_fields($domain)} if !$configured && !@fields;
    my @valid_fields;
    for my $field (@fields) {
        if ($field_map->{$field}) {
            push @valid_fields, $field;
        } else {
            push @errors, 'A selected detail field is not available.';
        }
    }
    push @errors, 'Choose at least one detail field.' unless @valid_fields;
    @valid_fields = @{$config->resolved_default_fields($domain)} unless @valid_fields;

    my @groups = _unique(grep { length } map { _scalar($_) } @{_values($input, 'group')});
    @groups = @{$config->resolved_default_group($domain)} if !$configured && !@groups;
    my @valid_groups;
    for my $group (@groups) {
        if (!$field_map->{$group}) {
            push @errors, 'A selected group field is not available.';
        } elsif (@valid_groups >= 3) {
            push @errors, 'Choose no more than three group fields.';
        } else {
            push @valid_groups, $group;
        }
    }
    if (($view eq 'aggregate' || $view eq 'graph') && !@valid_groups) {
        push @errors, 'Choose at least one group field.';
        @valid_groups = @{$config->resolved_default_group($domain)};
    }

    my $measure = _first($input, 'measure') // $config->measures->[0]{id};
    unless ($config->measure($measure)) {
        push @errors, 'Choose an available measure.';
        $measure = $config->measures->[0]{id};
    }

    my $order = _first($input, 'order') // $valid_fields[0];
    unless (defined($order) && $field_map->{$order}) {
        push @errors, 'Choose an available sort field.';
        $order = $valid_fields[0];
    }
    my $direction = lc(_first($input, 'direction') // 'asc');
    unless ($direction eq 'asc' || $direction eq 'desc') {
        push @errors, 'Sort direction must be ascending or descending.';
        $direction = 'asc';
    }

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
    my $filter_count = @$filter_fields;
    $filter_count = @$filter_ops if @$filter_ops > $filter_count;
    $filter_count = @$filter_values if @$filter_values > $filter_count;
    my @filters;
    my %seen_filter_field;
    for my $index (0 .. $filter_count - 1) {
        my $field = _scalar($filter_fields->[$index]);
        my $op = lc(_scalar($filter_ops->[$index]) || 'eq');
        my $value = _scalar($filter_values->[$index]);
        next unless length($field) || length($value);
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
        unless ($op =~ /\A(?:eq|gt|gte|in|is_null|not_null)\z/) {
            push @errors, 'A filter operator is not available.';
            next;
        }
        $value = '' if $op =~ /_null\z/;
        if ($op eq 'in' && length($value)
            && !grep { length } map { _trim($_) } split /,/, $value, -1) {
            push @errors, 'Membership filters require at least one value.';
            next;
        }
        my $filter = {
            field => $field,
            op => $op,
            value => $value,
        };
        $filter->{draft} = 1 if $op !~ /_null\z/ && !length($value);
        push @filters, $filter;
    }

    return $class->new(
        view => $view,
        fields => \@valid_fields,
        filters => \@filters,
        groups => \@valid_groups,
        measure => $measure,
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
    push @pairs, map { (field => $_) } @{$self->fields};
    for my $filter (@{$self->filters}) {
        push @pairs,
            filter_field => $filter->{field},
            filter_op => $filter->{op},
            filter_value => $filter->{value};
    }
    push @pairs, map { (group => $_) } @{$self->groups};
    push @pairs,
        measure => $self->measure,
        order => $self->order,
        direction => $self->direction,
        limit => $self->limit,
        page => $self->page;
    return \@pairs;
}

sub as_hash ($self) {
    return {
        view => $self->view,
        fields => [@{$self->fields}],
        filters => [map { { %$_ } } @{$self->filters}],
        groups => [@{$self->groups}],
        measure => $self->measure,
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

1;
