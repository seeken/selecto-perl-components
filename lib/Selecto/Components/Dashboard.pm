package Selecto::Components::Dashboard;

# Helpers for hosts that show several saved Explorer views on one page (a
# dashboard or desktop): read a saved view's URL into Explorer input, list its
# promoted filters, apply shared filter values to them, and render one view's
# results as a tile body. Query meaning, validation and execution stay with
# Explorer (Explorer->model) and native selecto-perl.

use Mojo::Base -base, -signatures;
use Mojo::URL ();
use Selecto::Components::State ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Components::Renderer::Builder ();
use Selecto::Components::Renderer::Results ();

my $SEGMENT_CHOICE = qr/\Aquery_library_segment_choice_[A-Za-z][A-Za-z0-9_]*\z/;

# The Explorer input (as Explorer::input_from_controller would build it) held in
# a saved view URL such as "/explorer/load?q=1&view=graph&...". Unknown
# parameters are ignored.
sub input_from_url ($class, $url) {
    my $query = Mojo::URL->new($url // '')->query;
    my %known = map { $_ => 1 } @{Selecto::Components::State->parameter_names};
    my %input;
    for my $name (@{$query->names}) {
        next unless $known{$name} || ($name =~ $SEGMENT_CHOICE && length($name) <= 128);
        my @values = @{$query->every_param($name)};
        next unless @values;
        $input{$name} = @values == 1 ? $values[0] : \@values;
    }
    return \%input;
}

# The explorer path of a saved view URL ("/explorer/load").
sub path_from_url ($class, $url) {
    return Mojo::URL->new($url // '')->path->to_string;
}

# The promoted filters of a validated state, in order, as
#   {field, label, type, kind, op, value, value_end, instance, summary, operators}
# where kind is date | number | boolean | choice | text. Only the first promoted
# filter on a field is listed (it is the one shared values replace).
sub promoted_filters ($class, $config, $domain, $state) {
    my %by_path = map { $_->{path} => $_ } @{$config->filter_catalog($domain)};
    my (@filters, %seen);
    for my $index (0 .. $#{$state->filters}) {
        my $filter = $state->filters->[$index];
        next unless $filter->{promoted} && !defined($filter->{clause});
        next if $filter->{grouped} || $seen{$filter->{field}}++;
        my $field = $by_path{$filter->{field}} or next;
        push @filters, {
            field => $filter->{field},
            label => $field->{label},
            type => $field->{type},
            kind => $class->filter_kind($config, $field),
            op => $filter->{op},
            value => $filter->{value} // '',
            value_end => $filter->{value_end} // '',
            instance => $index + 1,
            summary => $class->filter_summary($config, $field, $filter),
            operators => Selecto::Components::Renderer::Builder::_filter_operators_for_filter(
                $config, $field, $filter,
            ),
        };
    }
    return \@filters;
}

sub filter_kind ($class, $config, $field) {
    return 'choice' if ref($field->{filter_choices}) eq 'ARRAY' && @{$field->{filter_choices}};
    return 'date' if $config->temporal_type($field->{type});
    return 'number' if $config->numeric_type($field->{type});
    return 'boolean' if $config->boolean_type($field->{type});
    return 'text';
}

# A compact summary of a filter's value for a chip or tile header:
# "Today", "2026-09-01 – 2026-09-15", "Acme, Globex +2", "≥ 100", "Any".
sub filter_summary ($class, $config, $field, $filter) {
    my $op = $filter->{op} // 'eq';
    my $value = $filter->{value} // '';
    my $value_end = $filter->{value_end} // '';
    return 'Empty' if $op eq 'is_null';
    return 'Not empty' if $op eq 'not_null';
    return Selecto::Components::Renderer::Builder::date_shortcut_label($value)
        if $op eq 'date_shortcut';
    if ($op eq 'between') {
        return 'Any' unless length($value) || length($value_end);
        return "from $value" unless length($value_end);
        return "until $value_end" unless length($value);
        return "$value – $value_end";
    }
    return 'Any' unless length($value);
    my $text = $value;
    if (ref($field) eq 'HASH' && ref($field->{filter_choices}) eq 'ARRAY'
        && @{$field->{filter_choices}}) {
        my %labels = map { $_->{value} => $_->{label} } @{$field->{filter_choices}};
        my @labels = map { my $id = $_; $id =~ s/\A\s+|\s+\z//g; $labels{$id} // $id }
            grep { length } split /,/, $value, -1;
        $text = @labels > 2
            ? join(', ', @labels[0, 1]) . ' +' . (@labels - 2)
            : join(', ', @labels);
    }
    my %prefix = (
        eq => '', ne => '≠ ', gt => '> ', gte => '≥ ', lt => '< ', lte => '≤ ',
        in => '', not_in => 'not ',
    );
    return ($prefix{$op} // '') . $text;
}

# Explorer input for $state with shared filter values applied. $overrides maps a
# promoted filter's field to {op, value, value_end}; it replaces only that
# filter's operator and values (the first promoted filter on the field) and
# leaves every other filter, group, measure and option as saved. Pagination
# returns to the first page. The result must go through Explorer->model again,
# which validates it.
sub apply_overrides ($class, $state, $overrides) {
    my $pairs = $state->query_pairs;
    my %input;
    for (my $i = 0; $i < @$pairs; $i += 2) {
        push @{$input{$pairs->[$i]}}, $pairs->[$i + 1];
    }
    my %done;
    for my $index (0 .. $#{$state->filters}) {
        my $filter = $state->filters->[$index];
        next unless $filter->{promoted} && !defined($filter->{clause}) && !$filter->{grouped};
        my $override = ref($overrides) eq 'HASH' ? $overrides->{$filter->{field}} : undef;
        next unless ref($override) eq 'HASH' && !$done{$filter->{field}}++;
        $input{filter_op}[$index] = $override->{op} // $filter->{op};
        $input{filter_value}[$index] = $override->{value} // '';
        $input{filter_value_end}[$index] = $override->{value_end} // '';
    }
    $input{page} = [1];
    return {map { my $v = $input{$_}; ($_ => @$v == 1 ? $v->[0] : $v) } keys %input};
}

# The results of one view without Explorer's page furniture (pagination,
# result meta, debug panel, promoted filter cards): the chart, aggregate grid or
# table. The page embedding tiles must provide an ancestor with
# data-sc-chart-src for charts to load.
sub tile_html ($class, $model) {
    my $state = $model->{state};
    my $result = $model->{result};
    unless ($state && $state->valid && $result) {
        my @errors = $state ? @{$state->errors} : ();
        push @errors, $model->{runtime_error} if $model->{runtime_error};
        @errors = ('This view could not be shown.') unless @errors;
        return '<div class="sc-alert" role="alert"><ul>' .
            join('', map { '<li>' . html_escape($_) . '</li>' } @errors) . '</ul></div>';
    }
    my $results = 'Selecto::Components::Renderer::Results';
    return '<div class="sc-grid-warning" role="status">This grid is too large to show here. Open it in Explorer.</div>'
        if $result->{grid_limit_exceeded};
    return $results->_graph($result, $model) if $result->{graph};
    return $results->_grid($result, $model) if $result->{grid_data};
    return '<p class="sc-empty-note">No rows match.</p>' unless @{$result->{records} // []};
    return $results->_table($result, $model);
}

# The editor controls for one promoted filter, for use outside the Explorer page:
# a match-mode select and, for each allowed mode, its value controls (all but the
# current mode hidden), using Explorer's promoted-filter markup and its
# data-sc-promoted-filter-input="op|value|value_end" attributes.
sub filter_controls_html ($class, $config, $domain, $filter) {
    my %by_path = map { $_->{path} => $_ } @{$config->filter_catalog($domain)};
    my $field = $by_path{$filter->{field}} or return '';
    my $builder = 'Selecto::Components::Renderer::Builder';
    my $current = {op => $filter->{op}, value => $filter->{value}, value_end => $filter->{value_end}};
    my $html = $builder->_promoted_filter_mode_control($config, $field, $current);
    for my $operator (@{Selecto::Components::Renderer::Builder::_filter_operators_for_filter(
        $config, $field, $current,
    )}) {
        my $op = $operator->[0];
        my $values = $op eq $current->{op} ? $current : {op => $op, value => '', value_end => ''};
        $html .= '<div data-sc-promoted-filter-values data-op="' . html_escape($op) . '"' .
            ($op eq $current->{op} ? '' : ' hidden') . '>' .
            $builder->_promoted_filter_value_controls($config, $field, $values) . '</div>';
    }
    return $html;
}

1;

=head1 NAME

Selecto::Components::Dashboard - saved Explorer views as tiles on one page

=head1 SYNOPSIS

    my $explorer = $c->selecto_components_explorer('load');
    my $input = Selecto::Components::Dashboard->input_from_url($saved_url);
    my $model = $explorer->model($c, $input, {result_cache => $cache});
    my $filters = Selecto::Components::Dashboard->promoted_filters(
        $model->{config}, $model->{domain}, $model->{state},
    );
    my $shared = Selecto::Components::Dashboard->apply_overrides(
        $model->{state}, {delivered_date => {op => 'date_shortcut', value => 'today'}},
    );
    my $html = Selecto::Components::Dashboard->tile_html(
        $explorer->model($c, $shared, {result_cache => $cache}),
    );

=cut
