use 5.034;
use strict;
use warnings;

use Test::More;
use Selecto::Components::Resource::Registry ();
use Selecto::Components::Resource::Composer ();

my $registry = Selecto::Components::Resource::Registry->new;
$registry->register_provider('core.accounting', {
    slot => 'accounting', title => 'Accounting', capability => 'loads.accounting',
});
$registry->register_provider('metro.accounting', {
    slot => 'accounting', title => 'Metro Accounting', capability => 'loads.accounting',
});
$registry->register_panel('metro.dispatch', {
    title => 'Dispatch', when => {dispatch_enabled => 1},
});
$registry->register_badge('core.rush', {
    label => 'Rush', enabled_by_default => 1, when => {rush => 1},
});
$registry->freeze;

eval { $registry->register_panel('metro.late', {}) };
like $@, qr/frozen/, 'frozen registries reject late mutation';

my $composer = Selecto::Components::Resource::Composer->new(
    registry => $registry,
    authorize => sub {
        return $_[0]{capability} eq 'loads.accounting'
            ? {status => 'enabled'} : {status => 'hidden'};
    },
);
my $blueprint = {
    panels => [
        {id => 'core.overview', title => 'Overview'},
        {slot => 'accounting'},
        {id => 'core.history', title => 'History'},
    ],
    slots => {accounting => {default_provider => 'core.accounting'}},
};
my $effective = $composer->compose(
    blueprint => $blueprint,
    profile => {
        id => 'client.metro',
        providers => {accounting => 'metro.accounting'},
        enable => ['metro.dispatch'],
        order => {panels => [qw(core.overview metro.dispatch metro.accounting core.history)]},
    },
    facts => {dispatch_enabled => 1, rush => 1},
);

is_deeply [map { $_->{id} } @{$effective->{panels}}],
    [qw(core.overview metro.dispatch metro.accounting core.history)],
    'profile selects a provider and deterministically orders additive panels';
is_deeply [map { $_->{id} } @{$effective->{badges}}], ['core.rush'],
    'applicable default contributions are composed';
is $effective->{profile_id}, 'client.metro', 'effective definition identifies its profile';

my $denied = Selecto::Components::Resource::Composer->new(
    registry => $registry,
    authorize => sub { return {status => 'hidden', reason_code => 'missing_privilege'} },
)->compose(
    blueprint => $blueprint,
    profile => {order => {panels => [qw(core.overview core.accounting core.history)]}},
    facts => {},
);
is_deeply [map { $_->{id} } @{$denied->{panels}}],
    [qw(core.overview core.history)],
    'authorization prunes a selected provider instead of disclosing it';

eval {
    $composer->compose(
        blueprint => $blueprint,
        profile => {providers => {accounting => 'metro.missing'}}, facts => {},
    );
};
like $@, qr/Unknown resource provider/, 'unknown provider selections fail closed';

done_testing;
