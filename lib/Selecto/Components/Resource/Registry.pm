package Selecto::Components::Resource::Registry;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;

my %KINDS = map { $_ => 1 } qw(
    panel provider badge field_group action validator after_commit
);

has _entries => sub { return {map { $_ => {} } sort keys %KINDS} };
has _frozen => 0;

sub register ($self, $kind, $id, $spec) {
    die "Resource contribution kind is not supported: $kind\n"
        unless defined($kind) && !ref($kind) && $KINDS{$kind};
    die "Resource contribution ID must be namespaced: $id\n"
        unless defined($id) && !ref($id)
            && "$id" =~ /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/;
    die "Resource contribution $kind $id must be an object\n"
        unless ref($spec) eq 'HASH';
    die "Resource registry is frozen\n" if $self->_frozen;
    die "Duplicate resource $kind contribution: $id\n"
        if exists $self->_entries->{$kind}{$id};
    if ($kind eq 'provider') {
        my $slot = $spec->{slot};
        die "Resource provider $id requires a valid slot\n"
            unless defined($slot) && !ref($slot)
                && "$slot" =~ /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/;
    }
    $self->_entries->{$kind}{$id} = _copy({id => "$id", %$spec});
    return $self;
}

sub register_panel ($self, $id, $spec) { return $self->register(panel => $id, $spec) }
sub register_provider ($self, $id, $spec) { return $self->register(provider => $id, $spec) }
sub register_badge ($self, $id, $spec) { return $self->register(badge => $id, $spec) }
sub register_field_group ($self, $id, $spec) { return $self->register(field_group => $id, $spec) }
sub register_action ($self, $id, $spec) { return $self->register(action => $id, $spec) }
sub register_validator ($self, $id, $spec) { return $self->register(validator => $id, $spec) }
sub register_after_commit ($self, $id, $spec) { return $self->register(after_commit => $id, $spec) }

sub get ($self, $kind, $id) {
    return undef unless $KINDS{$kind} && defined($id) && !ref($id);
    my $entry = $self->_entries->{$kind}{"$id"};
    return defined($entry) ? _copy($entry) : undef;
}

sub all ($self, $kind) {
    die "Resource contribution kind is not supported: $kind\n"
        unless defined($kind) && !ref($kind) && $KINDS{$kind};
    return [map { _copy($self->_entries->{$kind}{$_}) }
        sort keys %{$self->_entries->{$kind}}];
}

sub freeze ($self) {
    $self->_frozen(1);
    return $self;
}

sub frozen ($self) { return $self->_frozen ? 1 : 0 }

sub _copy ($value) {
    return $value unless ref($value);
    return [map { _copy($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _copy($value->{$_}) } keys %$value}
        if ref($value) eq 'HASH';
    return $value;
}

1;
