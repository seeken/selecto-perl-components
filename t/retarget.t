use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL ();
use lib 't/lib';
use TestSelectoComponents;
use Selecto;
use Selecto::Components::Config ();
use Selecto::Components::Explorer ();
use Selecto::Components::QueryBuilder ();
use Selecto::Components::Renderer ();
use Selecto::Components::Renderer::Builder ();
use Selecto::Components::State ();

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

sub relation {
    my ($table, $columns, %extra) = @_;
    return {
        source_table => $table, primary_key => 'id',
        fields => [sort keys %$columns],
        columns => {map { ($_ => {type => $columns->{$_}}) } keys %$columns},
        associations => {},
        %extra,
    };
}

sub contract {
    my (%extra) = @_;
    return {
        schema_version => 1, name => 'Customers',
        source => relation('customers', {id => 'integer', name => 'string', region => 'string'},
            associations => {
                orders => {queryable => 'order', owner_key => 'id', related_key => 'customer_id'},
                notes => {queryable => 'note', owner_key => 'id', related_key => 'customer_id'},
            },
        ),
        schemas => {
            order => relation('orders',
                {id => 'integer', customer_id => 'integer', product_id => 'integer',
                    total => 'decimal', status => 'string'},
                associations => {
                    product => {queryable => 'product', owner_key => 'product_id', related_key => 'id'},
                },
            ),
            product => relation('products', {id => 'integer', name => 'string'}),
            note => relation('notes', {id => 'integer', customer_id => 'integer', body => 'string'}),
        },
        joins => {},
        %extra,
    };
}

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do($_) for (
    'CREATE TABLE customers (id integer primary key, name text, region text)',
    'CREATE TABLE orders (id integer primary key, customer_id integer, product_id integer, total decimal, status text)',
    'CREATE TABLE products (id integer primary key, name text)',
    'CREATE TABLE notes (id integer primary key, customer_id integer, body text)',
    q{INSERT INTO customers VALUES (1, 'Ann', 'west'), (2, 'Bob', 'east'), (3, 'Cy', 'west')},
    q{INSERT INTO orders VALUES (10, 1, 1, 25, 'open'), (11, 1, 2, 5, 'shipped'),
        (12, 2, 1, 40, 'open'), (13, 3, 1, 60, 'shipped')},
    q{INSERT INTO products VALUES (1, 'Widget'), (2, 'Gadget')},
    q{INSERT INTO notes VALUES (1, 1, 'call back')},
);

sub explorer {
    my ($domain) = @_;
    my $config = Selecto::Components::Config->new(
        id => 'customers', title => 'Customers', path => '/explore/customers',
        engine_factory => sub {
            Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        },
    );
    return Selecto::Components::Explorer->new(config => $config);
}

my $domain = Selecto::Domain->parse(contract());
my $explorer = explorer($domain);
my $controller = TestSelectoComponents::Controller->new;
my @west = (filter_field => 'region', filter_op => 'eq', filter_value => 'west',
    filter_value_end => '', filter_group => 0, filter_clause => '');

