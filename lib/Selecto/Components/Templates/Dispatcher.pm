package Selecto::Components::Templates::Dispatcher;

use 5.034;
use strict;
use warnings;

use Selecto::Components::Templates::EffectCoordinator ();
use Selecto::Components::Templates::EventDispatcher ();
use Selecto::Components::Templates::InstanceService ();

=head1 NAME

Selecto::Components::Templates::Dispatcher - Stable template runtime facade

=head1 DESCRIPTION

Preserves the original host API while delegating instance persistence, browser
events, and effect completions to focused modules.

=cut

sub new {
    my ($class, %args) = @_;
    my $instances = Selecto::Components::Templates::InstanceService->new(
        store => $args{store},
    );
    return bless {
        instances => $instances,
        events => Selecto::Components::Templates::EventDispatcher->new(
            instance_service => $instances,
        ),
        effects => Selecto::Components::Templates::EffectCoordinator->new(
            instance_service => $instances,
        ),
    }, $class;
}

sub mount {
    my ($self, %args) = @_;
    return $self->{instances}->mount(%args);
}

sub load {
    my ($self, %args) = @_;
    return $self->{instances}->load(%args);
}

sub dispatch {
    my ($self, %args) = @_;
    return $self->{events}->dispatch(%args);
}

sub dispatch_params {
    my ($self, %args) = @_;
    return $self->{events}->dispatch_params(%args);
}

sub complete {
    my ($self, %args) = @_;
    return $self->{effects}->complete(%args);
}

sub dispose {
    my ($self, %args) = @_;
    return $self->{instances}->dispose(%args);
}

1;
