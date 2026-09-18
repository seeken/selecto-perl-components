package Selecto::Components::Graph::Colors;

use 5.034;
use strict;
use warnings;

my @DEFAULT = (
    '#55d6be', '#5b8ff9', '#f6bd16', '#e8684a', '#9270ca', '#6dc8ec',
    '#ff9d4d', '#269a99', '#ff99c3', '#5d7092', '#f08bb4', '#78d3f8',
);

sub normalize_hex {
    my ($class, $value) = @_;
    return undef unless defined($value) && !ref($value);
    return undef if "$value" eq '';
    return undef unless "$value" =~ /\A#[0-9a-fA-F]{6}\z/;
    return lc "$value";
}

sub palettes {
    my ($class, $host) = @_;
    $host = {} unless ref($host) eq 'HASH';
    my %palettes = (default => [@DEFAULT]);
    for my $id (sort keys %$host) {
        next unless $id =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
        next unless ref($host->{$id}) eq 'ARRAY' && @{$host->{$id}};
        my @colors = map { $class->normalize_hex($_) } @{$host->{$id}};
        next if grep { !defined } @colors;
        $palettes{$id} = \@colors;
    }
    return \%palettes;
}

sub resolve_series {
    my ($class, %args) = @_;
    my $explicit = $class->normalize_hex($args{color});
    return $explicit if defined $explicit;
    my $palettes = $class->palettes($args{palettes});
    my $id = $args{palette} // 'default';
    $id = 'default' if $id eq 'auto' || !exists($palettes->{$id});
    my $colors = $palettes->{$id};
    my $key = defined($args{series_id}) ? "$args{series_id}" : '';
    my $hash = 0;
    $hash = (($hash * 33) + ord($_)) & 0x7fffffff for split //, $key;
    return $colors->[$hash % @$colors];
}

sub valid_opacity {
    my ($class, $value) = @_;
    return 0 if !defined($value) || ref($value)
        || "$value" !~ /\A(?:0(?:\.\d+)?|1(?:\.0+)?)\z/;
    return 0 + $value >= 0 && 0 + $value <= 1 ? 1 : 0;
}

1;
