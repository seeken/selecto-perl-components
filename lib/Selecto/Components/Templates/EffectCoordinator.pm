package Selecto::Components::Templates::EffectCoordinator;

use 5.034;
use strict;
use warnings;

use Selecto::Templates ();

=head1 NAME

Selecto::Components::Templates::EffectCoordinator - Persist template effect completions

=head1 DESCRIPTION

Applies source completions through the portable reducer and the shared instance
transition boundary. Source execution remains in C<SourceExecutor>; effect
claiming and leasing can be added here without expanding the public dispatcher.

=cut

sub new {
    my ($class, %args) = @_;
    die "invalid_instance_service: template effect coordinator requires an instance service\n"
        unless ref($args{instance_service}) && $args{instance_service}->can('transition');
    return bless {instances => $args{instance_service}}, $class;
}

sub complete {
    my ($self, %args) = @_;
    return $self->{instances}->transition(
        %args,
        transition => sub {
            my ($snapshot) = @_;
            return Selecto::Templates->complete_runtime(
                $args{manifest}, $snapshot, $args{completion},
            );
        },
    );
}

1;
