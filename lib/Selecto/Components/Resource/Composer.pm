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

__END__

=head1 NAME

Selecto::Components::Resource::Composer - Compose the effective workspace for one request

=head1 SYNOPSIS

    use Selecto::Components::Resource::Composer;

    my $composer = Selecto::Components::Resource::Composer->new(
        registry  => $registry,
        authorize => sub ($request) {    # {capability, phase, kind, contribution, facts, context}
            return MyApp::Auth->can($request->{capability})
                ? {status => 'enabled'} : {status => 'hidden', reason_code => 'missing_privilege'};
        },
    );

    my $effective = $composer->compose(
        blueprint => {
            panels => [{id => 'core.overview', title => 'Overview'}, {slot => 'accounting'}],
            slots  => {accounting => {default_provider => 'core.accounting'}},
        },
        profile => {
            id => 'client.metro',
            providers => {accounting => 'metro.accounting'},
            enable    => ['metro.dispatch'],
            order     => {panels => [qw(core.overview metro.dispatch metro.accounting)]},
        },
        facts => {dispatch_enabled => 1},
    );
    # {panels => [...], badges => [...], field_groups => [...], actions => [...],
    #  validators => [...], after_commits => [...], trace => [...], profile_id => 'client.metro'}

=head1 DESCRIPTION

The composer turns a B<blueprint>, a B<profile> and request B<facts> into the
effective list of contributions from a
L<Selecto::Components::Resource::Registry>:

=over 4

=item * The blueprint lists base panels, and named C<slots> that are filled by
a provider. The profile's C<providers> choose the provider, and otherwise the
slot's C<default_provider> is used. An unknown or mismatched provider dies.

=item * Registry contributions are included when they are
C<enabled_by_default> or listed in the profile's C<enable>, and are not in its
C<disable>.

=item * A contribution applies only when its C<when> matches the facts (a
hash of expected values, or a callback that receives the facts). A
contribution with a C<capability> applies only when C<authorize> returns
C<enabled>.

=item * The profile's C<< order => {panels => [...]} >> fixes the panel order.
Panels that are not listed keep their relative order after the listed ones.

=back

Pruned contributions are left out without saying why in the result. The
C<trace> records each decision for diagnostics, so do not show it to end
users.

=head1 ATTRIBUTES

=head2 registry

Required. A L<Selecto::Components::Resource::Registry>.

=head2 authorize

A callback that returns C<< {status => 'enabled'|'disabled'|'hidden', reason_code} >>.
The default enables everything.

=head1 METHODS

=head2 compose

    my $effective = $composer->compose(blueprint => \%b, profile => \%p, facts => \%f, context => $any);

C<context> is passed through to C<authorize>.

=head1 SEE ALSO

L<Selecto::Components::Resource::Registry>, L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
