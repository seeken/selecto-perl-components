package TestSelectoComponents;

use 5.034;
use strict;
use warnings;
use Mojolicious;
use Selecto;
use Selecto::Adapter ();
use Selecto::Components ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Statement ();

sub domain {
    return _domain();
}

sub private_domain {
    return _domain({ query_params => 0 });
}

sub _domain {
    my ($components) = @_;
    return Selecto::Domain->parse({
        schema_version => 1,
        domain_version => '1.0.0',
        name => 'Products',
        source => {
            source_table => 'products',
            primary_key => 'id',
            fields => [qw(id product_name category_id unit_price units_in_stock created_on)],
            columns => {
                id => { type => 'integer' },
                product_name => { type => 'string' },
                category_id => { type => 'integer' },
                unit_price => { type => 'decimal' },
                units_in_stock => { type => 'integer' },
                created_on => { type => 'date' },
            },
            associations => {
                category => {
                    queryable => 'categories',
                    owner_key => 'category_id',
                    related_key => 'id',
                },
            },
        },
        schemas => {
            categories => {
                source_table => 'categories',
                primary_key => 'id',
                fields => [qw(id category_name)],
                columns => {
                    id => { type => 'integer' },
                    category_name => { type => 'string' },
                },
                associations => {},
            },
        },
        joins => { category => { type => 'inner' } },
        (defined($components) ? (components => $components) : ()),
    }, strict => 1);
}

sub config {
    return {
        path => '/explore/products',
        title => 'Product Explorer',
        engine_factory => sub {
            return Selecto::Engine->new(
                domain => domain(),
                adapter => TestSelectoComponents::Adapter->new(dbh => bless({}, 'TestSelectoComponents::DBH')),
            );
        },
        default_fields => [qw(product_name category.category_name unit_price)],
        default_group => ['category.category_name'],
        measures => [
            { id => 'count', label => 'Product count', aggregate => 'count' },
            { id => 'total_price', label => 'Total price', aggregate => 'sum', field => 'unit_price' },
        ],
        show_sql => 1,
    };
}

sub app {
    my $app = Mojolicious->new;
    $app->secrets(['test-only-secret']);
    my $private = config();
    $private->{path} = '/explore/private-products';
    $private->{title} = 'Private Product Explorer';
    $private->{engine_factory} = sub {
        return Selecto::Engine->new(
            domain => private_domain(),
            adapter => TestSelectoComponents::Adapter->new(
                dbh => bless({}, 'TestSelectoComponents::DBH')
            ),
        );
    };
    $app->plugin('Selecto::Components' => {
        explorers => { products => config(), private_products => $private },
    });
    return $app;
}

package TestSelectoComponents::Adapter;

use Mojo::Base 'Selecto::Adapter', -signatures;
use Selecto::Statement ();

our $LAST_QUERY;

sub name { return 'test'; }
sub dialect { return __PACKAGE__; }
sub compile ($self, $domain, $query) {
    $LAST_QUERY = $query;
    my @columns = map { defined($_->alias_name) ? $_->alias_name : $_->kind } @{$query->selections};
    return Selecto::Statement->new(
        sql => 'SELECT governed_test_query',
        params => _predicate_values($query->predicate),
        columns => \@columns,
        adapter_name => 'test',
    );
}
sub execute_query ($self, $statement) {
    my @rows;
    for my $row_index (1, 2) {
        push @rows, [map {
            $_ eq 'product_name' && $row_index == 1 ? '=2+2'
                : /(?:count|price)\z/ ? (($_ eq 'count' ? 2 : 10) * $row_index)
                : "Value $row_index"
        } @{$statement->columns}];
    }
    return { columns => $statement->columns, rows => \@rows };
}
sub preview_write { return {}; }
sub execute_write { return {}; }
sub execute_batch { return []; }

sub _predicate_values ($expression) {
    return [] unless $expression;
    my @values;
    _walk($expression, \@values);
    return \@values;
}

sub _walk ($expression, $values) {
    return unless ref($expression) && $expression->isa('Selecto::Expression');
    if ($expression->kind eq 'literal') {
        push @$values, $expression->arguments->[0];
        return;
    }
    for my $argument (@{$expression->arguments}) {
        if (ref($argument) eq 'ARRAY') {
            for my $item (@$argument) { _walk($item, $values) }
        } else {
            _walk($argument, $values);
        }
    }
}

1;
