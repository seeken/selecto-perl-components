package Selecto::Components::APIHandoff;

use Mojo::Base -strict, -signatures;
use JSON::PP ();
use Selecto::Components::BucketParser ();
use Selecto::Components::Canonical ();
use Selecto::QueryLibrary ();

# Build only from the validated state and the query actually used for the
# results. In particular, SQLite's plain grouping must not become a rollup,
# and a grid's cube/sets must not become an ordinary summary.
sub aggregate ($class, $model, $controller) {
    my $config = $model->{config};
    return _disabled('Canonical Explorer routes are not enabled for this Explorer.')
        unless $config->canonical_api_path && $config->canonical_explorer;
    my $result = eval { $class->_aggregate($model, $controller) };
    return $result if $result;
    # Host callbacks and private validation errors never become HTML titles.
    return _disabled('Canonical Explorer metadata or query validation is unavailable.');
}

sub _aggregate ($class, $model, $controller) {
    my ($config, $state, $engine, $built) = @{$model}{qw(config state engine result)};
    return _disabled('The aggregate query must have valid results before opening the API console.')
        unless $state->valid && $engine && $built;
    return _disabled('The aggregate grid exceeds the Explorer result limits.') if $built->{grid_limit_exceeded};
    return _disabled('As of is not supported by the canonical Explorer query route.') if defined $state->as_of;
    return _disabled('Retargeted aggregates are not supported by the canonical Explorer query route.')
        if defined $state->retarget;
    return _disabled('Summary pivots require multiple queries and cannot be handed to the API console.') if $built->{pivot};
    return _disabled('Relative date filters use a different clock in the canonical Explorer query route.')
        if grep { !$_->{draft} && $_->{op} eq 'date_shortcut' } @{$state->filters};

    my $authorized = $config->canonical_authorizer->($controller);
    return _disabled('Canonical Explorer access is not authorized for this request.')
        unless defined($authorized) && !ref($authorized) && "$authorized" eq '1';
    my $publication = $config->canonical_publication->($controller, $engine);
    return _disabled('Canonical Explorer publication metadata is unavailable.')
        unless defined($publication) && !ref($publication) && length($publication) && length($publication) <= 4096;
    my $host = Selecto::Components::Canonical::_explorer($config, $config, $engine, $publication, $controller);
    my $features = $host->features($engine);
    return _disabled('Aggregates are disabled by the canonical Explorer host.') unless $features->{supports}{aggregate};
    my %fields = map { ($_->{id} => $_) } @{$features->{fields}};
    my (@groups, @select, %names, %order_ids);
    my $field_map = $config->field_map($engine->domain);
    for my $column (grep { !$_->{measure} } @{$built->{columns}}) {
        my $id = $column->{field};
        my $gc = $state->group_configs->{$id} // {};
        my $field = $column->{source_field} // $id;
        return _disabled('Dimension, selected-value, and custom-order groups cannot be handed to the API console.')
            if $column->{dimension} || $column->{pivot_values} || $column->{value_order};
        return _disabled('A grouping field is not published as groupable by the canonical Explorer host.')
            unless $fields{$field} && $fields{$field}{groupable};
        my $format = $gc->{format} // '';
        my $alias = $gc->{alias} // '';
        if (length($format) && $format ne 'default') {
            my $buckets = _buckets($format, $gc->{bucket_ranges}, $fields{$field}{type});
            return _disabled("The group format '$format' cannot be handed to the API console.")
                unless $buckets || grep { $_ eq $format } @{$fields{$field}{group_formats}};
            $alias = $column->{key} unless length $alias;
            push @groups, {field => $field, alias => $alias,
                ($buckets ? (buckets => $buckets) : (format => $format))};
            push @select, {group => $alias};
        } else {
            return _disabled('Aliases on unformatted groups are not supported by the canonical Explorer query route.')
                if length $alias;
            $alias = $field;
            push @groups, $field;
            push @select, $field;
        }
        return _disabled('Group and measure aliases must be unique API identifiers of at most 63 characters.')
            if $names{$alias}++ || (ref($groups[-1]) && !_alias($alias));
        $order_ids{$id} = $alias;
    }
    my @measures = grep { $_->{measure} } @{$built->{columns}};
    return _disabled('Expanded measures cannot be handed to the API console.') if @measures != @{$state->measures};
    for my $index (0 .. $#measures) {
        my $column = $measures[$index];
        my $mc = $state->measure_config_list->[$index] // {};
        my $function = $column->{function};
        my $field = $column->{field};
        return _disabled('Measure transforms cannot be handed to the API console.') if @{$mc->{transforms} // []};
        my $allowed = defined($field)
            ? ($fields{$field} && grep { $_ eq $function } @{$fields{$field}{aggregates}})
            : $function eq 'count';
        return _disabled("The measure function '$function' is not published by the canonical Explorer host.") unless $allowed;
        my $alias = length($mc->{alias} // '') ? $mc->{alias} : $column->{key};
        return _disabled('Group and measure aliases must be unique API identifiers of at most 63 characters.')
            if !_alias($alias) || $names{$alias}++;
        push @select, {aggregate => $function, alias => $alias,
            (defined($field) ? (field => $field) : ()),
            ($function eq 'sum' && $mc->{ignore_nulls} ? (ignore_nulls => 'auto') : ())};
        $order_ids{'measure:' . $state->measures->[$index]} //= $alias;
    }

    my (@filters, %clauses, @clauses);
    for my $filter (grep { !$_->{draft} } @{$state->filters}) {
        return _disabled('Conditional filters cannot be handed to the API console.')
            if $field_map->{$filter->{field}}{conditional};
        my $entry = {field => $filter->{field}, op => $filter->{op}};
        my $field = $fields{$filter->{field}};
        return _disabled('A filter field is not published by the canonical Explorer host.') unless $field;
        if ($filter->{grouped}) {
            my $id = $filter->{grouped} eq '1' ? $filter->{field} : $filter->{grouped};
            my $format = ($state->group_configs->{$id} // {})->{format} // '';
            return _disabled('This grouped filter cannot be handed to the API console.')
                unless ($filter->{op} eq 'eq' || $filter->{op} eq 'is_null')
                    && grep { $_ eq $format } @{$field->{group_formats}};
            $entry->{format} = $format;
        }
        unless ($filter->{op} =~ /\A(?:is_null|not_null)\z/) {
            $entry->{value} = $filter->{op} =~ /\A(?:in|not_in)\z/
                ? [map { _value($field, $_) } @{$filter->{values} // [map {
                    s/^\s+|\s+$//gr
                } grep { /\S/ } split /,/, $filter->{value}]}]
                : $filter->{grouped} ? $filter->{value} : _value($field, $filter->{value});
        }
        $entry->{end} = _value($field, $filter->{value_end}) if $filter->{op} eq 'between';
        if (defined $filter->{clause}) {
            push @clauses, $filter->{clause} unless exists $clauses{$filter->{clause}};
            push @{$clauses{$filter->{clause}}}, $entry;
        } else { push @filters, $entry }
    }
    push @filters, {any => [map { {all => $clauses{$_}} } @clauses]} if @clauses;
    # These exclusions also affect every subtotal, not merely its label.
    for my $filter (@{$state->group_filters($field_map)}) {
        if ($filter->{grouped}) {
            my $gc = $state->group_configs->{$filter->{from_group}} // {};
            my $field = $fields{$filter->{field}};
            my $buckets = $field ? _buckets($gc->{format}, $gc->{bucket_ranges}, $field->{type}) : undef;
            return _disabled('Grouped missing-value exclusions cannot be handed to the API console.')
                unless $buckets && $buckets->{ranges};
            my @ranges;
            for my $range (@{$buckets->{ranges}}) {
                my $bounds = $host->_range_bounds({zone => 'UTC'}, $field, $buckets->{kind}, $range->{min}, $range->{max});
                push @ranges, {all => [map {
                    my $value = $_->[1];
                    $value .= ' 00:00:00' if $field->{type} eq 'naive_datetime';
                    {field => $filter->{field}, op => $_->[0], value => _value($field, $value)}
                } @$bounds]};
            }
            push @filters, {any => \@ranges};
        } else { push @filters, {field => $filter->{field}, op => 'not_null'} }
    }
    my @segments = @{$state->query_library_segments // []};
    unshift @segments, @{Selecto::QueryLibrary->view_segments($engine->domain, $state->query_library_view)}
        if length($state->query_library_view // '');
    my %seen;
    @segments = grep { !$seen{$_}++ } @segments;
    my $query = {group_by => \@groups, select => \@select,
        (@filters ? (filters => \@filters) : ()),
        (@segments ? (segments => \@segments) : ()),
        (keys %{$state->query_library_parameters // {}} ? (parameters => {%{$state->query_library_parameters}}) : ()),
        row_format => 'arrays', limit => 0 + $state->limit, offset => ($state->page - 1) * $state->limit};
    my $mode = $built->{query}->grouping_mode;
    if ($mode eq 'rollup' || $mode eq 'cube' || $mode eq 'grouping_sets') {
        return _disabled("The canonical Explorer host does not support $mode.") unless $features->{supports}{$mode};
        if ($mode eq 'grouping_sets') { $query->{grouping_sets} = [map { [@$_] } @{$built->{query}->grouping_sets}] }
        else { $query->{$mode} = JSON::PP::true }
        return _disabled('Subtotal pagination uses a different row order in the canonical Explorer query route.')
            if !$built->{aggregate_grid} && ($state->page > 1 || $built->{has_more});
    }
    my @orders;
    for my $order (@{$state->orders}) {
        next unless $order->{field} =~ /\Ameasure:/; # Aggregate builder orders the other groups naturally.
        return _disabled('Custom ordering with subtotals is not supported by the canonical Explorer query route.')
            if $mode ne 'plain';
        return _disabled('This aggregate ordering cannot be handed to the API console.') unless $order_ids{$order->{field}};
        push @orders, {field => $order_ids{$order->{field}}, direction => $order->{direction}};
    }
    $query->{order_by} = \@orders if @orders;
    if ($built->{aggregate_grid}) {
        # A native grid reads all its cells rather than the selected page.
        return _disabled('The complete grid exceeds the canonical Explorer page limit.')
            if $built->{count} > $features->{limits}{max_limit};
        $query->{limit} = 0 + $built->{count};
        $query->{offset} = 0;
    }
    return _disabled('The aggregate page limit or offset exceeds the canonical Explorer limits.')
        if $query->{limit} > $features->{limits}{max_limit} || $query->{offset} > $features->{limits}{max_offset};
    # There is no public plan-only entry point in Selecto::API::Explorer. Reuse
    # its exact pre-execution checks instead of maintaining a second validator
    # or running a database query merely to render a link.
    my $accepted = eval {
        $engine->assert_tenant_boundary(access => 'read');
        my $contract = $engine->domain->contract // {};
        die 'required query contract' if grep { @{$contract->{$_} // []} }
            qw(required_selected required_group_by required_order_by);
        my $context = {engine => $engine, features => $features, supports => $host->_supports($engine),
            catalogue => $host->_catalogue($engine->domain, $host->_supports($engine)), limits => $host->limits};
        $host->_check_supports($context, $query);
        $host->_field_prepass($context, $query);
        $host->_check_conversions($context, $query);
        $host->_plan($context, $query);
        1;
    };
    return _disabled('The aggregate exceeds canonical Explorer capabilities, query rules, or limits.') unless $accepted;
    return {payload => {format => 'selecto.explorer-query', format_version => 1,
        domain => {fingerprint => $features->{domain}{fingerprint}}, features => {revision => $features->{revision}},
        query => $query}};
}

sub _alias ($value) { return $value =~ /\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/ }
sub _buckets ($format, $ranges, $type) {
    # Relative/month buckets use the native read clock, while the wire host
    # resolves them using its own trusted clock. Only clock-free kinds map.
    my $numeric = $type eq 'integer' || $type eq 'decimal';
    my $kind = $format eq 'buckets' || ($format eq 'age_buckets' && $numeric) ? 'numeric'
        : $format eq 'year_buckets' ? 'year' : return undef;
    my $spec = Selecto::Components::BucketParser->specification($ranges, "${kind}_ranges") or return undef;
    return {kind => $kind, step => 0 + $spec->{increment}} if exists $spec->{increment};
    return {kind => $kind, ranges => [map {
        {label => $_->{label}, min => $_->{minimum}, max => $_->{maximum}}
    } @{$spec->{ranges}}]};
}
sub _value ($field, $value) {
    return JSON::PP::true if $field->{type} eq 'boolean' && "$value" =~ /\A(?:1|true|yes)\z/i;
    return JSON::PP::false if $field->{type} eq 'boolean' && "$value" =~ /\A(?:0|false|no)\z/i;
    return 0 + $value if $field->{type} eq 'integer';
    return "$value";
}
sub _disabled ($reason) { return {reason => $reason} }

1;

__END__

=head1 NAME

Selecto::Components::APIHandoff - Aggregate console requests from validated Explorer results

=head1 DESCRIPTION

Internal translation for the API button. Uses the canonical Explorer host's
features and validation without executing a second query. Unsupported states
return a plain-text reason for the disabled control.

=cut
