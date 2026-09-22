use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use Mojo::IOLoop;
use Test::More;
use Time::HiRes qw(time);
use Selecto::Components::Templates::SourceScheduler;

my $parent_pid = $$;
my $scheduler = Selecto::Components::Templates::SourceScheduler->new(
    max_workers => 1,
    timeout_seconds => 1,
    term_grace_seconds => 0.02,
    max_payload_bytes => 1_024,
    max_result_bytes => 1_024,
);

my ($event_loop_tick, $first_result);
Mojo::IOLoop->timer(0.01 => sub { $event_loop_tick = 1 });
my $first = $scheduler->execute(
    payload => {tenant_id => 7, marker => 'safe-data'},
    work => sub {
        my ($payload) = @_;
        select undef, undef, undef, 0.12;
        return {status => 'ok', pid => $$, payload => $payload};
    },
    on_finish => sub { $first_result = $_[0] },
);
is $first->{status}, 'scheduled', 'source work is scheduled asynchronously';
is $scheduler->active_workers, 1, 'scheduled child occupies one bounded slot';

my $busy = $scheduler->execute(
    payload => {tenant_id => 7},
    work => sub { return {status => 'ok'} },
    on_finish => sub { fail 'busy work must not run' },
);
is $busy->{status}, 'busy', 'concurrency bound rejects excess work';
is $busy->{code}, 'source_workers_busy', 'capacity failure has a stable code';

_drain_until(sub { defined($first_result) && $scheduler->active_workers == 0 });
ok $event_loop_tick, 'the parent event loop advances while source work sleeps';
is $first_result->{status}, 'ok', 'child result returns to the parent';
isnt $first_result->{pid}, $parent_pid, 'source work runs in a separate process';
is_deeply $first_result->{payload}, {tenant_id => 7, marker => 'safe-data'},
    'the child receives the JSON-safe payload';

my $invalid_payload = $scheduler->execute(
    payload => {callback => sub { return 1 }},
    work => sub { return {status => 'ok'} },
    on_finish => sub { fail 'invalid payload must not run' },
);
is $invalid_payload->{code}, 'invalid_source_job',
    'non-serializable payloads fail before a child starts';
is $scheduler->active_workers, 0, 'invalid work consumes no worker slot';

my $timeout_scheduler = Selecto::Components::Templates::SourceScheduler->new(
    max_workers => 1,
    timeout_seconds => 0.05,
    term_grace_seconds => 0.02,
);
my ($timeout_result, $timeout_tick);
my $started_at = time;
Mojo::IOLoop->timer(0.01 => sub { $timeout_tick = 1 });
is $timeout_scheduler->execute(
    payload => {operation => 'slow'},
    work => sub {
        local $SIG{TERM} = 'IGNORE';
        select undef, undef, undef, 2;
        return {status => 'ok'};
    },
    on_finish => sub { $timeout_result = $_[0] },
)->{status}, 'scheduled', 'slow source starts';

_drain_until(sub {
    defined($timeout_result) && $timeout_scheduler->active_workers == 0
});
ok $timeout_tick, 'timeout supervision does not block the event loop';
is $timeout_result->{code}, 'source_timeout', 'elapsed source work times out';
cmp_ok time - $started_at, '<', 1,
    'an uncooperative child is killed after the bounded grace period';
is $timeout_scheduler->active_workers, 0,
    'terminated child releases its worker slot';

my $small_result_scheduler = Selecto::Components::Templates::SourceScheduler->new(
    max_workers => 1,
    timeout_seconds => 1,
    max_result_bytes => 32,
);
my $large_result;
$small_result_scheduler->execute(
    payload => {operation => 'large'},
    work => sub { return {status => 'ok', value => 'x' x 100} },
    on_finish => sub { $large_result = $_[0] },
);
_drain_until(sub {
    defined($large_result) && $small_result_scheduler->active_workers == 0
});
is $large_result->{code}, 'source_result_too_large',
    'oversized child results are replaced by a bounded error';

done_testing;

sub _drain_until {
    my ($condition) = @_;
    my $timed_out;
    my $watcher;
    my $guard = Mojo::IOLoop->timer(3 => sub {
        $timed_out = 1;
        Mojo::IOLoop->stop;
    });
    $watcher = Mojo::IOLoop->recurring(0.005 => sub {
        return unless $condition->();
        Mojo::IOLoop->remove($guard);
        Mojo::IOLoop->remove($watcher);
        Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->start;
    ok !$timed_out, 'asynchronous source work settles before the test deadline';
}
