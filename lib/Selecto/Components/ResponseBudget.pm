package Selecto::Components::ResponseBudget;
use Mojo::Base -strict, -signatures;
use bytes ();
use Mojo::JSON qw(encode_json);
use Scalar::Util qw(blessed);
use JSON::PP ();
use Selecto::Limits ();
use Selecto::OperationBudget ();

our $CURRENT;

sub render ($class, $limits, $callback) {
    if ($CURRENT) {
        local $CURRENT->{limits} = $CURRENT->{limits}->intersect($limits);
        my $text = $callback->();
        $CURRENT->{limits}->check_bytes('max_response_bytes', $text,
            'response_limit_exceeded', 'Rendered response');
        return $text;
    }
    local $CURRENT = {limits => $limits, bytes => 0};
    my $text = $callback->();
    $limits->check_bytes('max_response_bytes', $text, 'response_limit_exceeded', 'Rendered response');
    return $text;
}

# Charge dynamic text before the escaping allocation, including a finite
# allowance for the surrounding markup emitted at every text site.
sub escape ($class, $value) {
    return unless $CURRENT;
    my $maximum = bytes::length($value // '') * 6 + 128;
    $CURRENT->{limits}->check_count('max_response_bytes', $CURRENT->{bytes} + $maximum,
        'response_limit_exceeded', 'Rendered response');
    $CURRENT->{bytes} += $maximum;
}
sub fragment ($class, $text) {
    if ($CURRENT) {
        $CURRENT->{bytes} += bytes::length($text);
        $CURRENT->{limits}->check_count('max_response_bytes', $CURRENT->{bytes},
            'response_limit_exceeded', 'Rendered response');
    }
    return $text;
}

# Check exact JSON representation size before materializing the whole string.
# The iterative tree guard runs first, so encoding one scalar/key is bounded.
sub json ($class, $value, $limits = undef) {
    $limits //= Selecto::Limits->new;
    Selecto::OperationBudget->new(limits => $limits, code => 'response_limit_exceeded')->check_tree(
        $value, bytes_limit => 'max_response_bytes', scalar_limit => 'max_response_bytes', label => 'Response');
    my @stack = ($value);
    my $size = 0;
    while (@stack) {
        my $item = pop @stack;
        if (!ref($item) || JSON::PP::is_bool($item)) {
            _scalar_admission($item, $limits, $size);
            $size += bytes::length(encode_json($item));
        } elsif (ref($item) eq 'ARRAY') {
            $size += 2 + (@$item ? @$item - 1 : 0);
            push @stack, @$item;
        } else {
            my @keys = keys %$item;
            $size += 2 + (@keys ? @keys - 1 : 0);
            for my $key (@keys) {
                _scalar_admission($key, $limits, $size + 1);
                $size += bytes::length(encode_json($key)) + 1;
            }
            push @stack, @{$item}{@keys};
        }
        $limits->check_count('max_response_bytes', $size, 'response_limit_exceeded', 'Encoded response');
    }
    return encode_json($value);
}
sub _scalar_admission ($value, $limits, $used) {
    my $estimated = !defined($value) ? 4 : JSON::PP::is_bool($value) ? ($value ? 4 : 5)
        : bytes::length($value) + 2;
    if (defined($value) && !ref($value)) {
        # String syntax is an upper bound for numeric scalars too. Scan without
        # creating an escaped copy; one scalar cannot amplify past the cap.
        while ($value =~ /(["\\\x00-\x1f])/g) {
            $estimated += $1 =~ /[\x08\x09\x0a\x0c\x0d"\\]/ ? 1 : 5;
        }
    }
    $limits->check_count('max_response_bytes', $used + $estimated,
        'response_limit_exceeded', 'Encoded response');
}
1;
