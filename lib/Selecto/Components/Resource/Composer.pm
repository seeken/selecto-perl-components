package Selecto::Components::Resource::Composer;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Components::Resource::Registry ();

has 'registry';
has authorize => sub { return sub { return {status => 'enabled'} } };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    die "Resource composer requires a resource registry\n"
        unless blessed($self->registry)
            && $self->registry->isa('Selecto::Components::Resource::Registry');
    die "Resource composer authorize must be a callback\n"
        unless ref($self->authorize) eq 'CODE';
    return $self;
}

sub compose ($self, %args) {
    my $blueprint = $args{blueprint};
    my $profile = $args{profile} // {};
    my $facts = $args{facts} // {};
    die "Resource blueprint must be an object\n" unless ref($blueprint) eq 'HASH';
    die "Resource profile must be an object\n" unless ref($profile) eq 'HASH';
    die "Resource facts must be an object\n" unless ref($facts) eq 'HASH';
    my $panels = $blueprint->{panels} // [];
    my $slots = $blueprint->{slots} // {};
    die "Resource blueprint panels must be an array\n" unless ref($panels) eq 'ARRAY';
    die "Resource blueprint slots must be an object\n" unless ref($slots) eq 'HASH';
    my $providers = $profile->{providers} // {};
    die "Resource profile providers must be an object\n" unless ref($providers) eq 'HASH';
    my %enabled = map { _id($_, 'enabled contribution') => 1 }
        @{_array($profile->{enable}, 'profile enable')};
    my %disabled = map { _id($_, 'disabled contribution') => 1 }
        @{_array($profile->{disable}, 'profile disable')};

    my (@effective_panels, @trace);
    for my $entry (@$panels) {
        die "Resource blueprint panel entries must be objects\n"
            unless ref($entry) eq 'HASH';
        if (defined($entry->{slot})) {
            my $slot = _slot($entry->{slot});
            my $slot_spec = $slots->{$slot};
            die "Resource blueprint references unknown slot: $slot\n"
                unless ref($slot_spec) eq 'HASH';
            my $provider_id = $providers->{$slot}
                // $slot_spec->{default_provider};
            die "Resource slot $slot has no selected provider\n"
                unless defined($provider_id) && !ref($provider_id);
            $provider_id = _id($provider_id, "provider for slot $slot");
            my $provider = $self->registry->get(provider => $provider_id)
                or die "Unknown resource provider $provider_id for slot $slot\n";
            die "Resource provider $provider_id belongs to slot $provider->{slot}, not $slot\n"
                unless $provider->{slot} eq $slot;
            my ($accepted, $reason) = $self->_accepted(
                provider => $provider, $facts, \%args, \%disabled,
            );
            push @trace, {kind => 'provider', id => $provider_id, slot => $slot,
                accepted => $accepted ? 1 : 0, reason => $reason};
            push @effective_panels, $provider if $accepted;
            next;
        }
        my $panel = _copy($entry);
        $panel->{id} = _id($panel->{id}, 'blueprint panel');
        my ($accepted, $reason) = $self->_accepted(
            panel => $panel, $facts, \%args, \%disabled,
        );
        push @trace, {kind => 'panel', id => $panel->{id},
            accepted => $accepted ? 1 : 0, reason => $reason};
        push @effective_panels, $panel if $accepted;
    }

    for my $panel (@{$self->registry->all('panel')}) {
        next unless $panel->{enabled_by_default} || $enabled{$panel->{id}};
        my ($accepted, $reason) = $self->_accepted(
            panel => $panel, $facts, \%args, \%disabled,
        );
        push @trace, {kind => 'panel', id => $panel->{id},
            accepted => $accepted ? 1 : 0, reason => $reason};
        push @effective_panels, $panel if $accepted;
    }
    @effective_panels = _ordered(\@effective_panels, $profile->{order}{panels})
        if ref($profile->{order}) eq 'HASH';

    my %result = (panels => \@effective_panels, trace => \@trace);
    for my $kind (qw(badge field_group action validator after_commit)) {
        my @items;
        for my $item (@{$self->registry->all($kind)}) {
            next unless $item->{enabled_by_default} || $enabled{$item->{id}};
            my ($accepted, $reason) = $self->_accepted(
                $kind => $item, $facts, \%args, \%disabled,
            );
            push @trace, {kind => $kind, id => $item->{id},
                accepted => $accepted ? 1 : 0, reason => $reason};
            push @items, $item if $accepted;
        }
        $result{"${kind}s"} = \@items;
    }
    $result{profile_id} = "$profile->{id}"
        if defined($profile->{id}) && !ref($profile->{id});
    return \%result;
}

sub _accepted ($self, $kind, $item, $facts, $args, $disabled) {
    return (0, 'profile_disabled') if $disabled->{$item->{id}};
    return (0, 'not_applicable') unless _applies($item->{when}, $facts);
    my $capability = $item->{capability};
    return (1, 'enabled') unless defined($capability) && length("$capability");
    my $decision = $self->authorize->({
        capability => "$capability",
        phase => 'discovery',
        kind => $kind,
        contribution => $item,
        facts => $facts,
        context => $args->{context},
    });
    die "Resource authorization returned an invalid decision for $item->{id}\n"
        unless ref($decision) eq 'HASH'
            && ($decision->{status} // '') =~ /\A(?:enabled|disabled|hidden)\z/;
    return $decision->{status} eq 'enabled'
        ? (1, 'enabled')
        : (0, $decision->{reason_code} // 'capability_denied');
}

sub _applies ($when, $facts) {
    return 1 unless defined $when;
    return $when->($facts) ? 1 : 0 if ref($when) eq 'CODE';
    die "Resource applicability must be a callback or object\n"
        unless ref($when) eq 'HASH';
    for my $name (keys %$when) {
        my $expected = $when->{$name};
        my $actual = $facts->{$name};
        return 0 if defined($expected) != defined($actual);
        return 0 if defined($expected) && (ref($expected) || ref($actual)
            || "$expected" ne "$actual");
    }
    return 1;
}

sub _ordered ($items, $requested) {
    return @$items unless defined $requested;
    die "Resource panel order must be an array\n" unless ref($requested) eq 'ARRAY';
    my %rank;
    my $index = 0;
    for my $id (@$requested) {
        $id = _id($id, 'panel order');
        die "Duplicate resource panel order entry: $id\n" if exists $rank{$id};
        $rank{$id} = $index++;
    }
    # An otherwise valid panel may be absent after applicability or capability
    # pruning. Keep its configured rank inert rather than disclosing why it is
    # unavailable. Profile-definition validation can reject truly unknown IDs
    # before request-time composition.
    my %original = map { $items->[$_]{id} => $_ } 0 .. $#$items;
    return sort {
        (exists($rank{$a->{id}}) ? $rank{$a->{id}} : 1_000_000 + $original{$a->{id}})
            <=>
        (exists($rank{$b->{id}}) ? $rank{$b->{id}} : 1_000_000 + $original{$b->{id}})
    } @$items;
}

sub _array ($value, $label) {
    return [] unless defined $value;
    die "Resource $label must be an array\n" unless ref($value) eq 'ARRAY';
    return $value;
}

sub _id ($value, $label) {
    die "Resource $label ID is invalid\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/;
    return "$value";
}

sub _slot ($value) {
    die "Resource slot is invalid\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/;
    return "$value";
}

sub _copy ($value) {
    return $value unless ref($value);
    return [map { _copy($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _copy($value->{$_}) } keys %$value}
        if ref($value) eq 'HASH';
    return $value;
}

1;
