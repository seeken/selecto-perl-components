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

our @ACTION_REQUESTS;
our @SAVED_QUERY_REQUESTS;
our @SAVED_QUERIES = (
    {name => 'Zulu inventory', url => '/explore/products?q=1&view=detail&field=product_name&limit=25&page=1'},
    {name => 'alpha inventory', url => '/explore/products?q=1&view=detail&field=product_name&limit=25&page=1'},
    {name => 'Wrong explorer', url => '/explore/elsewhere?q=1'},
);

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
                product_name => {
                    type => 'string',
                    link => {
                        url_template => '/products/view?id={{id}}',
                        id_field => 'id',
                    },
                },
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
        query_library => {
            segments => {
                low_stock => {
                    label => 'Low stock',
                    description => 'Products below the supplied stock threshold.',
                    filters => [['lt', 'units_in_stock', ['param', 'threshold']]],
                    parameters => {
                        threshold => {
                            type => 'integer', required => 1, label => 'Stock threshold',
                        },
                    },
                },
                premium => {
                    label => 'Premium products',
                    capability => 'products.read',
                    filters => [['gte', 'unit_price', ['param', 'minimum_price']]],
                    parameters => {
                        minimum_price => {type => 'decimal', required => 1},
                    },
                },
            },
            projections => {
                product_summary => {
                    fields => [qw(id product_name unit_price units_in_stock)],
                    associations => [{name => 'category', fields => ['category_name']}],
                },
            },
            orderings => {
                price_desc => {order_by => [['unit_price', 'desc'], ['id', 'asc']]},
            },
            views => {
                low_stock_products => {
                    label => 'Low stock products',
                    description => 'Reusable inventory review preset.',
                    segments => ['low_stock'],
                    projection => 'product_summary',
                    ordering => 'price_desc',
                },
            },
        },
        actions => {
            add_product_note => {
                label => 'Add Product Note',
                description => 'Add a note to selected products.',
                type => 'bulk_action',
                scope => 'bulk',
                inputs => [
                    {
                        id => 'note_type', label => 'Note type', type => 'select',
                        choice_source => 'product_note_types', required => 1,
                    },
                    {
                        id => 'comment', label => 'Comment', type => 'textarea',
                        required => 1, min_length => 1, max_length => 255,
                    },
                ],
                execution => {kind => 'host', operation => 'add_product_note'},
            },
            mark_for_review => {
                label => 'Mark for Review',
                description => 'Mark selected products for review.',
                type => 'bulk_action',
                scope => 'bulk',
                inputs => [
                    {
                        id => 'reason', label => 'Reason', type => 'textarea',
                        required => 1, min_length => 1, max_length => 120,
                    },
                ],
                execution => {kind => 'host', operation => 'mark_for_review'},
            },
            build_shipments => {
                label => 'Build Shipments',
                description => 'Group selected products into shipments.',
                type => 'bulk_action',
                scope => 'bulk',
                selection => {
                    mode => 'groups',
                    palette => 'lucky_charms',
                    max_groups => 4,
                    group_inputs => [{
                        id => 'carrier_id', label => 'Carrier ID', type => 'number',
                        required => 1, minimum => 1,
                    }],
                },
                submit_label => 'Build shipments',
                execution => {kind => 'host', operation => 'build_shipments'},
            },
        },
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
        choice_sources => {
            product_note_types => sub {
                return [
                    {value => 'internal', label => 'Internal'},
                    {value => 'public', label => 'Public'},
                ];
            },
        },
        action_handlers => {
            add_product_note => sub {
                my ($controller, $request) = @_;
                push @ACTION_REQUESTS, $request;
                return {
                    ok => 1,
                    applied_count => scalar(@{$request->{selected_ids}}),
                    message => 'Product note added.',
                };
            },
            mark_for_review => sub {
                my ($controller, $request) = @_;
                push @ACTION_REQUESTS, $request;
                return {
                    ok => 1,
                    applied_count => scalar(@{$request->{selected_ids}}),
                    message => 'Products marked for review.',
                };
            },
            build_shipments => sub {
                my ($controller, $request) = @_;
                push @ACTION_REQUESTS, $request;
                return {
                    ok => 1,
                    applied_count => scalar(@{$request->{selected_ids}}),
                    built_count => scalar(@{$request->{groups}}),
                    message => 'Shipments built.',
                };
            },
        },
        saved_query_store => TestSelectoComponents::SavedQueryStore->new,
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

