package Selecto::Components::BucketParser;

use Mojo::Base -base, -signatures;

sub parse ($class, $input) {
    return [] unless defined($input) && !ref($input);
    my @ranges;
    for my $part (split /,/, "$input") {
        $part =~ s/\A\s+|\s+\z//g;
        next unless length($part);
        if ($part =~ /\A(\d+)\z/) {
            push @ranges, { minimum => 0 + $1, maximum => 0 + $1, label => "$1" };
        } elsif ($part =~ /\A(\d+)-(\d+)\z/ && $1 <= $2) {
            push @ranges, { minimum => 0 + $1, maximum => 0 + $2, label => "$1-$2" };
        } elsif ($part =~ /\A(\d+)\+\z/) {
            push @ranges, { minimum => 0 + $1, maximum => undef, label => "$1+" };
        } elsif ($part =~ /\A-(\d+)\z/) {
            push @ranges, { minimum => undef, maximum => 0 + $1, label => "\x{2264}$1" };
        } elsif ($part =~ /\A(today|yesterday|tomorrow)\z/i) {
            my $keyword = lc($1);
            push @ranges, { minimum => $keyword, maximum => $keyword, label => $keyword };
        }
    }
    return \@ranges;
}

sub increment ($class, $input) {
    return undef unless defined($input) && !ref($input) && "$input" =~ /\A\s*\*\/(\d+)\s*\z/;
    return $1 > 0 ? 0 + $1 : undef;
}

sub specification ($class, $input, $kind) {
    $kind //= 'numeric_ranges';
    if (($kind eq 'numeric_ranges' || $kind eq 'year_ranges') && defined(my $increment = $class->increment($input))) {
        return {
            kind => $kind eq 'year_ranges' ? 'year_increment' : 'numeric_increment',
            increment => $increment,
        };
    }
    my $ranges = $class->parse($input);
    if ($kind ne 'date_relative_ranges') {
        $ranges = [grep {
            (!defined($_->{minimum}) || $_->{minimum} =~ /\A\d+\z/)
                && (!defined($_->{maximum}) || $_->{maximum} =~ /\A\d+\z/)
        } @$ranges];
    }
    return undef unless @$ranges;
    return { kind => $kind, ranges => $ranges };
}

sub valid ($class, $input, $kind) {
    return defined $class->specification($input, $kind) ? 1 : 0;
}

1;
