use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON::PP ();
use Mojolicious;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::QueryBuilder;
use Selecto::Components::State;

my $raw = TestSelectoComponents::domain()->contract;
$raw->{actions}{mark_for_review}{capability} = 'products.review';
$raw->{actions}{mark_for_review}{preconditions} = [
    ['discontinued', JSON::PP::false], ['>', 'units_in_stock', 0],
];
my $domain = Selecto::Domain->parse($raw, strict => 1);
is_deeply $domain->action_prerequisite_fields, {mark_for_review => 'can_mark_for_review'},
    'the test domain has one action prerequisite column';

my ($hidden, @authorized) = (0);
my $options = TestSelectoComponents::config();
$options->{engine_factory} = sub {
    Selecto::Engine->new(domain => $domain,
        adapter => TestSelectoComponents::Adapter->new(dbh => bless({}, 'TestSelectoComponents::DBH')));
};
$options->{action_authorizer} = sub {
    my ($controller, $request) = @_;
    push @authorized, $request;
    return $hidden && $request->{action}{id} eq 'mark_for_review' ? 'hidden' : 'enabled';
};
my $config = Selecto::Components::Config->new(%$options, id => 'products');
my $controller = Mojolicious->new->build_controller;

my $request_config = $config->for_request($controller);
my $visible = $request_config->engine($controller)->domain;
my ($filter) = grep { $_->{path} eq 'can_mark_for_review' } @{$request_config->filter_catalog($visible)};
is $filter->{label}, 'Mark for Review prerequisites met', 'the Explorer offers the prerequisite filter';
is_deeply $filter->{filter_choices},
    [{value => 'true', label => 'Yes'}, {value => 'false', label => 'No'}],
    'the prerequisite filter is Yes/No';
ok grep({ $_->{path} eq 'can_mark_for_review' } @{$request_config->field_catalog($visible)}),
    'the Explorer offers the prerequisite column';
is scalar(@authorized), 1, 'the action is authorized once';
is $authorized[0]{phase}, 'preview', 'with the phase Explorer lists actions in';
ok !defined $authorized[0]{target}, 'and without a target';
$request_config->engine($controller);
is scalar(@authorized), 1, 'a request copy remembers the decision';

my $state = Selecto::Components::State->from_input($request_config, $visible, {
    q => 1, view => 'detail', field => ['product_name', 'can_mark_for_review'],
    filter_field => 'can_mark_for_review', filter_op => 'eq', filter_value => 'false',
});
ok $state->valid, 'a No filter and the column are accepted';
my $query = Selecto::Components::QueryBuilder->build($request_config, $visible, $state)->{query};
my $statement = Selecto::Engine->new(domain => $visible,
    adapter => Selecto::PostgreSQL->new(dbh => bless({}, 'TestSelectoComponents::DBH')))->compile($query);
like $statement->sql, qr{AS "can_mark_for_review".*WHERE .*"units_in_stock" > \$\d+\)\) = \$\d+}s,
    'the Explorer selects and filters the prerequisite predicate';
is $statement->params->[-2], 0, 'No compares the predicate with false';

$hidden = 1;
@authorized = ();
$request_config = $config->for_request($controller);
my $without = $request_config->engine($controller)->domain;
ok !exists $without->fields->{can_mark_for_review}, 'a hidden action hides its prerequisite column';
ok !grep({ $_->{path} eq 'can_mark_for_review' } @{$request_config->filter_catalog($without)}),
    'and its filter';
ok !Selecto::Components::State->from_input($request_config, $without, {
    q => 1, view => 'detail', field => 'product_name',
    filter_field => 'can_mark_for_review', filter_op => 'eq', filter_value => 'true',
})->valid, 'a hidden prerequisite filter is rejected';
ok exists $domain->fields->{can_mark_for_review}, 'the shared domain is unchanged';

$hidden = 0;
my $app = Mojolicious->new;
$app->secrets(['test-only-secret']);
$app->plugin('Selecto::Components' => {explorers => {products => {%$options, path => '/explore/products'}}});
my $t = Test::Mojo->new($app);
$t->get_ok('/explore/products?q=1&view=detail&field=product_name&field=can_mark_for_review')
    ->status_is(200)
    ->content_like(qr/Mark for Review prerequisites met/, 'the page shows the prerequisite column');
$hidden = 1;
$t->get_ok('/explore/products?q=1&view=detail&field=product_name')
    ->status_is(200)
    ->content_unlike(qr/prerequisites met/, 'the page omits a hidden prerequisite column');

done_testing;
