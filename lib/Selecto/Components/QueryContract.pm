package Selecto::Components::QueryContract;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);
use Selecto::Components::Graph::Capabilities ();
use Selecto::Components::QueryAssistant::Target ();

sub build {
    my ($class, %args) = @_;
    my ($config, $domain, $state) = @args{qw(config domain state)};
    die "query contract requires config, domain, and state\n"
        unless $config && $domain && $state;
    my @fields = map {
        my $field = $_;
        +{
            id => $field->{path}, label => $field->{label}, type => $field->{type},
            (defined($field->{association}) ? (association => $field->{association}) : ()),
            ($field->{denormalizing} ? (denormalizing => 1) : ()),
            (defined($field->{unit}) ? (unit => $field->{unit}) : ()),
            (defined($field->{behavior}) ? (behavior => $field->{behavior}) : ()),
            operators => [map { $_->[0] } @{$config->filter_operators($field->{type})}],
            group_formats => [map { $_->[0] } @{$config->group_formats($field->{type})}],
        }
    } @{$config->field_catalog($domain)};
    my @measures = map {
        my $measure = $_;
        +{
            id => $measure->{path}, label => $measure->{label}, type => $measure->{type},
            default_function => $measure->{default_function},
            functions => [map { $_->[0] } @{$config->measure_functions(
                $measure->{type}, !defined($measure->{field}),
            )}],
            (defined($measure->{source_unit}) ? (source_unit => $measure->{source_unit}) : ()),
            (defined($measure->{source_behavior}) ? (source_behavior => $measure->{source_behavior}) : ()),
        }
    } @{$config->measure_catalog($domain)};
    my $assistant = $config->query_assistant // {};
    my $choice_fields = ref($assistant->{choice_fields}) eq 'HASH'
        ? $assistant->{choice_fields} : {};
    $_->{choice_search} = 1 for grep { $choice_fields->{$_->{id}} } @fields;
    my $basis = {
        domain => $domain->fingerprint,
        policy => $assistant->{policy_version} // '1',
        scope => $args{scope} // '',
        views => $config->views,
        max_limit => 0 + $config->max_limit,
    };
    return {
        query_contract_version => 1,
        target_version => 1,
        explorer_id => $config->id,
        domain_id => $config->id,
        context_version => sha256_hex(encode_json($basis)),
        views => [@{$config->views}],
        limits => {
            max_filters => 0 + $config->max_filters,
            max_orders => 0 + $config->max_orders,
            max_measures => 0 + $config->max_measures,
            max_rows => 0 + $config->max_limit,
        },
        fields => \@fields,
        measures => \@measures,
        date_shortcuts => [map { +{id => $_->{id}, label => $_->{label}, group => $_->{group}} } @{$config->date_shortcuts}],
        graph => Selecto::Components::Graph::Capabilities->for_config($config, $domain),
        active_target => Selecto::Components::QueryAssistant::Target->from_state($state),
    };
}

1;
