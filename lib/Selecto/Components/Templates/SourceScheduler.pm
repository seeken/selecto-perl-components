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

=head2 Worker limits

C<max_workers> (default 4, at most 64) bounds all concurrent children in this
process. C<max_workers_per_owner> bounds the children one owner may hold at the
same time so that a single user cannot starve everyone else. It defaults to
C<max(1, int(max_workers / 2))> (2 with the default pool) and may not exceed
C<max_workers>. Callers identify the owner with the opaque C<owner_key> argument
to C<execute>; the template controller passes a SHA-256 digest of the canonical
owner scope. Jobs without an C<owner_key> are only bounded by C<max_workers>.

A job refused because the pool is full returns C<source_workers_busy>; a job
refused because its owner already holds its share returns
C<source_owner_workers_busy>. Both are C<busy> results (HTTP 409).

Both limits are per process. In a preforking server every worker process owns
its own pool, so the effective ceiling is multiplied by the number of worker
processes; size the database connection pool accordingly.

=head2 Forked child

The C<work> callback runs in a forked child. Anything it touches that was
created in the parent, notably DBI handles, is shared with the parent at the
file-descriptor level and must not be used. See
L<Selecto::Components::Templates::SourceExecutor/"Database connections in the child">.
C<in_worker> returns true inside that child.

=cut

our $IN_WORKER = 0;

sub in_worker { return $IN_WORKER ? 1 : 0 }

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
    my $default_per_owner = int($max_workers / 2);
    $default_per_owner = 1 if $default_per_owner < 1;
    my $max_workers_per_owner = _positive_integer(
        $args{max_workers_per_owner} // $default_per_owner, $max_workers,
        'max_workers_per_owner',
    );
    return bless {
        max_workers => $max_workers,
        max_workers_per_owner => $max_workers_per_owner,
        active_by_owner => {},
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
sub max_workers_per_owner { return $_[0]{max_workers_per_owner} }

sub active_workers_for {
    my ($self, $owner_key) = @_;
    return 0 unless defined($owner_key) && !ref($owner_key);
    return $self->{active_by_owner}{$owner_key} // 0;
}

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

    my $owner_key = $args{owner_key};
    return _error('invalid_source_job', 'template source job is invalid')
        if defined($owner_key)
        && (ref($owner_key) || !length("$owner_key") || length("$owner_key") > 256);

    my $payload_json = eval { $self->{json}->encode($args{payload}) };
    return _error('invalid_source_job', 'template source job is invalid')
        if $@ || !defined($payload_json)
        || length($payload_json) > $self->{max_payload_bytes};
    return {
        status => 'busy', code => 'source_workers_busy',
        message => 'Template source workers are busy. Try again.',
    } if $self->{active_workers} >= $self->{max_workers};
    return {
        status => 'busy', code => 'source_owner_workers_busy',
        message => 'Too many template sources are loading for this user. Try again.',
    } if defined($owner_key)
        && $self->active_workers_for($owner_key) >= $self->{max_workers_per_owner};

    $self->{active_workers}++;
    $self->{active_by_owner}{$owner_key}++ if defined($owner_key);
    my $released = 0;
    my $release_slot = sub {
        return if $released++;
        $self->{active_workers}-- if $self->{active_workers} > 0;
        return unless defined($owner_key);
        delete $self->{active_by_owner}{$owner_key}
            if --$self->{active_by_owner}{$owner_key} <= 0;
    };
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

    my $child = sub {
        $IN_WORKER = 1;
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
    };
    my $finish = sub {
        my ($finished_subprocess, $error, $result) = @_;
        Mojo::IOLoop->remove($timeout_id) if defined($timeout_id);
        Mojo::IOLoop->remove($kill_id) if defined($kill_id);
        $release_slot->();
        return if $responded;
        return $deliver->(_error(
            'source_worker_failed', 'Template source worker failed.',
        )) if defined($error) && length($error);
        return $deliver->(_error(
            'invalid_source_result', 'Template source result is invalid.',
        )) unless ref($result) eq 'HASH';
        return $deliver->($result);
    };
    my $started = eval { $subprocess->run($child, $finish); 1 };
    unless ($started) {
        Mojo::IOLoop->remove($timeout_id) if defined($timeout_id);
        $release_slot->();
        return _error('source_worker_failed', 'Template source worker failed.');
    }

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
