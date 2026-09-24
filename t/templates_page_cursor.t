use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Scalar::Util qw(dualvar);
use Storable qw(dclone);
use Test::More;
use Selecto::Components::Templates::PageCursor ();

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $source = _json("$fixtures/order-lines-top-n.compile.json")->{sources}[0];
$source->{query}{collections}[0]{page_size} = 1;
$source->{query}{collections}[0]{collections}[0]{page_size} = 1;
my $result = _json("$fixtures/collection-page-result.cases.json")
    ->{cases}[0]{expected};
my $snapshot = {
    instance_id => 'instance-1',
    release_id => 'release-1',
    template_fingerprint => 'sha256:template-1',
    inputs => {}, state => {search => 'A'},
    sources => {
        $source->{id} => {
            status => 'ready', generation => 1, result => $result,
        },
    },
};
my $scope = {
    tenant_id => 'tenant-7', principal_id => 'actor-1',
    authorization_revision => 'acl-2', membership_revision => 'open-orders-v1',
};
my $secret = 's' x 32;
my $unpaged_source = dclone($source);
delete $unpaged_source->{query}{collections}[0]{page_size};
delete $unpaged_source->{query}{collections}[0]{collections}[0]{page_size};
my $undeclared = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $snapshot, source_id => $source->{id},
    source_plan => $unpaged_source, scope => $scope, secret => $secret,
);
is $undeclared->{code}, 'invalid_page_cursor',
    'host does not issue a page token for an undeclared collection page';

my $issued = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $snapshot, source_id => $source->{id}, source_plan => $source,
    scope => $scope, secret => $secret, now => 1000, ttl_seconds => 60,
);
is $issued->{status}, 'ok', 'host issues cursors from server-held pages';
is scalar(@{$issued->{pages}}), 4, 'every page retains its public parent identity';
like $issued->{pages}[0]{token}, qr/\Apc1\.1060\.[0-9a-f]{64}\z/,
    'cursor exposes only expiry and keyed digest';
is $issued->{pages}[2]{token}, undef, 'final page has no continuation token';
is $issued->{pages}[3]{token}, undef, 'other final page has no token';
unlike $issued->{pages}[0]{token}, qr/tenant-7|A/,
    'cursor does not expose tenant or seek tuple';

my $line_token = $issued->{pages}[0]{token};
my $line = Selecto::Components::Templates::PageCursor->resolve(
    snapshot => $snapshot, source_id => $source->{id}, source_plan => $source,
    scope => $scope, secret => $secret, token => $line_token,
    now => 1001, ttl_seconds => 60,
);
is $line->{status}, 'ok', 'current line position resolves';
is_deeply $line->{position}, {
    collection_path => ['lines'], parent_path => [1],
    after_values => ['A', 11],
}, 'resolved position remains server-owned';

my $nested = Selecto::Components::Templates::PageCursor->resolve(
    snapshot => $snapshot, source_id => $source->{id}, source_plan => $source,
    scope => $scope, secret => $secret,
    token => $issued->{pages}[1]{token}, now => 1001, ttl_seconds => 60,
);
is_deeply $nested->{position}{parent_path}, [1, 11],
    'nested parent has a separate cursor';

my $native_snapshot = dclone($snapshot);
$native_snapshot->{sources}{$source->{id}}{result}{pages}[0]{parent_path} =
    [dualvar(1, '1')];
$native_snapshot->{sources}{$source->{id}}{result}{pages}[0]{after_values} =
    ['A', dualvar(11, '11')];
my $native_issued = Selecto::Components::Templates::PageCursor->issue(
    snapshot => $native_snapshot, source_id => $source->{id}, source_plan => $source,
    scope => $scope, secret => $secret, now => 1000, ttl_seconds => 60,
);
my $native_resolved = Selecto::Components::Templates::PageCursor->resolve(
    snapshot => $native_snapshot, source_id => $source->{id}, source_plan => $source,
    scope => $scope, secret => $secret,
    token => $native_issued->{pages}[0]{token}, now => 1001, ttl_seconds => 60,
);
is $native_resolved->{status}, 'ok',
    'native database integer cursor resolves after token sealing';
is(JSON::PP->new->canonical->encode($native_resolved->{position}),
    '{"after_values":["A",11],"collection_path":["lines"],"parent_path":[1]}',
    'cursor copy preserves JSON integer types from native database scalars');

my $other_tenant = {%$scope, tenant_id => 'tenant-8'};
my $other_principal = {%$scope, principal_id => 'actor-2'};
my $other_revision = {%$scope, authorization_revision => 'acl-3'};
my $other_membership = {%$scope, membership_revision => 'closed-orders-v1'};
my $new_release = dclone($snapshot);
$new_release->{release_id} = 'release-2';
my $new_generation = dclone($snapshot);
$new_generation->{sources}{$source->{id}}{generation} = 2;
my $new_binding = dclone($snapshot);
$new_binding->{state}{search} = 'changed';
my $other_parent = dclone($snapshot);
$other_parent->{sources}{$source->{id}}{result}{pages} = [
    @{$other_parent->{sources}{$source->{id}}{result}{pages}}[2, 3]
];
my $new_source = dclone($source);
$new_source->{query}{limit} = 1;

for my $change (
    [$snapshot, $source, $other_tenant, $secret, $line_token, 1001],
    [$snapshot, $source, $other_principal, $secret, $line_token, 1001],
    [$snapshot, $source, $other_revision, $secret, $line_token, 1001],
    [$snapshot, $source, $other_membership, $secret, $line_token, 1001],
    [$new_release, $source, $scope, $secret, $line_token, 1001],
    [$new_generation, $source, $scope, $secret, $line_token, 1001],
    [$new_binding, $source, $scope, $secret, $line_token, 1001],
    [$other_parent, $source, $scope, $secret, $line_token, 1001],
    [$snapshot, $new_source, $scope, $secret, $line_token, 1001],
    [$snapshot, $source, $scope, ('t' x 32), $line_token, 1001],
    [$snapshot, $source, $scope, $secret, "$line_token" . '0', 1001],
    [$snapshot, $source, $scope, $secret, $line_token, 1061],
) {
    my ($current_snapshot, $current_source, $current_scope, $current_secret,
        $token, $now) = @$change;
    my $resolved = Selecto::Components::Templates::PageCursor->resolve(
        snapshot => $current_snapshot, source_id => $source->{id},
        source_plan => $current_source, scope => $current_scope,
        secret => $current_secret, token => $token,
        now => $now, ttl_seconds => 60,
    );
    is $resolved->{code}, 'invalid_page_cursor',
        'changed scope, position or expired token fails closed';
}

done_testing;

sub _json {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "fixture unavailable: $path\n";
    local $/;
    my $bytes = <$handle>;
    close $handle;
    return JSON::PP->new->utf8(1)->decode($bytes);
}
