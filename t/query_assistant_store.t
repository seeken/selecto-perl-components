use 5.034;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
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

done_testing;
