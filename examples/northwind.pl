#!/usr/bin/env perl

use 5.034;
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec ();
use Mojolicious::Lite -signatures;
use Selecto;
use Selecto::Components ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Query ();
use Selecto::Perl::Northwind::Database ();
use Selecto::Perl::Northwind::Domains ();

my $northwind_root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..', '..', 'selecto-perl-northwind'));
die "selecto-perl-northwind was not found at $northwind_root\n" unless -d $northwind_root;
die "DATABASE_URL is required for the Northwind Components demo\n" unless defined $ENV{DATABASE_URL};

my $driver = Selecto::Perl::Northwind::Database->driver_name($ENV{DATABASE_URL});
my $dbh = Selecto::Perl::Northwind::Database->connect($ENV{DATABASE_URL}, driver => $driver);
my $adapter_name = Selecto::Perl::Northwind::Database->adapter_name($driver);
my $adapter = Selecto->adapter($adapter_name => (dbh => $dbh));
my $products_domain = Selecto::Perl::Northwind::Domains->load($northwind_root, 'products');

app->secrets(['selecto-perl-components-development-only']);
app->hook(after_dispatch => sub ($controller) {
    my $headers = $controller->res->headers;
    $headers->header('X-Content-Type-Options' => 'nosniff');
    $headers->header('Referrer-Policy' => 'same-origin');
    $headers->header('Content-Security-Policy' =>
        q{default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; img-src 'self'; base-uri 'none'; frame-ancestors 'none'});
});

plugin 'Selecto::Components' => {
    explorers => {
        products => {
            path => '/explore/products',
            title => 'Northwind Products',
            engine_factory => sub ($controller) {
                return Selecto::Engine->new(
                    domain => $products_domain,
                    adapter => $adapter,
                );
            },
            default_fields => [qw(product_name category.category_name supplier.company_name unit_price units_in_stock)],
            default_group => ['category.category_name'],
            measures => [
                { id => 'product_count', label => 'Product count', aggregate => 'count' },
                { id => 'inventory_value', label => 'Sum of unit prices', aggregate => 'sum', field => 'unit_price' },
                { id => 'highest_price', label => 'Highest unit price', aggregate => 'max', field => 'unit_price' },
            ],
            show_sql => 1,
        },
        orders => {
            path => '/explore/orders',
            title => 'Northwind Orders',
            engine_factory => sub ($controller) {
                return Selecto::Engine->new(
                    domain => Selecto::Perl::Northwind::Domains->load($northwind_root, 'orders'),
                    adapter => $adapter,
                );
            },
            default_fields => [qw(id order_date customer.company_name freight ship_country)],
            default_group => ['customer.company_name'],
            measures => [
                { id => 'order_count', label => 'Order count', aggregate => 'count' },
                { id => 'total_freight', label => 'Total freight', aggregate => 'sum', field => 'freight' },
            ],
            show_sql => 1,
        },
    },
    pages => {
        product_search => {
            path => '/pages/products', title => 'Northwind Product Search',
            domain => $products_domain,
            engine_factory => sub ($controller) {
                return Selecto::Engine->new(domain => $products_domain, adapter => $adapter);
            },
            dataset => {
                query => Selecto::Query->new,
                entity_key => ['id'],
            },
            views => [
                {id => 'products', kind => 'detail', label => 'Products',
                    query => Selecto::Query->new->select(
                        'id', 'product_name', 'category.category_name',
                        'supplier.company_name', 'unit_price', 'units_in_stock',
                    )->order_by('product_name')},
                {id => 'categories', kind => 'aggregate', label => 'By category',
                    query => Selecto::Query->new->select(
                        'category.category_name',
                        Selecto::Expression->count_distinct('id')->as('products'),
                    )->group_by('category.category_name')->order_by('category.category_name')},
            ],
            controls => [
                {id => 'category', kind => 'facet', label => 'Category',
                    field => 'category_id', label_field => 'category.category_name',
                    values => {source => 'dataset', limit => 30, searchable => 1}},
                {id => 'supplier', kind => 'facet', label => 'Supplier',
                    field => 'supplier_id', label_field => 'supplier.company_name',
                    values => {source => 'dataset', limit => 30, searchable => 1}},
                {id => 'price', kind => 'range', label => 'Unit price', field => 'unit_price'},
                {id => 'name', kind => 'text', label => 'Product name', field => 'product_name'},
            ],
            initial_state => {view => 'products', filters => {}},
        },
    },
};

get '/' => sub ($controller) { return $controller->redirect_to('/explore/products') };

my $port = $ENV{PORT} // 4128;
my $host = $ENV{PHX_DEV_HOSTNAME} // '127.0.0.1';
app->start(@ARGV ? @ARGV : ('daemon', '-l', "http://$host:$port"));
