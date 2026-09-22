package Selecto::Components::Templates::Dispatcher;

use 5.034;
use strict;
use warnings;

use Selecto::Templates ();
use Selecto::Components::Templates::Event ();

sub new {
    my ($class, %args) = @_;
    die "invalid_store: template dispatcher requires an instance store\n"
        unless ref($args{store}) && $args{store}->can('load')
        && $args{store}->can('compare_and_set');
    return bless {store => $args{store}}, $class;
}

sub mount {
    my ($self, %args) = @_;
    my $instance_id = $self->{store}->new_instance_id;
    my $runtime = _runtime(sub {
        Selecto::Templates->mount_runtime(
            $args{manifest},
            instance_id => $instance_id,
            release_id => $args{release_id},
            inputs => $args{inputs} // {},
        );
    });
    return $runtime unless $runtime->{status} eq 'ok';

    my $created = eval {
        $self->{store}->create(
            owner_scope => $args{owner_scope},
            release => $args{release_id},
            initial_snapshot => $runtime->{observation}{snapshot},
            expires_at => $args{expires_at},
            instance_id => $instance_id,
        );
    };
    return _exception($@) if $@;
    return {
        status => 'ok',
        instance_id => $created,
        store_revision => 0,
        observation => $runtime->{observation},
    };
}

sub load {
    my ($self, %args) = @_;
    return $self->{store}->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
}

sub dispatch {
    my ($self, %args) = @_;
    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';

    my $snapshot = $loaded->{snapshot};
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
    my $runtime = _runtime(sub {
        Selecto::Templates->dispatch_runtime($args{manifest}, $snapshot, $event);
    });
    return $runtime unless $runtime->{status} eq 'ok';
    return $self->_commit_observation($loaded, \%args, $runtime->{observation});
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

sub complete {
    my ($self, %args) = @_;
    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';

    my $runtime = _runtime(sub {
        Selecto::Templates->complete_runtime(
            $args{manifest}, $loaded->{snapshot}, $args{completion},
        );
    });
    return $runtime unless $runtime->{status} eq 'ok';
    return $self->_commit_observation($loaded, \%args, $runtime->{observation});
}

sub dispose {
    my ($self, %args) = @_;
    return $self->{store}->dispose(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
}

sub _commit_observation {
    my ($self, $loaded, $args, $observation) = @_;
    return {
        status => 'ok',
        store_revision => $loaded->{revision},
        observation => $observation,
    } unless ($observation->{outcome} // '') eq 'accepted';

    my $stored = $self->{store}->compare_and_set(
        owner_scope => $args->{owner_scope},
        instance_id => $args->{instance_id},
        revision => $loaded->{revision},
        next_snapshot => $observation->{snapshot},
    );
    return $stored unless $stored->{status} eq 'ok';
    return {
        status => 'ok',
        store_revision => $stored->{revision},
        observation => $observation,
    };
}

sub _runtime {
    my ($operation) = @_;
    my $observation = eval { $operation->() };
    return _exception($@) if $@;
    return {status => 'ok', observation => $observation};
}

sub _exception {
    my ($error) = @_;
    chomp $error;
    my ($code, $message) = $error =~ /\A([a-z0-9_]+):\s*(.*)\z/s;
    return {
        status => 'error',
        code => $code // 'template_runtime_error',
        message => $message // $error,
    };
}

1;
