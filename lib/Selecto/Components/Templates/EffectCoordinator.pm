package Selecto::Components::Templates::EffectCoordinator;

use 5.034;
use strict;
use warnings;

use Selecto::Templates ();

=head1 NAME

Selecto::Components::Templates::EffectCoordinator - Persist template effect completions

=head1 DESCRIPTION

Claims one source generation before execution and applies its completion through
the portable reducer and shared instance transition boundary. Source execution
remains in C<SourceExecutor>, outside the short claim transaction.

=cut

sub new {
    my ($class, %args) = @_;
    die "invalid_instance_service: template effect coordinator requires an instance service\n"
        unless ref($args{instance_service}) && $args{instance_service}->can('transition');
    return bless {instances => $args{instance_service}}, $class;
}

sub claim_effect {
    my ($self, %args) = @_;
    my $effect = $args{effect};
    return _error('invalid_effect', 'template source effect is invalid')
        unless _valid_effect($effect, $args{instance_id});
    return $self->{instances}->claim_effect(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
        source => $effect->{source},
        generation => $effect->{generation},
        effect_id => $effect->{effect_id},
        lease_seconds => $args{lease_seconds},
    );
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

sub complete_claimed_effect {
    my ($self, %args) = @_;
    my $completion = $args{completion};
    return _error('invalid_completion', 'template source completion is invalid')
        unless _valid_completion($completion, $args{instance_id});
    return $self->{instances}->claimed_transition(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
        source => $completion->{source},
        generation => $completion->{generation},
        effect_id => $completion->{effect_id},
        claim_token => $args{claim_token},
        transition => sub {
            my ($snapshot) = @_;
            return Selecto::Templates->complete_runtime(
                $args{manifest}, $snapshot, $completion,
            );
        },
    );
}

sub release_effect_claim {
    my ($self, %args) = @_;
    my $effect = $args{effect};
    return _error('invalid_effect', 'template source effect is invalid')
        unless _valid_effect($effect, $args{instance_id});
    return $self->{instances}->release_effect_claim(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
        source => $effect->{source},
        generation => $effect->{generation},
        effect_id => $effect->{effect_id},
        claim_token => $args{claim_token},
    );
}

sub _valid_effect {
    my ($effect, $instance_id) = @_;
    return ref($effect) eq 'HASH'
        && ($effect->{schema} // '') eq 'selecto.template.runtime-effect.v1'
        && ($effect->{kind} // '') eq 'load_source'
        && defined($instance_id) && !ref($instance_id) && length("$instance_id")
        && defined($effect->{source}) && !ref($effect->{source}) && length("$effect->{source}")
        && defined($effect->{generation}) && !ref($effect->{generation})
        && "$effect->{generation}" =~ /\A[1-9][0-9]*\z/
        && defined($effect->{effect_id}) && !ref($effect->{effect_id})
        && "$effect->{effect_id}" eq
            "$instance_id:source:$effect->{source}:$effect->{generation}"
        && ref($effect->{bindings}) eq 'HASH'
        && ref($effect->{bindings}{input}) eq 'HASH'
        && ref($effect->{bindings}{state}) eq 'HASH';
}

sub _valid_completion {
    my ($completion, $instance_id) = @_;
    return ref($completion) eq 'HASH'
        && ($completion->{schema} // '') eq 'selecto.template.runtime-completion.v1'
        && defined($instance_id) && !ref($instance_id) && length("$instance_id")
        && defined($completion->{instance_id}) && !ref($completion->{instance_id})
        && "$completion->{instance_id}" eq "$instance_id"
        && defined($completion->{source}) && !ref($completion->{source})
        && length("$completion->{source}")
        && defined($completion->{generation}) && !ref($completion->{generation})
        && "$completion->{generation}" =~ /\A[1-9][0-9]*\z/
        && defined($completion->{effect_id}) && !ref($completion->{effect_id})
        && "$completion->{effect_id}" eq
            "$instance_id:source:$completion->{source}:$completion->{generation}";
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