package TestSelectoComponents::SavedQueryStore;

sub new { return bless {}, shift }

sub list {
    return [map { {%$_} } @TestSelectoComponents::SAVED_QUERIES];
}

sub save {
    my ($self, $controller, $config, $request) = @_;
    push @TestSelectoComponents::SAVED_QUERY_REQUESTS, {operation => 'save', %$request};
    @TestSelectoComponents::SAVED_QUERIES = (
        grep { $_->{name} ne $request->{name} } @TestSelectoComponents::SAVED_QUERIES,
        {name => $request->{name}, url => $request->{url}},
    );
    return 1;
}

sub delete {
    my ($self, $controller, $config, $request) = @_;
    push @TestSelectoComponents::SAVED_QUERY_REQUESTS, {operation => 'delete', %$request};
    @TestSelectoComponents::SAVED_QUERIES = grep {
        $_->{name} ne $request->{name}
    } @TestSelectoComponents::SAVED_QUERIES;
    return 1;
}

package TestSelectoComponents::Adapter;

use Mojo::Base 'Selecto::Adapter', -signatures;
use Selecto::Statement ();

our (
    $LAST_QUERY, $LAST_COUNT_QUERY, $LAST_COUNT_STATEMENT,
    $LAST_COMPILED_QUERY, $LAST_DATA_QUERY, $COUNT_EXECUTIONS,
);

sub name { return 'test'; }
sub dialect { return __PACKAGE__; }
sub compile ($self, $domain, $query) {
    $LAST_COMPILED_QUERY = $query;
    if (defined $query->limit_value) {
        $LAST_QUERY = $query;
    } else {
        $LAST_COUNT_QUERY = $query;
    }
    my @columns = map { defined($_->alias_name) ? $_->alias_name : $_->kind } @{$query->selections};
    return Selecto::Statement->new(
        sql => 'SELECT governed_test_query',
        params => _predicate_values($query->predicate),
        columns => \@columns,
        adapter_name => 'test',
    );
}
sub execute_query ($self, $statement) {
    if (@{$statement->columns} == 1 && $statement->columns->[0] eq 'selecto_total_count') {
        $LAST_COUNT_STATEMENT = $statement;
        $COUNT_EXECUTIONS++;
        return { columns => $statement->columns, rows => [[42]] };
    }
    $LAST_DATA_QUERY = $LAST_COMPILED_QUERY;
    my $rollup = grep { $_ eq '__selecto_rollup_grouping' } @{$statement->columns};
    my $group_count = $rollup ? scalar(@{$LAST_DATA_QUERY->groups}) : 0;
    my @rows;
    my $row_count = defined($LAST_DATA_QUERY->limit_value) ? 2 : 42;
    for my $row_index (1 .. $row_count) {
        my $row = [map {
                $_ eq '__selecto_rollup_grouping' ? 0
                : $_ eq '__selecto_action_target' ? 100 + $row_index
                : /\A__selecto_link_/ ? 100 + $row_index
                : $_ eq 'product_name' && $row_index == 1 ? '=2+2'
                : /(?:count|price)\z/ ? (($_ eq 'count' ? 2 : 10) * $row_index)
                : "Value $row_index"
        } @{$statement->columns}];
        $row->[$group_count - 1] = undef if $rollup && $row_index == 2;
        push @rows, $row;
    }
    if ($rollup) {
        for my $rolled_up (1 .. $group_count) {
            my $retained_groups = $group_count - $rolled_up;
            my $column_index = 0;
            push @rows, [map {
                my $value = $_ eq '__selecto_rollup_grouping' ? (1 << $rolled_up) - 1
                    : $column_index < $retained_groups ? 'Value 1'
                    : $column_index < $group_count ? undef
                    : /(?:count|price)\z/ ? 42 : undef;
                $column_index++;
                $value;
            } @{$statement->columns}];
        }
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
