package Selecto::Components::QueryAssistant::Validator;

use 5.034;
use strict;
use warnings;

use Storable qw(dclone);
use Selecto::Components::QueryAssistant::Target ();
use Selecto::Components::QueryBuilder ();
use Selecto::Components::State ();

sub validate {
    my ($class, %args) = @_;
    my ($config, $domain, $engine, $target) = @args{qw(config domain engine target)};
    my ($input, $state, $built, $statement);
    my $ok = eval {
        $input = Selecto::Components::QueryAssistant::Target->to_input($target);
        _preserve_inactive_state($input, $args{preserve_input});
        die "view is not enabled\n" unless $config->allows_view($input->{view});
        if ($input->{view} ne 'detail') {
            my $defaults = $config->resolved_default_fields($domain);
            $input->{field} = [@$defaults];
            $input->{field_alias} = [map { '' } @$defaults];
            $input->{field_format} = [map { '' } @$defaults];
        }
        if ($input->{view} eq 'graph') {
            my $maximum = 0 + $config->max_limit;
            my $minimum = $maximum < 250 ? $maximum : 250;
            die "graph point limit must be from $minimum through $maximum\n"
                if $input->{limit} < $minimum || $input->{limit} > $maximum;
        } elsif ($input->{limit} > $config->max_limit) {
            die "row limit is above the configured maximum\n";
        }
        $state = Selecto::Components::State->from_input($config, $domain, $input);
        die join('; ', @{$state->errors}) . "\n" unless $state->valid;
        die "incomplete filters are not supported\n" if grep { $_->{draft} } @{$state->filters};
        $built = Selecto::Components::QueryBuilder->build($config, $domain, $state, {paginate => 1});
        if ($engine) {
            my $compiled = eval { $statement = $engine->compile($built->{query}); 1 };
            die "target could not be compiled\n" unless $compiled;
        }
        1;
    };
    unless ($ok) {
        my $message = $@ || 'target validation failed';
        $message =~ s/\s+\z//;
        return {ok => 0, errors => [{code => 'invalid_target', message => $message}]};
    }
    return {
        ok => 1, input => $input, state => $state,
        normalized_target => Selecto::Components::QueryAssistant::Target->from_state($state),
        prepared => $built,
        (defined($statement) ? (statement => $statement) : ()),
    };
}

sub _preserve_inactive_state {
    my ($input, $previous) = @_;
    return unless ref($previous) eq 'HASH';
    my $view = $input->{view};
    my @query_library = qw(
        query_library_view query_library_materialized_view query_library_segment
        query_library_param_name query_library_param_value
    );
    _copy($input, $previous, @query_library);

    if ($view ne 'detail') {
        _copy($input, $previous, qw(field field_alias field_format order direction row_click_action));
    }
    if ($view eq 'detail') {
        _copy($input, $previous, qw(
            group group_alias group_format group_bucket_ranges group_prefix_length
            group_exclude_articles measure measure_alias measure_function
            measure_bucket_ranges measure_ignore_nulls measure_series_id
            measure_chart_type measure_axis measure_stack measure_color
            measure_fill_opacity measure_transform measure_transform_window
        ));
    } elsif ($view eq 'aggregate') {
        my $old = $previous->{measure};
        my $new = $input->{measure};
        if (ref($old) eq 'ARRAY' && ref($new) eq 'ARRAY'
            && @$old == @$new && join("\0", @$old) eq join("\0", @$new)) {
            _copy($input, $previous, qw(
                measure_series_id measure_chart_type measure_axis measure_stack
                measure_color measure_fill_opacity measure_transform measure_transform_window
            ));
        }
    }
    if ($view ne 'graph') {
        _copy($input, $previous, qw(
            chart_type graph_show_table graph_palette graph_category_field
            graph_category_value graph_category_format graph_category_color
        ));
    }
    if ($view ne 'aggregate') {
        _copy($input, $previous, qw(
            aggregate_grid aggregate_grid_colorize aggregate_grid_color_scale
        ));
    }
}

sub _copy {
    my ($input, $previous, @keys) = @_;
    for my $key (@keys) {
        next unless exists $previous->{$key};
        $input->{$key} = ref($previous->{$key})
            ? dclone($previous->{$key}) : $previous->{$key};
    }
}

1;
