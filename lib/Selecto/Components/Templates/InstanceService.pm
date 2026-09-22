package Selecto::Components::Templates::InstanceService;

use 5.034;
use strict;
use warnings;

use Selecto::Templates ();

=head1 NAME

Selecto::Components::Templates::InstanceService - Persist template runtime transitions

=head1 DESCRIPTION

Owns template instance allocation, scoped loading, revisioned persistence, and
disposal. Event parsing and source-effect coordination remain outside this
module. Store exceptions are converted to one bounded public error.

=cut

sub new {
    my ($class, %args) = @_;
    die "invalid_store: template instance service requires an instance store\n"
        unless ref($args{store})
        && !grep { !$args{store}->can($_) }
            qw(new_instance_id create load compare_and_set dispose);
    return bless {store => $args{store}}, $class;
}

sub mount {
    my ($self, %args) = @_;
    my $allocated = _store(sub { $self->{store}->new_instance_id });
    return $allocated unless $allocated->{status} eq 'ok';
    my $instance_id = $allocated->{value};
    my $runtime = _runtime(sub {
        Selecto::Templates->mount_runtime(
            $args{manifest},
            instance_id => $instance_id,
            release_id => $args{release_id},
            inputs => $args{inputs} // {},
        );
    });
    return $runtime unless $runtime->{status} eq 'ok';

    my $stored = _store(sub {
        $self->{store}->create(
            owner_scope => $args{owner_scope},
            release => $args{release_id},
            initial_snapshot => $runtime->{observation}{snapshot},
            expires_at => $args{expires_at},
            instance_id => $instance_id,
        );
    });
    return $stored unless $stored->{status} eq 'ok';
    return {
        status => 'ok',
        instance_id => $stored->{value},
        store_revision => 0,
        observation => $runtime->{observation},
    };
}

sub load {
    my ($self, %args) = @_;
    my $stored = _store(sub {
        $self->{store}->load(
            owner_scope => $args{owner_scope},
            instance_id => $args{instance_id},
        );
    });
    return $stored->{status} eq 'ok' ? $stored->{value} : $stored;
}

sub transition {
    my ($self, %args) = @_;
    my $transition = delete $args{transition};
    return _invalid_transition() unless ref($transition) eq 'CODE';

    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';

    my $runtime = _runtime(sub { $transition->($loaded->{snapshot}) });
    return $runtime unless $runtime->{status} eq 'ok';
    return $self->_commit_observation($loaded, \%args, $runtime->{observation});
}

sub claim_effect {
    my ($self, %args) = @_;
    return _unsupported_claims()
        unless $self->{store}->can('claim_effect');
    my $claimed = _store(sub { $self->{store}->claim_effect(%args) });
    return $claimed->{status} eq 'ok' ? $claimed->{value} : $claimed;
}

sub claimed_transition {
    my ($self, %args) = @_;
    my $transition = delete $args{transition};
    return _invalid_transition() unless ref($transition) eq 'CODE';
    return _unsupported_claims()
        unless $self->{store}->can('commit_claimed_effect')
        && $self->{store}->can('release_effect_claim');

    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';
    my $runtime = _runtime(sub { $transition->($loaded->{snapshot}) });
    if ($runtime->{status} ne 'ok') {
        $self->release_effect_claim(%args);
        return $runtime;
    }

    my $observation = $runtime->{observation};
    if (($observation->{outcome} // '') ne 'accepted') {
        my $released = $self->release_effect_claim(%args);
        return $released unless $released->{status} eq 'ok';
        return {
            status => 'ok',
            store_revision => $loaded->{revision},
            observation => $observation,
        };
    }

    my $committed = _store(sub {
        $self->{store}->commit_claimed_effect(
            owner_scope => $args{owner_scope},
            instance_id => $args{instance_id},
            source => $args{source},
            generation => $args{generation},
            effect_id => $args{effect_id},
            claim_token => $args{claim_token},
            revision => $loaded->{revision},
            next_snapshot => $observation->{snapshot},
        );
    });
    return $committed unless $committed->{status} eq 'ok';
    my $stored = $committed->{value};
    return $stored unless $stored->{status} eq 'ok';
    return {
        status => 'ok',
        store_revision => $stored->{revision},
        observation => $observation,
    };
}

sub release_effect_claim {
    my ($self, %args) = @_;
    return _unsupported_claims()
        unless $self->{store}->can('release_effect_claim');
    my $released = _store(sub { $self->{store}->release_effect_claim(%args) });
    return $released->{status} eq 'ok' ? $released->{value} : $released;
}

sub dispose {
    my ($self, %args) = @_;
    my $stored = _store(sub {
        $self->{store}->dispose(
            owner_scope => $args{owner_scope},
            instance_id => $args{instance_id},
        );
    });
    return $stored->{status} eq 'ok' ? $stored->{value} : $stored;
}

sub _commit_observation {
    my ($self, $loaded, $args, $observation) = @_;
    return {
        status => 'ok',
        store_revision => $loaded->{revision},
        observation => $observation,
    } unless ($observation->{outcome} // '') eq 'accepted';

    my $operation = _store(sub {
        $self->{store}->compare_and_set(
            owner_scope => $args->{owner_scope},
            instance_id => $args->{instance_id},
            revision => $loaded->{revision},
            next_snapshot => $observation->{snapshot},
        );
    });
    return $operation unless $operation->{status} eq 'ok';
    my $stored = $operation->{value};
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

sub _store {
    my ($operation) = @_;
    my $value = eval { $operation->() };
    return {
        status => 'error',
        code => 'instance_store_unavailable',
        message => 'template instance store is unavailable',
    } if $@;
    return {status => 'ok', value => $value};
}

sub _invalid_transition {
    return {
        status => 'error',
        code => 'invalid_instance_transition',
        message => 'template instance transition is invalid',
    };
}

sub _unsupported_claims {
    return {
        status => 'error',
        code => 'effect_claiming_unavailable',
        message => 'template effect claiming is unavailable',
    };
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
