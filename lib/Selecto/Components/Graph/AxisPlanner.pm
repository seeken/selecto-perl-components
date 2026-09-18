package Selecto::Components::Graph::AxisPlanner;

use 5.034;
use strict;
use warnings;

use Selecto::Analytics::UnitRegistry ();

sub plan {
    my ($class, $series) = @_;
    die "graph series must be an array\n" unless ref($series) eq 'ARRAY';

    my @planned = map { +{%$_} } @$series;
    my %signature_for_axis;
    my @errors;

    # Reserve manually selected axes first so an earlier automatic series does
    # not unexpectedly displace an explicit choice later in the list.
    for my $item (@planned) {
        my $requested = $item->{axis} // 'auto';
        next if $requested eq 'auto';
        my $signature = _signature($item->{unit});
        if (defined($signature_for_axis{$requested})
            && $signature_for_axis{$requested} ne $signature) {
            push @errors, ucfirst($requested) .
                ' graph axis contains measures with incompatible units.';
            next;
        }
        $signature_for_axis{$requested} = $signature;
        $item->{resolved_axis} = $requested;
    }

    for my $item (@planned) {
        next if defined($item->{resolved_axis});
        my $signature = _signature($item->{unit});
        my ($compatible) = grep {
            defined($signature_for_axis{$_})
                && $signature_for_axis{$_} eq $signature
        } qw(left right);
        if ($compatible) {
            $item->{resolved_axis} = $compatible;
            next;
        }
        my ($empty) = grep { !defined($signature_for_axis{$_}) } qw(left right);
        if ($empty) {
            $signature_for_axis{$empty} = $signature;
            $item->{resolved_axis} = $empty;
            next;
        }
        push @errors,
            'A graph can use at most two incompatible Y-axis units; normalize or remove a measure.';
        $item->{resolved_axis} = 'left';
    }

    return {series => \@planned, errors => \@errors};
}

sub _signature {
    my ($unit) = @_;
    return '__untyped__' unless defined $unit;
    return Selecto::Analytics::UnitRegistry->signature($unit);
}

1;
