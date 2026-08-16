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

is_deeply(Selecto::Components::BucketParser->specification('*/10', 'numeric_ranges'),
    { kind => 'numeric_increment', increment => 10 },
    'numeric increment shorthand becomes portable intent');
is_deeply(Selecto::Components::BucketParser->specification('*/5', 'year_ranges'),
    { kind => 'year_increment', increment => 5 },
    'year increment shorthand becomes portable intent');
ok !Selecto::Components::BucketParser->valid('garbage', 'numeric_ranges'),
    'invalid range input fails closed';

done_testing;
