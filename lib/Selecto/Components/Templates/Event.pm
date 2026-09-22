package Selecto::Components::Templates::Event;

use 5.034;
use strict;
use warnings;

use B qw(SVp_IOK SVp_NOK SVp_POK svref_2object);
use Encode qw(encode_utf8);
use JSON::PP ();

my $MAX_VALUE_BYTES = 16_384;
my $MAX_INTEGER = '9223372036854775807';
my $MIN_INTEGER_MAGNITUDE = '9223372036854775808';

sub max_value_bytes { return $MAX_VALUE_BYTES }

sub normalize {
    my ($class, $manifest, $event_name, $params) = @_;
    return _error('invalid_event_params', 'template event parameters are invalid')
        unless ref($manifest) eq 'HASH' && ref($manifest->{events}) eq 'ARRAY'
        && defined($event_name) && !ref($event_name) && ref($params) eq 'HASH';

    my ($declaration) = grep {
        ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} eq $event_name
    } @{$manifest->{events}};
    return _error('unknown_event', 'template event is not declared')
        unless $declaration;
    return _error('invalid_event_params', 'template event parameters are invalid')
        unless keys(%$params) == 1 && exists($params->{value});

    my $type = ref($declaration->{payload}) eq 'HASH'
        ? $declaration->{payload}{value} : undef;
    return _error('invalid_event_declaration', 'template event declaration is invalid')
        unless defined($type) && ($type eq 'string' || $type eq 'integer' || $type eq 'boolean');

    my $normalized = _normalize_value($type, $params->{value});
    return $normalized unless $normalized->{status} eq 'ok';
    return {status => 'ok', payload => {value => $normalized->{value}}};
}

sub _normalize_value {
    my ($type, $value) = @_;
    if ($type eq 'string') {
        return _invalid_value() unless _string($value);
        return _error('event_value_too_large', 'template event value is too large')
            if length(encode_utf8($value)) > $MAX_VALUE_BYTES;
        return {status => 'ok', value => $value};
    }

    if ($type eq 'integer') {
        return {status => 'ok', value => $value}
            if _native_integer($value) && _int64("$value");
        return _invalid_value() unless _string($value) && _int64($value);
        return {status => 'ok', value => int($value)};
    }

    if ($type eq 'boolean') {
        return {status => 'ok', value => $value} if JSON::PP::is_bool($value);
        return {status => 'ok', value => JSON::PP::true} if _string($value) && $value eq 'true';
        return {status => 'ok', value => JSON::PP::false} if _string($value) && $value eq 'false';
    }

    return _invalid_value();
}

sub _string {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value);
    return !!(svref_2object(\$value)->FLAGS & SVp_POK);
}

sub _native_integer {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value);
    my $flags = svref_2object(\$value)->FLAGS;
    return !!($flags & (SVp_IOK | SVp_NOK)) && "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/;
}

sub _int64 {
    my ($value) = @_;
    return 0 unless defined($value) && $value =~ /\A(?:0|-[1-9][0-9]*|[1-9][0-9]*)\z/;
    if ($value =~ /\A-(.+)\z/) {
        my $magnitude = $1;
        return length($magnitude) < 19
            || (length($magnitude) == 19 && $magnitude le $MIN_INTEGER_MAGNITUDE);
    }
    return length($value) < 19
        || (length($value) == 19 && $value le $MAX_INTEGER);
}

sub _invalid_value {
    return _error('invalid_event_value', 'template event value is invalid');
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
