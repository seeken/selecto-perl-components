package Selecto::Components::QueryAssistant::Diff;

use 5.034;
use strict;
use warnings;

use Mojo::JSON qw(encode_json);

sub between {
    my ($class, $before, $after) = @_;
    my @changes;
    my %keys = map { $_ => 1 } (keys %{$before // {}}, keys %{$after // {}});
    for my $key (sort keys %keys) {
        my $old = encode_json($before->{$key});
        my $new = encode_json($after->{$key});
        next if $old eq $new;
        push @changes, {path => "/$key", before => $before->{$key}, after => $after->{$key}};
    }
    return \@changes;
}

1;
