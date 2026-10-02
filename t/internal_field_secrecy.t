use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use lib 't/lib';
use TestSelectoComponents;
use Selecto;
use Selecto::Components::Config ();
use Selecto::Components::Explorer ();

# PE :123/FV-03 through the Explorer request path: query-library names and
# choice filters are not permission to read internal fields. Sorting or
# filtering by one would reveal its values row by row.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE accounts (id integer primary key, name text, backup_code integer,
    secret_code integer, vip integer)');
$dbh->do(q{INSERT INTO accounts VALUES (1, 'a', 10, 300, 1), (2, 'b', 20, 100, NULL), (3, 'c', 30, 200, 1)});

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Accounts',
    source => {
        source_table => 'accounts', primary_key => 'id',
        fields => [qw(id name backup_code secret_code vip)],
        columns => {
            id => {type => 'integer'}, name => {type => 'string'}, backup_code => {type => 'integer'},
            secret_code => {type => 'integer', internal => 1}, vip => {type => 'integer', internal => 1},
        },
        associations => {},
    },
    schemas => {}, joins => {},
    components => {filter_choices => {
        secret_code => {label => 'Code', choices => [{value => '100', label => 'Hundred'}]},
        code_or_backup => {label => 'Effective code', choices => [{value => '100', label => 'Hundred'}],
            conditional => {when_field => 'name', present_field => 'secret_code', absent_field => 'backup_code'}},
        either_code => {label => 'Backup code', choices => [{value => '10', label => 'Ten'}],
            conditional => {when_field => 'vip', present_field => 'backup_code', absent_field => 'backup_code'}},
    }},
    query_library => {
        orderings => {by_secret => {order_by => [['secret_code', 'asc']]}},
        segments => {
            secret_at_least => {label => 'Secret at least', parameters => {min => {type => 'integer'}},
                filters => [['gte', 'secret_code', ['param', 'min']]]},
            vip_only => {label => 'VIP', filters => [['not_null', 'vip']]},
            named => {label => 'Named', filters => [['not_null', 'name']]},
        },
        projections => {listing => {fields => ['id']}},
        views => {
            secret_listing => {projection => 'listing', ordering => 'by_secret'},
            vip_listing => {projection => 'listing', segments => ['vip_only']},
        },
    },
});

sub explorer {
    my (%config) = @_;
    return Selecto::Components::Explorer->new(config => Selecto::Components::Config->new(
        id => 'accounts', title => 'Accounts', path => '/explore/accounts',
        engine_factory => sub {
            Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        },
        %config,
    ));
}

# The request path: parameters are read from the controller as for a GET.
sub request {
    my ($explorer, %params) = @_;
    my $model = $explorer->model(TestSelectoComponents::Controller->new(params => {
        q => 1, view => 'detail', field => 'id', order => 'id', limit => 25, page => 1, %params,
    }));
    return $model;
}

sub ids {
    my ($model) = @_;
    return undef unless $model->{state}->valid && $model->{result};
    return [map { $_->{id} } @{$model->{result}{records}}];
}

sub filter { my ($field, $op, $value) = @_; (filter_field => $field, filter_op => $op, filter_value => $value // '') }

my $explorer = explorer();
my %refused = (
    'sorting by an internal field' => [order => 'secret_code'],
    'a view ordering by an internal field' => [query_library_view => 'secret_listing'],
    'a parameterized segment on an internal field' => [query_library_segment => 'secret_at_least',
        query_library_param_name => 'min', query_library_param_value => 150],
    'a fixed segment on an internal field' => [query_library_segment => 'vip_only'],
    'a view segment on an internal field' => [query_library_view => 'vip_listing'],
    'an undeclared value on a choice filter over an internal field' => [filter('secret_code', 'eq', 300)],
    'a range on a choice filter over an internal field' => [filter('secret_code', 'gt', 150)],
    'an undeclared value among declared ones' => [filter('secret_code', 'in', '100,300')],
    'a null test on a choice filter over an internal field' => [filter('secret_code', 'not_null')],
    'an undeclared value on a conditional filter reading an internal field' => [filter('code_or_backup', 'eq', 300)],
    'a null test on a conditional filter reading an internal field' => [filter('code_or_backup', 'is_null')],
    'an undeclared value on a conditional filter switching on an internal field' => [filter('either_code', 'eq', 20)],
);
for my $name (sort keys %refused) {
    my $model = request($explorer, @{$refused{$name}});
    ok(!$model->{state}->valid, "$name is refused") or diag explain ids($model);
    ok(!$model->{result}, "$name runs no query");
}

is_deeply(ids(request($explorer, query_library_segment => 'named')), [1, 2, 3],
    'a segment on public fields still applies');
is_deeply(ids(request($explorer, filter('secret_code', 'eq', 100))), [2],
    'a declared choice still filters an internal field');
is_deeply(ids(request($explorer, filter('code_or_backup', 'in', '100'))), [2],
    'a declared choice still filters through a conditional internal field');
is_deeply(ids(request($explorer, filter('either_code', 'eq', 10))), [1],
    'a declared choice still switches on an internal field');
is_deeply(ids(request($explorer, filter('secret_code', 'eq', ''))), [1, 2, 3],
    'an unfinished choice filter stays a draft');

require Selecto::Components::Renderer::Builder;
my $filter_map = $explorer->config->filter_map($domain);
my $operators = sub { [map { $_->[0] } @{Selecto::Components::Renderer::Builder::_filter_operators_for_filter(
    $explorer->config, $filter_map->{$_[0]}, {})}] };
is_deeply($operators->('code_or_backup'), [qw(eq ne in not_in)], 'the picker offers a choices-only filter no null test');

my $host_listed = explorer(filter_fields => ['secret_code']);
is_deeply(ids(request($host_listed, filter('secret_code', 'gt', 150))), [1, 3],
    'a host that lists the field in filter_fields may filter it freely');

for my $field (qw(secret_code code_or_backup either_code)) {
    for my $json ('[""]', '["", "100"]') {
        my $model = request($explorer, filter_field => $field, filter_op => 'in', filter_values_json => $json);
        ok !$model->{state}->valid, "$field rejects undeclared empty membership $json";
        ok !$model->{result}, 'rejected empty membership executes no query';
    }
}
ok Selecto::Components::State::_declared_choice({filter_choices => [{value => ''}]}, 'in', '', ['']),
    'an explicitly declared empty membership choice remains allowed';
done_testing;
