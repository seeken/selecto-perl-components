package Selecto::Components::Templates::SourceScheduler;

use 5.034;
use strict;
use warnings;

use JSON::PP ();
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;

=head1 NAME

Selecto::Components::Templates::SourceScheduler - Bounded subprocess execution for template sources

=head1 DESCRIPTION

Runs one JSON-safe source payload in a child process so synchronous DBI work does
not block the Mojolicious event loop. The scheduler bounds concurrent children,
payload/result sizes, and elapsed execution time. Only the typed result returns to
the parent process.

=cut

sub new {
    my ($class, %args) = @_;
    my $max_workers = _positive_integer(
        $args{max_workers} // 4, 64, 'max_workers',
    );
    my $timeout_seconds = _positive_number(
        $args{timeout_seconds} // 15, 300, 'timeout_seconds',
    );
    my $term_grace_seconds = _positive_number(
        $args{term_grace_seconds} // 0.25, 5, 'term_grace_seconds',
    );
    my $max_payload_bytes = _positive_integer(
        $args{max_payload_bytes} // 1_048_576, 16_777_216,
        'max_payload_bytes',
    );
    my $max_result_bytes = _positive_integer(
        $args{max_result_bytes} // 1_048_576, 16_777_216,
        'max_result_bytes',
    );
    return bless {
        max_workers => $max_workers,
        timeout_seconds => $timeout_seconds,
        term_grace_seconds => $term_grace_seconds,
        max_payload_bytes => $max_payload_bytes,
        max_result_bytes => $max_result_bytes,
        active_workers => 0,
        json => JSON::PP->new->canonical->allow_nonref(0),
    }, $class;
}

sub active_workers { return $_[0]{active_workers} }
sub max_workers { return $_[0]{max_workers} }

sub execute {
    my ($self, %args) = @_;
    my $work = $args{work};
    my $on_finish = $args{on_finish};
    return _error('invalid_source_job', 'template source job is invalid')
        unless ref($args{payload}) eq 'HASH'
        && ref($work) eq 'CODE' && ref($on_finish) eq 'CODE';

    my $timeout_seconds;
    eval {
        $timeout_seconds = defined($args{timeout_seconds})
            ? _positive_number($args{timeout_seconds}, 300, 'timeout_seconds')
            : $self->{timeout_seconds};
        1;
    } or return _error('invalid_source_job', 'template source job is invalid');

    my $payload_json = eval { $self->{json}->encode($args{payload}) };
    return _error('invalid_source_job', 'template source job is invalid')
        if $@ || !defined($payload_json)
        || length($payload_json) > $self->{max_payload_bytes};
    return {
        status => 'busy', code => 'source_workers_busy',
        message => 'Template source workers are busy. Try again.',
    } if $self->{active_workers} >= $self->{max_workers};

    $self->{active_workers}++;
    my $subprocess = Mojo::IOLoop::Subprocess->new;
    my ($timeout_id, $kill_id);
    my $responded = 0;
    my $deliver = sub {
        my ($result) = @_;
        return if $responded++;
        $on_finish->($result);
    };

    $subprocess->on(spawn => sub {
        my $pid = $subprocess->pid;
        $timeout_id = Mojo::IOLoop->timer($timeout_seconds => sub {
            kill 'TERM', $pid if defined($pid) && $pid > 0;
            $deliver->(_error(
                'source_timeout', 'Template source execution timed out.',
            ));
            $kill_id = Mojo::IOLoop->timer($self->{term_grace_seconds} => sub {
                kill 'KILL', $pid
                    if defined($pid) && $pid > 0 && kill(0, $pid);
            });
        });
    });

    $subprocess->run(
        sub {
            my $payload = eval { $self->{json}->decode($payload_json) };
            return _error('invalid_source_job', 'template source job is invalid')
                if $@ || ref($payload) ne 'HASH';

            my $result = eval { $work->($payload) };
            return _error(
                'source_worker_failed', 'Template source worker failed.',
            ) if $@ || ref($result) ne 'HASH';

            my $result_json = eval { $self->{json}->encode($result) };
            return _error(
                'source_result_too_large', 'Template source result is too large.',
            ) if !$@ && defined($result_json)
                && length($result_json) > $self->{max_result_bytes};
            return _error(
                'invalid_source_result', 'Template source result is invalid.',
            ) if $@ || !defined($result_json);
            return $self->{json}->decode($result_json);
        },
        sub {
            my ($finished_subprocess, $error, $result) = @_;
            Mojo::IOLoop->remove($timeout_id) if defined($timeout_id);
            Mojo::IOLoop->remove($kill_id) if defined($kill_id);
            $self->{active_workers}-- if $self->{active_workers} > 0;
            return if $responded;
            return $deliver->(_error(
                'source_worker_failed', 'Template source worker failed.',
            )) if defined($error) && length($error);
            return $deliver->(_error(
                'invalid_source_result', 'Template source result is invalid.',
            )) unless ref($result) eq 'HASH';
            return $deliver->($result);
        },
    );

    return {status => 'scheduled'};
}

sub _positive_integer {
    my ($value, $max, $name) = @_;
    die "$name must be an integer between 1 and $max\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A[1-9][0-9]*\z/ && $value <= $max;
    return 0 + $value;
}

sub _positive_number {
    my ($value, $max, $name) = @_;
    die "$name must be a number greater than 0 and at most $max\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/
        && $value > 0 && $value <= $max;
    return 0 + $value;
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
