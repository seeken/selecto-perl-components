package Selecto::Components::Templates::EventDispatcher;

use 5.034;
use strict;
use warnings;

use Selecto::Templates ();
use Selecto::Components::Templates::Event ();

=head1 NAME

Selecto::Components::Templates::EventDispatcher - Apply typed template events

=cut

sub new {
    my ($class, %args) = @_;
    die "invalid_instance_service: template event dispatcher requires an instance service\n"
        unless ref($args{instance_service}) && $args{instance_service}->can('transition');
    return bless {instances => $args{instance_service}}, $class;
}

sub dispatch {
    my ($self, %args) = @_;
    return $self->{instances}->transition(
        %args,
        transition => sub {
            my ($snapshot) = @_;
            my $event = {
                schema => 'selecto.template.runtime-event.v1',
                instance_id => $snapshot->{instance_id},
                release_id => $snapshot->{release_id},
                event_id => $args{event_id},
                name => $args{name},
                expected_state_revision => exists($args{expected_state_revision})
                    ? $args{expected_state_revision} : $snapshot->{state_revision},
                payload => $args{payload},
            };
            return Selecto::Templates->dispatch_runtime(
                $args{manifest}, $snapshot, $event,
            );
        },
    );
}

sub dispatch_params {
    my ($self, %args) = @_;
    my $normalized = Selecto::Components::Templates::Event->normalize(
        $args{manifest}, $args{name}, $args{params},
    );
    return $normalized unless $normalized->{status} eq 'ok';
    delete $args{params};
    $args{payload} = $normalized->{payload};
    return $self->dispatch(%args);
}

1;
