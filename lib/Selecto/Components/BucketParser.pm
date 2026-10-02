package Selecto::Components::BucketParser;

use Mojo::Base -base, -signatures;
use Selecto::Limits ();

sub parse ($class, $input) {
    return [] unless defined($input) && !ref($input);
    my $limits = Selecto::Limits->new;
    return [] unless eval {
        $limits->check_bytes('max_bucket_bytes', $input, 'invalid_query', 'Bucket input');
        1;
    };
    my @parts = split /,/, "$input", $limits->get('max_bucket_ranges') + 1;
    return [] if @parts > $limits->get('max_bucket_ranges');
    my $digits = $limits->get('max_numeric_digits');
    return [] if grep { length($_) > $digits } "$input" =~ /([0-9]+)/g;
    my @ranges;
    for my $part (@parts) {
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
    return undef if length($1) > Selecto::Limits->new->get('max_numeric_digits');
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

__END__

=head1 NAME

Selecto::Components::BucketParser - Parse numeric and date bucket range specifications

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
