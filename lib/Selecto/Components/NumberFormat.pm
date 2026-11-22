package Selecto::Components::NumberFormat;

use Mojo::Base -strict, -signatures;
use Math::BigFloat ();

# This is presentation metadata only. Never replace a query/result value.
sub profile ($class, $column) {
    return undef unless $column->{measure};
    my $function = $column->{function} // '';
    my $series = $column->{series} // {};
    # Tables contain aggregates, including the graph's raw-data table.
    my $unit = $series->{raw_unit} // $series->{unit} // {};
    my $kind = $unit->{kind} // '';
    my $percentage = $kind eq 'percentage' || $function eq 'true_percentage';
    return undef unless $percentage || ($column->{type} // '') =~
        /\A(?:integer|int|smallint|bigint|id|decimal|number|numeric|float|double|real)\z/i;
    my $count = $function =~ /\A(?:count|count_distinct|true_count|false_count|buckets|age_buckets)\z/;
    my $places = $percentage ? 1 : $count ? 0 : $kind eq 'currency' ? 2
        : $kind eq 'duration' ? (($column->{type} // '') =~ /\A(?:integer|int|smallint|bigint)\z/i ? 0 : 1)
        : $function eq 'avg' ? 2
        : ($column->{type} // '') =~ /\A(?:integer|int|smallint|bigint|id)\z/i ? 0 : 2;
    my $fixed = $percentage || $count || $kind eq 'currency' || $kind eq 'duration' || !$places;
    my $override = ($column->{display} // {})->{decimals};
    if (defined($override) && !ref($override) && "$override" =~ /\A(?:[0-9]|1[0-5])\z/) {
        $places = 0 + $override;
        $fixed = 1;
    }
    return {decimals => $places, fixed => $fixed ? 1 : 0,
        percentage => $percentage ? 1 : 0,
        fraction => $percentage && $function ne 'true_percentage'
            && ($unit->{scale} // 'fraction') eq 'fraction' ? 1 : 0};
}

sub numeric ($class, $value) {
    return defined($value) && !ref($value) && "$value" =~
        /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/;
}

sub _rounded ($value, $profile) {
    my $number = Math::BigFloat->new("$value");
    $number->bmul(100) if $profile->{fraction};
    return $number->bfround(-$profile->{decimals}, 'common')->bstr;
}

# Optional decimals drop only when the whole displayed measure permits it.
# Every row (including pivot cells and totals) then uses the same precision.
sub prepare ($class, $column, $values) {
    delete $column->{display_precision};
    my $profile = $class->profile($column) or return;
    return if $profile->{fixed};
    my $places = 0;
    for my $value (@$values) {
        next unless $class->numeric($value);
        my $rounded = _rounded($value, $profile);
        $rounded =~ s/0+\z// if $rounded =~ /\./;
        my ($fraction) = $rounded =~ /\.(\d+)/;
        my $length = length($fraction // '');
        $places = $length if $length > $places;
    }
    $column->{display_precision} = $places;
}

sub format ($class, $column, $value) {
    my $profile = $class->profile($column) or return undef;
    return undef unless $class->numeric($value);
    my $rounded = _rounded($value, $profile);
    my ($whole, $fraction) = split /\./, $rounded, 2;
    $fraction //= '';
    my $places = $profile->{fixed} ? $profile->{decimals} : $column->{display_precision};
    if (!defined($places)) {
        $fraction =~ s/0+\z//;
        $places = length($fraction);
    }
    $fraction = substr($fraction . ('0' x $places), 0, $places);
    $whole =~ s/(?<=\d)(?=(?:\d{3})+\z)/,/g;
    return $whole . ($places ? ".$fraction" : '') . ($profile->{percentage} ? '%' : '');
}

sub xlsx_format ($class, $column) {
    my $profile = $class->profile($column) or return undef;
    my $decimal = $profile->{decimals} ? '.' . ('0' x $profile->{decimals}) : '';
    # SQL percent-true and analytics transforms use whole percentages. A
    # literal percent sign keeps their raw numeric value in the workbook.
    return '0' . $decimal . ($profile->{fraction} ? '%' : '"%"') if $profile->{percentage};
    return '#,##0' . $decimal;
}

1;

__END__

=head1 NAME

Selecto::Components::NumberFormat - Numeric measure presentation for tables and exports

=head1 DESCRIPTION

Internal fixed en-US measure formatting. Source values are never rounded or replaced.

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.
This is free software, licensed under:
The Artistic License 2.0 (GPL Compatible)

=cut
