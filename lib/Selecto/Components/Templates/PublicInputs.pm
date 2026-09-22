package Selecto::Components::Templates::PublicInputs;

use 5.034;
use strict;
use warnings;

use Encode qw(encode_utf8);
use JSON::PP ();
use Mojo::URL ();

my $MAX_STRING_BYTES = 16_384;
my $MAX_INTEGER = '9223372036854775807';
my $MIN_INTEGER_MAGNITUDE = '9223372036854775808';

sub configure {
    my ($class, $manifest, $names, $template_id) = @_;
    $template_id //= 'unknown';
    $names //= [];
    die "template $template_id public_inputs must be an array\n"
        unless ref($names) eq 'ARRAY';
    die "template $template_id manifest inputs must be an array\n"
        unless ref($manifest) eq 'HASH' && ref($manifest->{inputs}) eq 'ARRAY';

    my (%requested, %declared);
    for my $name (@$names) {
        die "template $template_id public input name is invalid\n"
            unless defined($name) && !ref($name)
            && "$name" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        die "template $template_id public input $name is configured more than once\n"
            if $requested{"$name"}++;
    }

    my @configured;
    for my $input (@{$manifest->{inputs}}) {
        die "template $template_id manifest input declaration is invalid\n"
            unless ref($input) eq 'HASH'
            && defined($input->{name}) && !ref($input->{name})
            && "$input->{name}" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
            && defined($input->{type}) && !ref($input->{type});
        my $name = "$input->{name}";
        die "template $template_id manifest input $name is declared more than once\n"
            if $declared{$name}++;
        next unless $requested{$name};
        my $type = "$input->{type}";
        die "template $template_id public input $name must be string, integer, or boolean\n"
            unless $type =~ /\A(?:string|integer|boolean)\??\z/;
        push @configured, {name => $name, type => $type};
    }

    for my $name (sort keys %requested) {
        die "template $template_id public input $name is not declared by the manifest\n"
            unless $declared{$name};
    }
    return \@configured;
}

sub decode {
    my ($class, $controller, $declarations) = @_;
    return _invalid()
        unless ref($controller) && ref($declarations) eq 'ARRAY';
    my %allowed = map { $_->{name} => $_ } @$declarations;
    my @submitted_names = @{$controller->req->params->names};
    return _invalid() if grep { !$allowed{$_} } @submitted_names;

    my (%inputs, @query_pairs);
    for my $declaration (@$declarations) {
        my $name = $declaration->{name};
        my $values = $controller->every_param($name);
        next unless ref($values) eq 'ARRAY' && @$values;
        return _invalid() unless @$values == 1 && !ref($values->[0]);
        my $normalized = _normalize($declaration->{type}, $values->[0]);
        return $normalized unless $normalized->{status} eq 'ok';
        $inputs{$name} = $normalized->{value};
        push @query_pairs, $name, $normalized->{query_value};
    }

    my $canonical = Mojo::URL->new($controller->req->url->path->to_string);
    $canonical->query(\@query_pairs) if @query_pairs;
    my $canonical_url = $canonical->to_string;
    return {
        status => 'ok',
        inputs => \%inputs,
        canonical_url => $canonical_url,
        redirect => $controller->req->url->to_string ne $canonical_url ? 1 : 0,
    };
}

sub _normalize {
    my ($type, $value) = @_;
    my $base = $type // '';
    $base =~ s/\?\z//;

    if ($base eq 'string') {
        return _invalid() unless defined($value) && !ref($value);
        my $bytes = eval { encode_utf8($value) };
        return _invalid() if $@;
        return _error('public_template_input_too_large',
            'Public template input is too large.')
            if length($bytes) > $MAX_STRING_BYTES;
        return {status => 'ok', value => "$value", query_value => "$value"};
    }

    if ($base eq 'integer') {
        return _invalid() unless _int64($value);
        return {status => 'ok', value => int($value), query_value => "$value"};
    }

    if ($base eq 'boolean') {
        return {status => 'ok', value => JSON::PP::true, query_value => 'true'}
            if defined($value) && !ref($value) && $value eq 'true';
        return {status => 'ok', value => JSON::PP::false, query_value => 'false'}
            if defined($value) && !ref($value) && $value eq 'false';
    }

    return _invalid();
}

sub _int64 {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value)
        && "$value" =~ /\A(?:0|-[1-9][0-9]*|[1-9][0-9]*)\z/;
    if ($value =~ /\A-(.+)\z/) {
        my $magnitude = $1;
        return length($magnitude) < 19
            || (length($magnitude) == 19 && $magnitude le $MIN_INTEGER_MAGNITUDE);
    }
    return length($value) < 19
        || (length($value) == 19 && $value le $MAX_INTEGER);
}

sub _invalid {
    return _error(
        'invalid_public_template_inputs',
        'Public template inputs are invalid.',
    );
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
