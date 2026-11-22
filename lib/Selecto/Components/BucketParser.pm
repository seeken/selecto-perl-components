package Selecto::Components::BucketParser;

use Mojo::Base -base, -signatures;
use Selecto::Limits ();

# The range kind a group format buckets by, or '' for a format that is not
# a range bucket.
my %GROUP_KINDS = (
    buckets => 'numeric_ranges', age_buckets => 'elapsed_days_ranges',
    custom_buckets => 'date_relative_ranges', year_buckets => 'year_ranges',
    month_buckets => 'month_ranges',
);
sub group_kind ($class, $format) { return $GROUP_KINDS{$format // ''} // ''; }

my @MONTHS = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# A month $ago calendar months before the current one, as "Sep 2026".
sub _month_label ($ago, $now) {
    my $index = $now->[0] * 12 + $now->[1] - $ago;
    return $MONTHS[$index % 12] . ' ' . int($index / 12);
}

# Month ranges count calendar months back: 0 is this month. "12-6" and
# "6-12" are the same range; the labels name the months, oldest first.
sub _month_ranges ($class, $input, $now) {
    my @parts = split /,/, "$input";
    my @ranges;
    for my $part (@parts) {
        $part =~ s/\A\s+|\s+\z//g;
        next unless length $part;
        my ($minimum, $maximum);
        if ($part =~ /\A(\d+)\s*-\s*(\d+)\z/) { ($minimum, $maximum) = $1 <= $2 ? ($1, $2) : ($2, $1) }
        elsif ($part =~ /\A(\d+)\z/) { ($minimum, $maximum) = ($1, $1) }
        elsif ($part =~ /\A(\d+)\+\z/) { $minimum = $1 }
        elsif ($part =~ /\A-(\d+)\z/) { $maximum = $1 }
        else { return [] }
        my $label = !defined($maximum) ? _month_label($minimum, $now) . ' and earlier'
            : !defined($minimum) ? _month_label($maximum, $now) . ' and later'
            : $minimum == $maximum ? _month_label($minimum, $now)
            # ASCII, so the label comes back from every driver as it was sent.
            : _month_label($maximum, $now) . ' - ' . _month_label($minimum, $now);
        push @ranges, {minimum => (defined($minimum) ? 0 + $minimum : undef),
            maximum => (defined($maximum) ? 0 + $maximum : undef), label => $label};
    }
    return \@ranges;
}

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
        # "-N" right after a range that ends at a number continues it:
        # "1, -4, -10, 21+" reads as "1, 2-4, 5-10, 21+". Leading, or after
        # an open or keyword range, it is still "N or less".
        my $previous = @ranges ? $ranges[-1]{maximum} : undef;
        my ($through) = $part =~ /\A-(\d+)\z/;
        if (defined($through) && defined($previous) && $previous =~ /\A\d+\z/ && $previous + 1 <= $through) {
            my $minimum = $previous + 1;
            push @ranges, { minimum => $minimum, maximum => 0 + $through,
                label => $minimum == $through ? "$through" : "$minimum-$through" };
        } elsif ($part =~ /\A(\d+)\z/) {
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

sub specification ($class, $input, $kind, $now = undef) {
    $kind //= 'numeric_ranges';
    if ($kind eq 'month_ranges') {
        # Bounded and checked as other ranges are; the labels need the month.
        return undef unless @{$class->parse($input =~ s/(\d+)\s*-\s*(\d+)/$1 <= $2 ? "$1-$2" : "$2-$1"/ger)};
        my @local = localtime;
        my $ranges = $class->_month_ranges($input, $now // [$local[5] + 1900, $local[4]]);
        return @$ranges ? {kind => $kind, ranges => $ranges} : undef;
    }
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
