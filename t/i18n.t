use 5.034;
use strict;
use warnings;

use Test::More;
use Storable qw(dclone);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Actions ();
use Selecto::Components::Config ();
use Selecto::Components::I18N ();
use Selecto::Components::QueryLibrary ();
use Selecto::Components::State ();
use Selecto::Domain ();

my $contract = dclone(TestSelectoComponents::domain()->contract);
$contract->{extensions} = {
    i18n => {
        namespace => 'selecto.products',
        terms => {
            'domain.title' => {default => 'Product Explorer'},
            'measures.count.label' => {default => 'Product count'},
        },
    },
};
delete $contract->{domain_fingerprint};
my $domain = Selecto::Domain->parse($contract, strict => 1);
my $fingerprint = $domain->fingerprint;

my %translations = (
    'selecto.products.domain.title' => 'Explorateur de produits',
    'selecto.products.fields.unit_price.label' => 'Argent',
    'selecto.products.fields.product_name.label' => 'Zulu produit',
    'selecto.products.query_library.segments.low_stock.label' => 'Stock faible',
    'selecto.products.query_library.segments.low_stock.description' => 'Sous le seuil fourni.',
    'selecto.products.actions.build_shipments.label' => 'Construire les expéditions',
    'selecto.products.actions.build_shipments.description' => 'Regrouper les produits sélectionnés.',
    'selecto.products.actions.build_shipments.submit_label' => 'Construire',
    'selecto.products.actions.build_shipments.selection.group_inputs.carrier_id.label' => 'Transporteur',
    'selecto.products.actions.build_shipments.selection.row_details.stock.label' => 'Inventaire',
);
my @lookups;
my $spec = TestSelectoComponents::config();
my $base_config = Selecto::Components::Config->new(
    %$spec,
    id => 'products',
    localizer => sub {
        my ($key, $default, $context) = @_;
        push @lookups, {key => $key, default => $default, context => $context};
        return $translations{$key} // $default;
    },
);
my $controller = bless {}, 'TestSelectoComponents::LocalizationController';
my $config = $base_config->for_request($controller);

is $config->localize($domain, 'domain.title', $config->title),
    'Explorateur de produits', 'domain title is localized from its semantic dictionary key';

my $fields = $config->field_catalog($domain);
my %field = map { $_->{path} => $_ } @$fields;
is $field{unit_price}{label}, 'Argent', 'root field labels are localized';
is $field{product_name}{label}, 'Zulu produit', 'a second root field label is localized';
my @localized_positions = map { $fields->[$_]{path} } 0 .. $#$fields;
ok _before(\@localized_positions, 'unit_price', 'product_name'),
    'field catalog sorting uses localized semantic labels';

my $segments = Selecto::Components::QueryLibrary->entries(
    $domain, 'segments', $config,
);
my ($low_stock) = grep { $_->{id} eq 'low_stock' } @$segments;
is $low_stock->{label}, 'Stock faible', 'query-library labels are localized';
is $low_stock->{description}, 'Sous le seuil fourni.',
    'query-library descriptions are localized';

my $resolved = Selecto::Components::Actions->find(
    $config, $domain, undef, 'build_shipments',
);
is $resolved->{action}{label}, 'Construire les expéditions', 'action labels are localized';
is $resolved->{action}{description}, 'Regrouper les produits sélectionnés.',
    'action descriptions are localized';
is $resolved->{action}{submit_label}, 'Construire', 'action submit labels are localized';
is $resolved->{action}{selection}{group_inputs}[0]{label}, 'Transporteur',
    'action group input labels are localized';
is $resolved->{action}{selection}{row_details}[0]{label}, 'Inventaire',
    'action row-detail labels are localized';

my $terms = Selecto::Components::I18N->terms($domain, {
    title => $config->title,
    measures => $config->measures,
});
my %term = map { $_->{key} => $_ } @$terms;
is $term{'selecto.products.domain.title'}{default}, 'Product Explorer',
    'term discovery includes domain metadata defaults';
is $term{'selecto.products.fields.product_name.label'}{default}, 'Product Name',
    'term discovery includes humanized field defaults';
is $term{'selecto.products.actions.build_shipments.selection.group_inputs.carrier_id.label'}{default},
    'Carrier ID', 'term discovery includes nested action form labels';

my $fallback = Selecto::Components::Config->new(
    %$spec,
    id => 'products',
    localizer => sub { die "dictionary unavailable\n" },
);
is $fallback->localize($domain, 'domain.title', 'Product Explorer'), 'Product Explorer',
    'dictionary failures fall back to portable domain text';

my $state_localized = Selecto::Components::State->from_input($config, $domain, {
    q => 1, view => 'detail', field => ['product_name'], limit => 25, page => 1,
});
my $state_fallback = Selecto::Components::State->from_input($fallback, $domain, {
    q => 1, view => 'detail', field => ['product_name'], limit => 25, page => 1,
});
is $state_localized->query_signature, $state_fallback->query_signature,
    'localized presentation does not change canonical query identity';
is $domain->fingerprint, $fingerprint,
    'request-time localization does not mutate the domain fingerprint';
is $domain->contract->{source}{columns}{product_name}{label}, undef,
    'request-time localization does not mutate portable field metadata';
ok scalar(grep { $_->{context}{semantic} eq 'fields.product_name.label' } @lookups),
    'localizer receives semantic context suitable for host adapters';
ok scalar(grep { $_->{context}{controller} == $controller } @lookups),
    'request-local config supplies the current controller to the host localizer';

done_testing;

sub _before {
    my ($items, $left, $right) = @_;
    my %position;
    @position{@$items} = 0 .. $#$items;
    return $position{$left} < $position{$right};
}
