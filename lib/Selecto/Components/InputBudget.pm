package Selecto::Components::InputBudget;
use Mojo::Base -base, -signatures;
use Encode qw(encode);
use Scalar::Util qw(blessed reftype refaddr);
use Selecto::Limits ();

sub input ($class, $limits, $input) {
    my ($bytes, $nodes) = (0, 0);
    my $walk;
    $walk = sub ($value, $depth = 0) {
        die "Query state nesting is too deep.\n" if $depth > 12;
        die "Query state has too many values.\n" if ++$nodes > $limits->get('max_expression_nodes');
        if (!ref($value)) {
            return unless defined $value;
            $limits->check_bytes('max_state_bytes', $value, 'invalid_query', 'Query state value');
            $bytes += length(encode('UTF-8', "$value"));
            $limits->check_count('max_state_bytes', $bytes, 'invalid_query', 'Query state bytes');
        } elsif (ref($value) eq 'ARRAY') {
            $limits->check_count('max_generated_parameters', scalar(@$value), 'invalid_query', 'Query state collection');
            $walk->($_, $depth + 1) for @$value;
        } elsif (ref($value) eq 'HASH') {
            $limits->check_count('max_expression_nodes', scalar(keys %$value), 'invalid_query', 'Query state keys');
            for my $key (keys %$value) { $walk->($key, $depth + 1); $walk->($value->{$key}, $depth + 1) }
        } else { die "Query state contains an invalid value.\n" }
    };
    $walk->($input);
    if (exists $input->{field}) {
        my $fields = ref($input->{field}) eq 'ARRAY' ? $input->{field} : [$input->{field}];
        $limits->check_count('max_fields', scalar(@$fields), 'invalid_query', 'Detail columns');
    }
    for my $name (qw(group_bucket_ranges measure_bucket_ranges)) {
        next unless exists $input->{$name};
        for my $value (ref($input->{$name}) eq 'ARRAY' ? @{$input->{$name}} : $input->{$name}) {
            $limits->check_bytes('max_bucket_bytes', $value, 'invalid_query', 'Bucket input');
            my @parts = split /,/, $value, $limits->get('max_bucket_ranges') + 1;
            $limits->check_count('max_bucket_ranges', scalar(@parts), 'invalid_query', 'Bucket ranges');
            $limits->check_count('max_numeric_digits', length($_), 'invalid_query', 'Bucket digits')
                for $value =~ /([0-9]+)/g;
        }
    }
    return 1;
}

sub membership ($class, $limits, $values) {
    $limits->check_count('max_filter_values', scalar(@$values), 'invalid_query', 'Membership values');
    my $bytes = 0;
    for my $value (@$values) {
        die "Membership values must be scalars.\n" if !defined($value) || ref($value);
        $limits->check_bytes('max_value_bytes', $value, 'invalid_query', 'Membership value');
        $bytes += length(encode('UTF-8', "$value"));
    }
    $limits->check_count('max_parameter_bytes', $bytes, 'invalid_query', 'Membership bytes');
    return 1;
}

sub query ($class, $limits, $query) {
    $limits->check_count('max_generated_selections', scalar(@{$query->selections}), 'invalid_query', 'Generated selections');
    my ($nodes, $parameters, $parameter_bytes, %active) = (0, 0, 0);
    my $parameter = sub ($value) {
        $limits->check_count('max_generated_parameters', ++$parameters, 'invalid_query', 'Query parameters');
        return unless defined $value;
        die "Query parameter must be scalar.\n" if ref $value;
        $limits->check_bytes('max_value_bytes', $value, 'invalid_query', 'Query parameter');
        $parameter_bytes += length(encode('UTF-8', "$value"));
        $limits->check_count('max_parameter_bytes', $parameter_bytes, 'invalid_query', 'Query parameter bytes');
    };
    my $walk;
    $walk = sub ($value) {
        return unless ref $value;
        die "Cyclic query structure.\n" if $active{refaddr($value)};
        local $active{refaddr($value)} = 1;
        $limits->check_count('max_expression_nodes', ++$nodes, 'invalid_query', 'Query nodes');
        if (blessed($value) && $value->isa('Selecto::Expression')) {
            $parameter->($value->arguments->[0]) if $value->kind eq 'literal';
            if ($value->kind eq 'in') { $parameter->($_) for @{$value->arguments->[1]} }
        }
        my $type = reftype($value) // '';
        $walk->($_) for $type eq 'ARRAY' ? @$value : $type eq 'HASH' ? values %$value : ();
    };
    $walk->($query);
    return 1;
}
1;
