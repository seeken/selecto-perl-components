use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Statement;
use Selecto::Components::Explorer;

# A count wrapped around a compiled statement stays generated: it keeps the relations
# that give it its pin and guards. Without them it would run as hand-built.
my $source = Selecto::Statement->new(sql => 'SELECT 1', params => [7], columns => ['a'], adapter_name => 'postgresql');
$source->{_selecto_relations} = ['public.t'];
my $count = Selecto::Components::Explorer::_count_statement($source);
like($count->sql, qr/\ASELECT COUNT\(\*\) AS selecto_total_count FROM \(SELECT 1\) AS selecto_count_source\z/, 'the count wraps the statement');
is_deeply($count->params, [7], 'with its parameters');
is_deeply($count->columns, ['selecto_total_count'], 'and its own column');
is_deeply($count->relations, ['public.t'], 'and the relations of what it counts');
done_testing;
