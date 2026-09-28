use 5.034;
use strict;
use warnings;
use Test::More;
use Mojo::Parameters;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::State;
use Selecto::Components::QueryBuilder;
use Selecto::API::EngineHandler;
use Selecto::Engine;
use Selecto::PostgreSQL;
{
    package TextFilters::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;
    sub execute_query ($self, $statement) {
        $self->{last} = $statement;
        return {columns => $statement->columns, rows => []};
    }
}

my $config = Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id => 'products');
my $domain = TestSelectoComponents::domain();
my $engine = Selecto::Engine->new(domain => $domain,
    adapter => TextFilters::Adapter->new(dbh => bless({}, 'TextFilters::DBH')));
for my $op (qw(starts_with starts_with_ci text_contains text_contains_ci ends_with ends_with_ci)) {
    my $state = Selecto::Components::State->from_input($config, $domain, {
        q => 1, view => 'detail', field => 'product_name',
        filter_field => 'product_name', filter_op => $op, filter_value => 'MiX%_!',
        filter_promote_field => 'product_name',
    });
    ok $state->valid, "$op is accepted by Explorer";
    ok $state->filters->[0]{promoted}, "$op can be promoted";
    my $restored = Selecto::Components::State->from_input($config, $domain,
        Mojo::Parameters->new(@{$state->query_pairs})->to_hash);
    is_deeply $restored->filters, $state->filters, "$op survives canonical/saved URL roundtrip";
    my $query = Selecto::Components::QueryBuilder->build($config, $domain, $state)->{query};
    my $statement = $engine->compile($query);
    my $payload = $state->api_query_payload($config, $domain);
    is $payload->{filters}[0]{op}, $op, "$op survives Explorer-to-API handoff";
    my $api_query = Selecto::API::EngineHandler->new->query($engine, $payload);
    is $engine->adapter->{last}->params->[0], $statement->params->[0],
        'API and Explorer bind identical literal search patterns';
    for my $type (qw(integer decimal boolean date utc_datetime)) {
        ok !$config->allows_filter_operator($type, $op), "$type does not advertise $op";
    }
}
done_testing;
