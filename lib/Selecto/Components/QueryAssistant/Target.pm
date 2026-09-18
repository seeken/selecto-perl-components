package Selecto::Components::QueryAssistant::Target;

use 5.034;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use Storable qw(dclone);

sub from_state {
    my ($class, $state) = @_;
    my $target = {
        view => $state->view,
        filters => [map {
            +{field => $_->{field}, operator => $_->{op},
              value => ref($_->{values}) eq 'ARRAY' ? [@{$_->{values}}] : $_->{value},
              (length($_->{value_end} // '') ? (value_end => $_->{value_end}) : ())}
        } grep { !$_->{draft} && !$_->{grouped} && !defined($_->{clause}) } @{$state->filters}],
        limit => 0 + $state->limit,
    };
    if ($state->view eq 'detail') {
        $target->{fields} = [map {
            my $index = $_;
            my $id = $state->fields->[$index];
            my $cfg = $state->field_config_list->[$index] // {};
            +{field => $id,
              (length($cfg->{alias} // '') ? (alias => $cfg->{alias}) : ()),
              (length($cfg->{format} // '') ? (format => $cfg->{format}) : ())}
        } 0 .. $#{$state->fields}];
        $target->{orders} = [map { +{%$_} } @{$state->orders}];
    } else {
        $target->{groups} = [map {
            my $id = $_;
            my $cfg = $state->group_configs->{$id} // {};
            +{field => $id,
              (length($cfg->{alias} // '') ? (alias => $cfg->{alias}) : ()),
              (length($cfg->{format} // '') ? (format => $cfg->{format}) : ())}
        } @{$state->groups}];
        $target->{measures} = [map {
            my $index = $_;
            my $id = $state->measures->[$index];
            my $cfg = $state->measure_config_list->[$index] // {};
            my $transform = ref($cfg->{transforms}) eq 'ARRAY' ? $cfg->{transforms}[0] : undef;
            +{id => $id, function => $cfg->{function}, alias => $cfg->{alias} // '',
              null_handling => $cfg->{null_handling} // 'auto',
              ($state->view eq 'graph' ? (
                  series_id => $cfg->{series_id}, chart_type => $cfg->{chart_type} // 'auto',
                  axis => $cfg->{axis} // 'auto', stack => length($cfg->{stack} // '') ? $cfg->{stack} : undef,
                  color => length($cfg->{color} // '') ? $cfg->{color} : undef,
                  fill_opacity => $cfg->{fill_opacity},
                  transforms => $transform ? [dclone($transform)] : [],
              ) : ())}
        } 0 .. $#{$state->measures}];
        if ($state->view eq 'graph') {
            $target->{graph} = {
                chart_type => $state->chart_type,
                show_table => $state->graph_show_table ? 1 : 0,
                palette => $state->graph_palette // 'default',
                category_colors => [map { +{%$_} } @{$state->graph_category_colors // []}],
            };
        }
    }
    return $target;
}

sub to_input {
    my ($class, $target) = @_;
    die "target must be an object\n" unless ref($target) eq 'HASH';
    my $view = _scalar($target->{view}, 'view');
    die "view is not supported\n" unless $view =~ /\A(?:detail|aggregate|graph)\z/;
    my %allowed = map { $_ => 1 } qw(view filters limit);
    $allowed{$_} = 1 for $view eq 'detail' ? qw(fields orders) : qw(groups measures);
    $allowed{graph} = 1 if $view eq 'graph';
    _unknown($target, \%allowed, 'target');
    die "filters must be an array\n" unless ref($target->{filters}) eq 'ARRAY';
    my $limit = $target->{limit};
    die "limit must be a positive integer\n"
        unless defined($limit) && !ref($limit) && "$limit" =~ /\A[1-9]\d*\z/;
    my %input = (q => 1, view => $view, limit => 0 + $limit, page => 1);
    my (@filter_field, @filter_op, @filter_value, @filter_values_json, @filter_value_end);
    for my $filter (@{$target->{filters}}) {
        die "filter must be an object\n" unless ref($filter) eq 'HASH';
        _unknown($filter, {map { $_ => 1 } qw(field operator value value_end)}, 'filter');
        push @filter_field, _scalar($filter->{field}, 'filter field');
        push @filter_op, _scalar($filter->{operator}, 'filter operator');
        my $op = $filter_op[-1];
        if ($op eq 'in' && ref($filter->{value}) eq 'ARRAY') {
            die "membership filter values must not be empty\n" unless @{$filter->{value}};
            die "membership filter values must be scalars\n"
                if grep { !_is_json_scalar($_) } @{$filter->{value}};
            push @filter_value, '';
            require Mojo::JSON;
            push @filter_values_json, Mojo::JSON::encode_json([
                map { _json_scalar($_, 'membership filter value') } @{$filter->{value}}
            ]);
        } elsif ($op =~ /_null\z/) {
            push @filter_value, '';
            push @filter_values_json, '';
        } else {
            push @filter_value, _json_scalar($filter->{value}, 'filter value');
            push @filter_values_json, '';
        }
        die "filter value_end must be a scalar or null\n"
            if defined($filter->{value_end}) && !_is_json_scalar($filter->{value_end});
        push @filter_value_end, defined($filter->{value_end})
            ? _json_scalar($filter->{value_end}, 'filter value_end') : '';
    }
    @input{qw(filter_field filter_op filter_value filter_values_json filter_value_end)} =
        (\@filter_field, \@filter_op, \@filter_value, \@filter_values_json, \@filter_value_end) if @filter_field;
    if ($view eq 'detail') {
        die "fields must be a non-empty array\n"
            unless ref($target->{fields}) eq 'ARRAY' && @{$target->{fields}};
        my (@field, @alias, @format);
        for my $item (@{$target->{fields}}) {
            $item = {field => $item} unless ref($item);
            die "field must be an object\n" unless ref($item) eq 'HASH';
            _unknown($item, {field => 1, alias => 1, format => 1}, 'field');
            push @field, _scalar($item->{field}, 'field');
            push @alias, _optional_scalar($item->{alias}, 'field alias');
            push @format, _optional_scalar($item->{format}, 'field format');
        }
        @input{qw(field field_alias field_format)} = (\@field, \@alias, \@format);
        die "orders must be an array\n" unless ref($target->{orders}) eq 'ARRAY';
        my (@order, @direction);
        for my $item (@{$target->{orders}}) {
            die "order must be an object\n" unless ref($item) eq 'HASH';
            _unknown($item, {field => 1, direction => 1}, 'order');
            push @order, _scalar($item->{field}, 'order field');
            push @direction, _scalar($item->{direction}, 'order direction');
        }
        @input{qw(order direction)} = (\@order, \@direction) if @order;
    } else {
        die "groups must be a non-empty array\n"
            unless ref($target->{groups}) eq 'ARRAY' && @{$target->{groups}};
        my (@group, @group_alias, @group_format);
        for my $item (@{$target->{groups}}) {
            $item = {field => $item} unless ref($item);
            die "group must be an object\n" unless ref($item) eq 'HASH';
            _unknown($item, {field => 1, alias => 1, format => 1}, 'group');
            push @group, _scalar($item->{field}, 'group field');
            push @group_alias, _optional_scalar($item->{alias}, 'group alias');
            push @group_format, _optional_scalar($item->{format}, 'group format');
        }
        @input{qw(group group_alias group_format)} = (\@group, \@group_alias, \@group_format);
        die "measures must be a non-empty array\n"
            unless ref($target->{measures}) eq 'ARRAY' && @{$target->{measures}};
        my (@id, @function, @alias, @nulls, @series, @type, @axis, @stack, @color, @opacity, @transform, @window);
        for my $index (0 .. $#{$target->{measures}}) {
            my $item = $target->{measures}[$index];
            die "measure must be an object\n" unless ref($item) eq 'HASH';
            my %measure_allowed = map { $_ => 1 } qw(id function alias null_handling);
            if ($view eq 'graph') {
                $measure_allowed{$_} = 1 for qw(series_id chart_type axis stack color fill_opacity transforms);
            }
            _unknown($item, \%measure_allowed, 'measure');
            push @id, _scalar($item->{id}, 'measure id');
            push @function, _scalar($item->{function}, 'measure function');
            push @alias, _optional_scalar($item->{alias}, 'measure alias');
            my $null = _optional_scalar($item->{null_handling}, 'NULL handling') || 'auto';
            die "NULL handling is not supported\n" unless $null =~ /\A(?:auto|sql|zero)\z/;
            push @nulls, $null eq 'sql' ? 0 : $null eq 'zero' ? 1 : 'auto';
            next unless $view eq 'graph';
            push @series, _optional_scalar($item->{series_id}, 'series id') || 'series_' . ($index + 1);
            push @type, _optional_scalar($item->{chart_type}, 'series chart type') || 'auto';
            push @axis, _optional_scalar($item->{axis}, 'series axis') || 'auto';
            push @stack, _optional_scalar($item->{stack}, 'stack');
            push @color, _optional_scalar($item->{color}, 'color');
            push @opacity, _optional_scalar($item->{fill_opacity}, 'fill opacity');
            my $transforms = $item->{transforms} // [];
            die "transforms must be an array with at most one item\n"
                unless ref($transforms) eq 'ARRAY' && @$transforms <= 1;
            my $t = $transforms->[0];
            if ($t) {
                die "transform must be an object\n" unless ref($t) eq 'HASH';
                _unknown($t, {type => 1, parameters => 1}, 'transform');
                push @transform, _scalar($t->{type}, 'transform type');
                my $parameters = $t->{parameters} // {};
                die "transform parameters must be an object\n" unless ref($parameters) eq 'HASH';
                _unknown($parameters, {window => 1}, 'transform parameters');
                push @window, $parameters->{window} // '';
            } else {
                push @transform, '';
                push @window, '';
            }
        }
        @input{qw(measure measure_function measure_alias measure_ignore_nulls)} =
            (\@id, \@function, \@alias, \@nulls);
        if ($view eq 'graph') {
            die "graph must be an object\n" unless ref($target->{graph}) eq 'HASH';
            _unknown($target->{graph}, {chart_type => 1, show_table => 1, palette => 1, category_colors => 1}, 'graph');
            $input{chart_type} = _scalar($target->{graph}{chart_type}, 'chart type');
            $input{graph_show_table} = _boolean($target->{graph}{show_table}, 'show_table');
            $input{graph_palette} = _optional_scalar($target->{graph}{palette}, 'graph palette') || 'default';
            my $categories = $target->{graph}{category_colors} // [];
            die "category_colors must be an array\n" unless ref($categories) eq 'ARRAY';
            my (@category_field, @category_value, @category_format, @category_color);
            for my $category (@$categories) {
                die "category color must be an object\n" unless ref($category) eq 'HASH';
                _unknown($category, {field => 1, value => 1, format => 1, color => 1}, 'category color');
                push @category_field, _scalar($category->{field}, 'category field');
                push @category_value, _json_scalar($category->{value}, 'category value');
                push @category_format, _optional_scalar($category->{format}, 'category format');
                push @category_color, _scalar($category->{color}, 'category color');
            }
            @input{qw(graph_category_field graph_category_value graph_category_format graph_category_color)} =
                (\@category_field, \@category_value, \@category_format, \@category_color) if @category_field;
            @input{qw(measure_series_id measure_chart_type measure_axis measure_stack measure_color measure_fill_opacity measure_transform measure_transform_window)} =
                (\@series, \@type, \@axis, \@stack, \@color, \@opacity, \@transform, \@window);
        }
    }
    return \%input;
}

sub _unknown {
    my ($value, $allowed, $where) = @_;
    my @unknown = grep { !$allowed->{$_} } keys %$value;
    die "$where contains unsupported member $unknown[0]\n" if @unknown;
}

sub _scalar {
    my ($value, $name) = @_;
    die "$name must be a non-empty scalar\n" if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

sub _optional_scalar {
    my ($value, $name) = @_;
    return '' unless defined $value;
    die "$name must be a scalar or null\n" if ref($value);
    return "$value";
}

sub _is_json_scalar {
    my ($value) = @_;
    return 0 unless defined $value;
    return 1 unless ref $value;
    return blessed($value) && $value->isa('JSON::PP::Boolean') ? 1 : 0;
}

sub _json_scalar {
    my ($value, $name) = @_;
    die "$name must be a scalar\n" unless _is_json_scalar($value);
    return blessed($value) ? (0 + $value ? '1' : '0') : "$value";
}

sub _boolean {
    my ($value, $name) = @_;
    return 0 unless defined $value;
    return 0 + $value ? 1 : 0 if blessed($value) && $value->isa('JSON::PP::Boolean');
    die "$name must be a boolean\n" if ref($value) || "$value" !~ /\A[01]\z/;
    return 0 + $value;
}

1;
