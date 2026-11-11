use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Components::State ();

# When a grain change drops a measure, every per-measure setting of the measures
# that remain moves with its measure: none inherits a dropped one's.
{
    package StubConfig;
    sub new { return bless {}, shift }
    sub field_map { return {} }
    sub detail_column_map { return {} }
    sub measure { my (undef, $id) = @_; return $id eq 'gone' ? undef : {id => $id} }
}

my @keys = qw(measure_alias measure_function measure_bucket_ranges measure_ignore_nulls measure_series_id
    measure_chart_type measure_axis measure_stack measure_color measure_fill_opacity measure_transform
    measure_transform_window);
my %input = (measure => ['gone', 'kept'], map { ($_ => ["$_ of gone", "$_ of kept"]) } @keys);
my $kept = Selecto::Components::State::_retain_available(StubConfig->new, undef, \%input, 'orders', 'aggregate', ['measure']);
is_deeply($kept->{measure}, ['kept'], 'the dropped measure goes');
is_deeply($kept->{$_}, ["$_ of kept"], "$_ stays with its measure") for @keys;

done_testing;
