package Selecto::Components::SavedView;

use Mojo::Base -base, -signatures;
use Mojo::URL ();
use Scalar::Util qw(blessed);
use Selecto::Components::State ();
use Selecto::Components::QueryBuilder ();
use Selecto::Components::Explorer ();
use Selecto::Components::InputBudget ();

# Both entry points use the request-local config and engine, just like a page
# load. No query is executed: compilation applies the engine's read policy.
sub check ($class, $config, $context, $value) {
    my $parsed = $class->_parse($config, $context, $value);
    return {ok => 0, errors => $parsed->{errors}} if @{$parsed->{errors}};
    return {ok => 1, url => $parsed->{url}, state => $parsed->{state}->as_hash};
}

sub explain ($class, $config, $context, $value) {
    if (!ref($value)) {
        my $url = Mojo::URL->new($value // '');
        return {kind => 'not_an_explorer_view', path => $url->path->to_string}
            unless _local_view($config, $url);
    }
    my $parsed = $class->_parse($config, $context, $value);
    return {kind => 'invalid_explorer_view', errors => $parsed->{errors}}
        unless $parsed->{state};
    my ($state, $domain, $request_config) = @{$parsed}{qw(state domain config)};
    my $map = $request_config->field_map($domain, $state->grain);
    my $detail = $request_config->detail_column_map($domain, undef, $state->grain);
    my $omitted = $parsed->{omitted};
    my $label = sub ($field) { return ($map->{$field} // $detail->{$field} // {})->{label} // $field };
    my $data = $state->as_hash;
    if ($parsed->{all_fields_omitted}) {
        $data->{fields} = []; $data->{field_configs} = {}; $data->{field_config_list} = [];
    }
    # State supplies defaults when no readable detail columns remain. Explain
    # describes only the original readable selection, never invented defaults.
    my @fields;
    for my $i (0 .. $#{$state->fields}) {
        my $field = $state->fields->[$i];
        next unless $detail->{$field};
        push @fields, {field => $field, label => $label->($field),
            %{$state->field_config_list->[$i] // {}}};
    }
    @fields = () if $parsed->{all_fields_omitted};
    my @groups = map { my $g = $state->group_configs->{$_};
        +{id => $_, %$g, label => $label->($g->{field} // $_)} } @{$state->groups};
    my @measures = map {
        my $id = $_;
        my $definition = $request_config->measure($id, $domain, $state->grain) // {};
        +{id => $id, %{$state->measure_configs->{$id}},
            (defined($definition->{field}) ? (field => $definition->{field}) : ()),
            label => $definition->{label} // $label->($id)};
    } @{$state->measures};
    my @filters = map { +{%$_, label => $label->($_->{field})} } @{$state->filters};
    my @sort = map {
        my $field = $_->{field};
        $field =~ s/\Ameasure://;
        +{%$_, label => $label->($field)};
    } @{$state->orders};
    return {kind => 'explorer_view', url => $parsed->{url}, state => $data,
        view => $state->view, fields => \@fields, groups => \@groups,
        measures => \@measures, filters => \@filters, sort => \@sort,
        period => $state->as_of, page_size => $state->limit,
        omitted_fields => $omitted,
        errors => [grep { !defined($_->{field}) || !$parsed->{omitted_names}{$_->{field}} } @{$parsed->{errors}}]};
}

sub _local_view ($config, $url) {
    return !$url->is_abs && !defined($url->host) && !defined($url->userinfo)
        && !length($url->fragment // '') && $url->path->to_string eq $config->path;
}

sub _parse ($class, $config, $context, $value) {
    my (@errors, $state, $engine, $url);
    my %input;
    my $ok = eval {
        $config = $config->for_request($context);
        if (blessed($value) && $value->isa('Selecto::Components::State')) {
            # Repeated fields and filters must remain arrays.
            my $params = Mojo::URL->new->query($value->query_pairs)->query;
            %input = %{$params->to_hash};
        } elsif (ref($value) eq 'HASH') {
            %input = %$value;
        } elsif (defined($value) && !ref($value) && length($value)) {
            $config->limits->check_bytes('max_state_bytes', $value, 'invalid_query', 'Saved view');
            my $parsed = Mojo::URL->new($value);
            die "Saved view URL must be local to $config->{path}.\n" unless _local_view($config, $parsed);
            %input = %{$parsed->query->to_hash};
        } else { die "Saved view URL or state is required.\n" }
        %input = %{Selecto::Components::State->normalize_input(\%input)};
        Selecto::Components::InputBudget->input($config->limits, \%input);
        my %allowed = map { $_ => 1 } (@{Selecto::Components::State->parameter_names},
            (map { $_->{name} } @{$config->query_options}), qw(saved_query_name saved_query_id));
        push @errors, {option => $_, message => "Option $_ is not available."}
            for sort grep { !$allowed{$_} && !/\Aquery_library_segment_choice_[A-Za-z][A-Za-z0-9_]{0,95}\z/ } keys %input;
        die "Unsupported saved-view option.\n" if @errors;
        delete @input{qw(saved_query_name saved_query_id)};
        my $options = Selecto::Components::QueryOptions->parse($config, \%input, $context);
        if (@{$options->{errors}}) {
            push @errors, map { +{option => $_->{name}, message => "Option $_->{name} is not available."} } @{$config->query_options};
            die "Invalid request options.\n";
        }
        $engine = $config->engine($context, \%input);
        die "Saved views require URL query state.\n" unless $config->query_params_enabled($engine->domain);
        1;
    };
    return {errors => @errors ? \@errors : [{option => 'url', message => 'Saved view URL or request options are invalid.'}]}
        unless $ok;
    my $domain = $engine->domain;
    # Give State's intentionally general page errors the submitted identifier.
    # Explain redacts unavailable fields before returning any structured data.
    my $map = $config->field_map($domain);
    my $detail = $config->detail_column_map($domain);
    my %omitted;
    my $all_fields_omitted = 0;
    my @sets = (
        [field => $detail, [qw(field_alias field_format)]],
        [group => $map, [qw(group_alias group_format group_bucket_ranges group_prefix_length group_exclude_articles)]],
        [measure => {map { $_->{id} => $_ } @{$config->measures_for_domain($domain)}}, [qw(measure_alias measure_function measure_bucket_ranges measure_ignore_nulls measure_series_id measure_chart_type measure_axis measure_stack measure_color measure_fill_opacity measure_transform measure_transform_window measure_transform_alpha)]],
        [filter_field => $config->filter_map($domain), [qw(filter_op filter_value filter_values_json filter_value_end filter_group filter_clause)]],
        [order => $map, ['direction']],
        [graph_category_field => $map, [qw(graph_category_value graph_category_format graph_category_color)]],
    );
    # Explicit grain fields are resolved through the same configuration maps.
    my $grain = _values(\%input, 'rows_of')->[0];
    if (defined($grain) && length($grain) && $grain ne '-') {
        for my $set (@sets) {
            my ($key) = @$set;
            my $extra = eval { $key eq 'field' ? $config->detail_column_map($domain, undef, $grain)
                : $key eq 'filter_field' ? $config->filter_map($domain, $grain)
                : $key eq 'measure' ? {map { $_->{id} => $_ } @{$config->measures_for_domain($domain, $grain)}}
                : $config->field_map($domain, $grain) };
            $set->[1] = {%{$set->[1]}, %{$extra // {}}};
        }
    }
    my $preview = eval { Selecto::Components::State->from_input($config, $domain, \%input) };
    if ($preview) {
        my $orders = $sets[4][1] = {%{$sets[4][1]}};
        $orders->{$_} = 1 for @{$preview->groups}, @{$preview->measures};
    }
    for my $set (@sets) {
        my ($key, $available, $parallel) = @$set;
        my $values = _values(\%input, $key);
        my @keep;
        for my $i (0 .. $#$values) {
            my $field = $values->[$i];
            next if !defined($field) || ref($field) || $field eq '';
            my $lookup = $field;
            $lookup =~ s/\Ameasure:// if $key eq 'order';
            if (!$available->{$lookup}) {
                $omitted{$lookup} = 1;
                push @errors, {field => $lookup, option => $key,
                    message => "Field $lookup is not available for $key."};
            } else { push @keep, $i }
        }
        if (@keep != @$values && @$values) {
            $all_fields_omitted = 1 if $key eq 'field' && !@keep;
            for my $name ($key, @$parallel) {
                my $items = _values(\%input, $name);
                $input{$name} = [map { $items->[$_] // '' } @keep];
            }
        }
    }
    # Values of a hidden grouping axis are just as private as the axis field.
    # Do not return pivot choices or grid cells after removing their group.
    for my $name (qw(pivot_column grid_column graph_series_group)) {
        my $id = _values(\%input, $name)->[0];
        next unless defined($id) && !ref($id) && length($id);
        my $group = $preview ? $preview->group_configs->{$id} : undef;
        my $field = $group ? $group->{field} // $id : $id;
        $field =~ s/:.*\z//; # Formatted group ids retain their source before ':'.
        next unless $omitted{$field};
        delete $input{$name};
        if ($name ne 'graph_series_group') {
            delete @input{qw(pivot_column_value pivot_column_value_null pivot_column_top pivot_column_top_order pivot_column_top_measure pivot_column_other)};
        }
    }
    if (grep { $_->{option} eq 'group' } @errors) {
        delete @input{qw(grid_cell grid_axis)};
    }
    $ok = eval {
        $state = Selecto::Components::State->from_input($config, $domain, \%input);
        push @errors, map { _state_error($_) } @{$state->errors};
        # State errors about rejected filters need their field even if State
        # discarded the invalid condition before building the query.
        if (!$state->valid) {
            for my $field (@{_values(\%input, 'filter_field')}) {
                push @errors, {field => $field, option => 'filter', message => "Check filter for $field."};
            }
        }
        if ($state->valid) {
            my $built = Selecto::Components::QueryBuilder->build($config, $domain, $state, {paginate => 1});
            $engine->compile($built->{query});
        }
        $url = Selecto::Components::Explorer->new(config => $config)->canonical_url($state->with_page(1), $domain);
        1;
    };
    unless ($ok) {
        my $error = $@;
        my $details = blessed($error) && $error->isa('Selecto::Error') ? $error->details : {};
        push @errors, {option => 'state', message => 'Saved view is not available under the current read policy.',
            (defined($details->{field}) && !ref($details->{field}) ? (field => $details->{field}) : ())};
    }
    return {errors => \@errors, state => $state, domain => $domain, config => $config,
        url => $url, omitted_names => \%omitted, omitted => scalar(keys %omitted), all_fields_omitted => $all_fields_omitted};
}

sub _state_error ($message) {
    my $option = $message =~ /filter/i ? 'filter_field'
        : $message =~ /alias/i ? 'field_alias'
        : $message =~ /format/i ? 'field_format'
        : $message =~ /measure|series|axis|stack/i ? 'measure'
        : $message =~ /group/i ? 'group'
        : $message =~ /sort|order|direction/i ? 'order'
        : $message =~ /page|limit/i ? 'limit'
        : $message =~ /view/i ? 'view'
        : $message =~ /chart/i ? 'chart_type'
        : $message =~ /palette|color/i ? 'graph_palette'
        : $message =~ /as.of/i ? 'as_of' : 'state';
    return {option => $option, message => $message};
}

sub _values ($input, $name) {
    return [] unless exists $input->{$name};
    return ref($input->{$name}) eq 'ARRAY' ? $input->{$name} : [$input->{$name}];
}

1;

__END__

=head1 NAME

Selecto::Components::SavedView - Check and explain saved Explorer views

=head1 SYNOPSIS

    my $result = Selecto::Components::SavedView->check($config, $context, $url);
    my $view = Selecto::Components::SavedView->explain($config, $context, $url);

=head1 DESCRIPTION

Public request-aware validation and structured descriptions of Explorer state.
See F<docs/saved-views.md> for arguments, result shapes and read-policy rules.
No Explorer query is executed.

=cut
