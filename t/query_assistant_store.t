use 5.034;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Selecto::Components::QueryAssistant::Store;
use lib 'lib';
use Selecto::Components::QueryAssistant::Store::SQLite;

BEGIN {
    eval { require DBD::SQLite; 1 }
        or plan skip_all => 'DBD::SQLite is not installed in this development environment';
}

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/drafts.sqlite";
my $first = Selecto::Components::QueryAssistant::Store::SQLite->new(path => $path);
my $second = Selecto::Components::QueryAssistant::Store::SQLite->new(path => $path);
my $created = $first->create({owner => 'actor', target => {view => 'detail'}});
is $created->{revision}, 0, 'SQLite draft starts at revision zero';
is $second->get($created->{id})->{owner}, 'actor', 'another worker sees the same draft';

my $winner = $first->compare_and_swap($created->{id}, 0, {
    %$created, target => {view => 'graph'},
});
ok $winner->{ok}, 'first worker wins the exact-revision update';
my $loser = $second->compare_and_swap($created->{id}, 0, {
    %$created, target => {view => 'aggregate'},
});
is $loser->{code}, 'revision_conflict', 'second worker cannot overwrite a newer revision';
is $loser->{current_revision}, 1, 'conflict reports the authoritative revision';
is $second->get($created->{id})->{target}{view}, 'graph', 'winning payload remains authoritative';

for my $class (qw(Selecto::Components::QueryAssistant::Store Selecto::Components::QueryAssistant::Store::SQLite)) {
    my %options = $class =~ /SQLite/ ? (path => "$directory/payload.sqlite") : ();
    my $bounded = $class->new(%options, max_payload_bytes => 256);
    my $oversized = eval { $bounded->create({owner => 'large', target => {value => 'x' x 1024}}); 1 };
    ok !$oversized, "$class rejects oversized creation";
    like $@, qr/draft payload is too large/, "$class reports the same creation failure";
    my $small = $bounded->create({owner => 'small'});
    my $update = $bounded->compare_and_swap($small->{id}, 0, {%$small, value => 'x' x 1024});
    is $update->{code}, 'limit_exceeded', "$class reports a bounded update failure";
    is $bounded->get($small->{id})->{revision}, 0, "$class retains the original revision after a rejected update";
    my $metadata_bound = $class->new(
        ($class =~ /SQLite/ ? (path => "$directory/metadata.sqlite") : ()), max_payload_bytes => 20,
    );
    my $metadata = eval { $metadata_bound->create({owner => 'a'}); 1 };
    ok !$metadata, "$class counts generated metadata toward the payload ceiling";
}

# Independent worker connections compete to create the final draft slot.
# Every losing request must observe the quota rather than race the insert.
my $quota_path = "$directory/quota.sqlite";
my $quota = Selecto::Components::QueryAssistant::Store::SQLite->new(
    path => $quota_path, max_drafts_per_owner => 1,
);
pipe(my $start_read, my $start_write) or die $!;
my (@children, @outputs);
for (1 .. 4) {
    pipe(my $result_read, my $result_write) or die $!;
    my $pid = fork();
    die "cannot fork: $!" unless defined $pid;
    if (!$pid) {
        close $start_write;
        close $result_read;
        my $worker = Selecto::Components::QueryAssistant::Store::SQLite->new(
            path => $quota_path, max_drafts_per_owner => 1,
        );
        my $signal;
        sysread($start_read, $signal, 1);
        my $ok = eval { $worker->create({owner => 'shared-owner'}); 1 };
        print {$result_write} $ok ? 'created' : ($@ =~ /quota exceeded/ ? 'quota' : "unexpected: $@");
        close $result_write;
        _exit(0);
    }
    close $result_write;
    push @children, $pid;
    push @outputs, $result_read;
}
close $start_read;
syswrite($start_write, 'xxxx');
close $start_write;
my @outcomes = map { local $/; my $outcome = <$_>; close $_; $outcome } @outputs;
waitpid($_, 0) for @children;
is scalar(grep { $_ eq 'created' } @outcomes), 1, 'exactly one worker claims the final draft slot';
is scalar(grep { $_ eq 'quota' } @outcomes), 3, 'other workers receive the authoritative quota failure';
is $quota->{dbh}->selectrow_array('SELECT count(*) FROM selecto_query_drafts'), 1,
    'concurrent creation cannot exceed the per-owner quota';

# A borrowed connection's transaction is never committed by the store.
$quota->{dbh}->begin_work;
my $borrowed = Selecto::Components::QueryAssistant::Store::SQLite->new(dbh => $quota->{dbh});
$borrowed->create({owner => 'borrowed-owner'});
ok !$quota->{dbh}->{AutoCommit}, 'draft creation preserves a borrowed transaction';
$quota->{dbh}->rollback;
is $quota->{dbh}->selectrow_array('SELECT count(*) FROM selecto_query_drafts'), 1,
    'the host can roll back a draft created in its transaction';

done_testing;
