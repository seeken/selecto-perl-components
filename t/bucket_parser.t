use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Selecto::Components::BucketParser ();

my $ranges = Selecto::Components::BucketParser->parse('1, 2-5, 15+, -0, nope');
is_deeply $ranges, [
    { minimum => 1, maximum => 1, label => '1' },
    { minimum => 2, maximum => 5, label => '2-5' },
    { minimum => 15, maximum => undef, label => '15+' },
    { minimum => undef, maximum => 0, label => "\x{2264}0" },
], 'explicit governed ranges parse in order and invalid parts are ignored';

# "-N" after a range ending at a number starts where that range stopped.
sub labels { [map { $_->{label} } @{$_[0]}] }
is_deeply labels(Selecto::Components::BucketParser->parse('1,-4,-10,-20,21+')),
    [qw(1 2-4 5-10 11-20 21+)], 'a following -N continues from the range before it';
is_deeply(Selecto::Components::BucketParser->parse('1, -4')->[1], {minimum => 2, maximum => 4, label => '2-4'},
    'with the inferred bounds');
is_deeply labels(Selecto::Components::BucketParser->parse('-4, 5-9, -10, 20+, -30, 40, -2')),
    ["\x{2264}4", '5-9', '10', '20+', "\x{2264}30", '40', "\x{2264}2"],
    'leading, after an open range, or below the range before it, -N is still N or less';
is_deeply labels(Selecto::Components::BucketParser->specification('0, -6, -29, 30+', 'elapsed_days_ranges')->{ranges}),
    [qw(0 1-6 7-29 30+)], 'age buckets infer the same way';

is_deeply(Selecto::Components::BucketParser->specification('*/10', 'numeric_ranges'),
    { kind => 'numeric_increment', increment => 10 },
    'numeric increment shorthand becomes portable intent');
is_deeply(Selecto::Components::BucketParser->specification('*/5', 'year_ranges'),
    { kind => 'year_increment', increment => 5 },
    'year increment shorthand becomes portable intent');
ok !Selecto::Components::BucketParser->valid('garbage', 'numeric_ranges'),
    'invalid range input fails closed';

done_testing;
