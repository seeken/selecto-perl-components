package Selecto::Components::Templates::SourceExecutor;

use 5.034;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use Selecto::Templates ();

=head1 NAME

Selecto::Components::Templates::SourceExecutor - Execute compiled source intent with fresh host authority

=head1 DESCRIPTION

The manifest chooses bounded query intent. The host authorization callback is
invoked for every effect and supplies a freshly scoped C<Selecto::Engine> plus
its host query. Neither tenant authority nor a database handle comes from the
template artifact or browser request.

=cut

sub execute {
    my ($class, %args) = @_;
    my $manifest = $args{manifest};
    my $effect = $args{effect};
    my $authorize = $args{authorize};
    my $run = $args{run};

    return _error('invalid_source_effect', 'template source effect is invalid')
        unless _valid_effect($effect)
        && ref($manifest) eq 'HASH' && ref($manifest->{sources}) eq 'ARRAY';
    return _error('invalid_source_executor', 'template source executor is invalid')
        unless ref($authorize) eq 'CODE' && (!defined($run) || ref($run) eq 'CODE');

    my ($source) = grep {
        ref($_) eq 'HASH' && defined($_->{id}) && $_->{id} eq $effect->{source}
    } @{$manifest->{sources}};
    return _error('unknown_source', 'template source is not declared') unless $source;

    my ($authority, $authorization_exception);
    {
        local $@;
        my $ok = eval {
            $authority = $authorize->($source, $effect);
            1;
        };
        $authorization_exception = $@ unless $ok;
    }
    return _error('source_authorization_failed', 'template source authorization failed')
        if defined($authorization_exception)
        || ref($authority) ne 'HASH'
        || ($authority->{status} // '') ne 'ok'
        || !blessed($authority->{engine})
        || !$authority->{engine}->isa('Selecto::Engine')
        || !blessed($authority->{query})
        || !$authority->{query}->isa('Selecto::Query');

    my ($lowered, $lowering_exception);
    {
        local $@;
        my $ok = eval {
            $lowered = Selecto::Templates->lower_query(
                source => $source,
                engine => $authority->{engine},
                query => $authority->{query},
                bindings => $effect->{bindings},
            );
            1;
        };
        $lowering_exception = $@ unless $ok;
    }
    if (defined($lowering_exception)) {
        return {
            status => 'error',
            %{$lowering_exception->as_hash},
        } if blessed($lowering_exception)
            && $lowering_exception->isa('Selecto::Templates::QueryLoweringDiagnostic');
        return _error('source_lowering_failed', 'template source lowering failed');
    }

    my ($native, $execution_exception);
    {
        local $@;
        my $ok = eval {
            $native = defined($run)
                ? $run->($authority->{engine}, $lowered->{query}, $effect)
                : $authority->{engine}->all($lowered->{query});
            1;
        };
        $execution_exception = $@ unless $ok;
    }
    return _error('source_execution_failed', 'template source execution failed')
        if defined($execution_exception)
        || ref($native) ne 'HASH' || ref($native->{rows}) ne 'ARRAY';

    my ($projected, $projection_exception);
    {
        local $@;
        my $ok = eval {
            $projected = Selecto::Templates->project_rows(
                $lowered->{result_shape}, $native->{rows},
            );
            1;
        };
        $projection_exception = $@ unless $ok;
    }
    return _error('invalid_source_result', 'template source result is invalid')
        if defined($projection_exception);

    return {status => 'ok', result => $projected};
}

sub _valid_effect {
    my ($effect) = @_;
    return ref($effect) eq 'HASH'
        && ($effect->{schema} // '') eq 'selecto.template.runtime-effect.v1'
        && ($effect->{kind} // '') eq 'load_source'
        && defined($effect->{effect_id}) && !ref($effect->{effect_id}) && length($effect->{effect_id})
        && defined($effect->{source}) && !ref($effect->{source}) && length($effect->{source})
        && defined($effect->{generation}) && !ref($effect->{generation})
        && "$effect->{generation}" =~ /\A[1-9][0-9]*\z/
        && ref($effect->{bindings}) eq 'HASH'
        && ref($effect->{bindings}{input}) eq 'HASH'
        && ref($effect->{bindings}{state}) eq 'HASH';
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
