use 5.034;
use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config ();
use Selecto::Domain ();
use Selecto::Engine ();

# An Explorer may list star dimensions whose lookup tables are read whole
# (dimension_filter_choices): a filter on the dimension's key or display field then
# chooses from the table's rows, read per request.

my $contract = TestSelectoComponents::domain()->contract;
$contract->{joins}{category} = {
    type => 'star_dimension', name => 'Category',
    display_field => 'category_name', dimension_key => 'category_id',
};
my $domain = Selecto::Domain->parse($contract, strict => 1);

# A stand-in database handle: the lookup table's rows, and the SQL asked for.
package LookupDBH {
    our @ROWS; our $SQL; our $FAIL;
    sub new { bless {}, shift }
    sub quote_identifier ($self, $name) { qq{"$name"} }
    sub selectall_arrayref ($self, $sql) { $SQL = $sql; die "connection lost\n" if $FAIL; [map { [@$_] } @ROWS] }
}
@LookupDBH::ROWS = (['2 ', 'Dairy'], [3, 'Bakery, fresh'], [1, 'Produce'], [5, ' Padded']);
my $engine = Selecto::Engine->new(domain => $domain,
    adapter => TestSelectoComponents::Adapter->new(dbh => LookupDBH->new));

package TestController { sub new { bless {}, shift } }

my $config_with = sub (@wanted) {
    Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products',
        engine_factory => sub { $engine }, dimension_filter_choices => [@wanted]);
};
my $choices = sub ($config, $path) {
    [map { "$_->{value}=$_->{label}" } @{$config->filter_map($domain)->{$path}{filter_choices} // []}];
};

my $request = $config_with->('category')->for_request(TestController->new);
is_deeply $choices->($request, 'category_id'), ['2=Dairy', '1=Produce'],
    'the key field chooses by display text and filters the key (padded codes trimmed; values with commas or blanks left out)';
is $LookupDBH::SQL,
    'SELECT "id", "category_name" FROM "categories" WHERE "id" IS NOT NULL AND "category_name" IS NOT NULL ORDER BY "category_name" LIMIT 201',
    'one bounded read of the lookup table, by display text';
is_deeply $choices->($request, 'category.category_name'), ['Dairy=Dairy', 'Produce=Produce'],
    'the display field chooses its own text';

is_deeply $choices->($config_with->('category'), 'category_id'), [],
    'only a request copy reads the table (shared configuration never caches a tenant\'s rows)';
is_deeply $choices->($config_with->()->for_request(TestController->new), 'category_id'), [],
    'a dimension that is not listed keeps the free-text filter';
is_deeply $choices->($config_with->('no_such')->for_request(TestController->new), 'category_id'), [],
    'an unknown dimension is ignored';

@LookupDBH::ROWS = map { [$_, "Category $_"] } 1 .. 201;
is_deeply $choices->($config_with->('category')->for_request(TestController->new), 'category_id'), [],
    'a table over 200 rows keeps the free-text filter';
@LookupDBH::ROWS = ([1, 'Produce']);
local $LookupDBH::FAIL = 1;
is_deeply $choices->($config_with->('category')->for_request(TestController->new), 'category_id'), [],
    'a table that can\'t be read keeps the free-text filter';
$LookupDBH::FAIL = 0;

ok !eval { $config_with->('bad path!'); 1 }, 'dimension_filter_choices must name association paths';

done_testing;