sub run_model {
    my ($explorer, %input) = @_;
    my $model = $explorer->model($controller, {q => 1, limit => 25, page => 1, %input});
    ok($model->{state}->valid, 'the state is valid') or diag explain $model->{state}->errors;
    if (($model->{runtime_error} // '') eq 'bounded child collections require PostgreSQL') {
        ok !defined($model->{result}), 'SQLite nested grain is refused without partial results';
    } else {
        is($model->{runtime_error}, undef, 'the query runs') or diag $model->{runtime_error};
    }
    return $model;
}

sub column {
    my ($model, $key) = @_;
    return [map { $_->{$key} } @{$model->{result}{records}}];
}

subtest 'detail columns from one to-many association pick its rows' => sub {
    my $model = run_model($explorer, view => 'detail', field => ['orders.total', 'orders.status'],
        @west, order => 'orders.total', direction => 'asc');
    is($model->{state}->retarget, 'orders', 'the grain is retargeted');
    ok($model->{state}->retarget_auto, 'automatically');
    is($model->{state}->grain, undef, 'the pickers stay on the root');
    is_deeply(column($model, 'orders__total'), [5, 25, 60], 'one row per order of a west customer');
    is($model->{result}{total_count}, 3, 'the count counts target rows');
    like(Selecto::Components::Renderer->_retarget_note($model), qr/One row per Orders.*rows_of=-/,
        'the note offers root rows instead');
    is($model->{state}->api_query_payload($model->{config}, $model->{domain}), undef,
        'the API payload is not offered for a retargeted grain');
};

subtest 'root rows when asked or when columns mix' => sub {
    my $forced = run_model($explorer, view => 'detail', rows_of => '-',
        field => ['orders.total'], @west);
    is($forced->{state}->retarget, undef, 'rows_of=- keeps root rows');
    ok !defined($forced->{result}), 'forced root children need a bounded collection adapter';
    my $mixed = run_model($explorer, view => 'detail', field => ['name', 'orders.total'], @west);
    is($mixed->{state}->retarget, undef, 'root columns keep root rows');
    my $one = run_model($explorer, view => 'detail', field => ['orders.total', 'notes.body']);
    is($one->{state}->retarget, undef, 'columns from two associations keep root rows');
};

subtest 'explicit grain' => sub {
    my $model = run_model($explorer, view => 'detail', rows_of => 'orders',
        field => ['orders.id', 'orders.product.name'], @west, order => 'orders.id', direction => 'asc');
    is($model->{state}->grain, 'orders', 'the explicit grain drives the pickers');
    is_deeply(column($model, 'orders__product__name'), ['Widget', 'Gadget', 'Widget'],
        'the target reaches its own associations');
    is_deeply(column($model, 'orders__id'), [10, 11, 13], 'filters stay root context');

    my $summary = run_model($explorer, view => 'aggregate', rows_of => 'orders',
        field => 'orders.total', group => 'orders.status', measure => '__row_count__', @west);
    is_deeply({map { ($_->{orders__status} => $_->{measure____row_count__}) }
            grep { defined $_->{orders__status} } @{$summary->{result}{records}}},
        {open => 1, shipped => 2}, 'a summary counts target rows')
        or diag explain $summary->{result}{records};

    my $bad = $explorer->model($controller, {q => 1, view => 'detail', rows_of => 'nowhere'});
    ok(!$bad->{state}->valid, 'an unknown grain is refused');
};

subtest 'changing the grain keeps what the new grain offers' => sub {
    my $to_orders = run_model($explorer, view => 'detail', rows_of => 'orders', rows_of_from => '',
        field => ['name', 'orders.total'], order => 'name', direction => 'asc');
    is_deeply($to_orders->{state}->fields, ['orders.total'], 'root columns are dropped');
    is($to_orders->{state}->orders->[0]{field}, 'orders.total', 'the sort follows the columns');
    my $to_root = run_model($explorer, view => 'detail', rows_of => '-', rows_of_from => 'orders',
        field => ['orders.total', 'orders.product.name']);
    is_deeply($to_root->{state}->fields, ['orders.total'], 'columns the root cannot show are dropped');
};

subtest 'summary drilldowns open the counted rows' => sub {
    my $summary = run_model($explorer, view => 'aggregate', field => 'name', group => 'region',
        measure => 'orders.total');
    my %drill;
    for my $index (0 .. $#{$summary->{result}{records}}) {
        my $record = $summary->{result}{records}[$index];
        next unless defined $record->{region};
        $drill{$record->{region}} = $summary->{result}{drilldowns}[$index][0];
    }
    my %pairs = @{$drill{west}};
    is($pairs{rows_of}, 'orders', 'the drilldown retargets to the measured association');
    my $url = Mojo::URL->new('/explore/customers')->query($drill{west});
    my %input;
    for my $name (@{$url->query->names}) {
        my $values = $url->query->every_param($name);
        $input{$name} = @$values == 1 ? $values->[0] : $values;
    }
    my $detail = run_model($explorer, %input, order => 'orders.id', direction => 'asc');
    is($detail->{state}->retarget, 'orders', 'the detail view shows orders');
    is_deeply([sort { $a <=> $b } @{column($detail, 'orders__id')}], [10, 11, 13],
        'the orders the west total summed');
    is_deeply($detail->{state}->groups, ['region'], 'the summary groups are carried');
};

subtest 'declared targets' => sub {
    my $governed = Selecto::Domain->parse(contract(retarget => {
        targets => {orders => {label => 'Customer orders', default_selected => ['total']}},
    }));
    my $governed_explorer = explorer($governed);
    my $model = run_model($governed_explorer, view => 'detail', rows_of => 'orders', rows_of_from => '');
    is_deeply($model->{state}->fields, ['orders.total'], 'default_selected seeds the columns');
    my $picker = Selecto::Components::Renderer::Builder->_rows_of_picker($model);
    like($picker, qr/<option value="orders" selected>Customer orders<\/option>/,
        'the picker lists declared targets');
    like($picker, qr/name="rows_of_from" value="orders"/, 'the picker records the current grain');
    my %catalog = map { $_->{path} => $_ }
        @{$model->{config}->field_catalog($governed, {rows_of => 'orders'})};
    is($catalog{'orders.total'}{picker_group_key}, '', 'target fields group as the grain root');
    is($catalog{'orders.product.name'}{picker_group_key}, 'product',
        'target associations group by their own name');
    my $undeclared = run_model($governed_explorer, view => 'detail', field => ['notes.body']);
    is($undeclared->{state}->retarget, undef, 'automatic retargeting stays within declared targets');
    my $plain = run_model($explorer, view => 'detail', field => ['name']);
    is(Selecto::Components::Renderer::Builder->_rows_of_picker($plain),
        '<input type="hidden" name="rows_of_from" value="">',
        'a domain without targets shows no picker until a grain applies');
};

done_testing;
