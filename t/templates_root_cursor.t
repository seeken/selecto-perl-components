use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Storable qw(dclone);
use Test::More;
use Selecto::Components::Templates::RootCursor ();

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my $source = _json("$fixtures/order-root-page.compile.json")->{sources}[0];
delete $source->{query}{page};
$source->{query}{limit} = 1;
my $config = {
    page_size => 1,
    order_by => [{field => 'id', direction => 'asc'}],
    order_types => ['integer'], primary_key => 'id',
};
my $snapshot = {
    instance_id => 'instance-1', release_id => 'release-1',
    template_fingerprint => 'sha256:template-1',
    inputs => {}, state => {search => 'PO'},
    sources => {
        $source->{id} => {
            generation => 1, status => 'ready',
            result => {
                rows => [{id => 1, order_number => 'PO-100'}],
                root_page => {
                    config => $config, has_more => JSON::PP::true,
                    after_values => [1],
                },
            },
        },
    },
};
my $scope = {
    tenant_id => 'tenant-7', principal_id => 'actor-1',
    authorization_revision => 'acl-2', membership_revision => 'open-orders-v1',
};
my $secret = 's' x 32;
my %current = (
    snapshot => $snapshot, source_id => $source->{id},
    source_plan => $source, scope => $scope, secret => $secret,
);

my $issued = Selecto::Components::Templates::RootCursor->issue(
    %current, now => 1000, ttl_seconds => 60,
);
is $issued->{status}, 'ok', 'host issues a root cursor from its stored page';
like $issued->{token}, qr/\Arc1\.1060\.[0-9a-f]{64}\z/,
    'root token exposes only expiry and keyed digest';
unlike $issued->{token}, qr/tenant-7|PO-100/,
    'root token does not reveal tenant or row content';

my $resolved = Selecto::Components::Templates::RootCursor->resolve(
    %current, token => $issued->{token}, now => 1001, ttl_seconds => 60,
);
is $resolved->{status}, 'ok', 'current root token resolves';
is_deeply $resolved->{position}, {after_values => [1]},
    'only the server-held root tuple is returned';

my $final = dclone($snapshot);
$final->{sources}{$source->{id}}{result}{rows} = [{id => 4}];
$final->{sources}{$source->{id}}{result}{root_page}{has_more} = JSON::PP::false;
$final->{sources}{$source->{id}}{result}{root_page}{after_values} = undef;
my $final_issue = Selecto::Components::Templates::RootCursor->issue(
    %current, snapshot => $final, now => 1000, ttl_seconds => 60,
);
is $final_issue->{token}, undef, 'final root page has no continuation token';
my $final_resolve = Selecto::Components::Templates::RootCursor->resolve(
    %current, snapshot => $final, token => $issued->{token},
    now => 1001, ttl_seconds => 60,
);
is $final_resolve->{code}, 'invalid_root_cursor',
    'old token does not resolve against a final page';

my $other_tenant = {%$scope, tenant_id => 'tenant-8'};
my $other_principal = {%$scope, principal_id => 'actor-2'};
my $other_revision = {%$scope, authorization_revision => 'acl-3'};
my $other_membership = {%$scope, membership_revision => 'open-orders-v2'};
my $new_release = dclone($snapshot);
$new_release->{release_id} = 'release-2';
my $new_template = dclone($snapshot);
$new_template->{template_fingerprint} = 'sha256:other';
my $new_generation = dclone($snapshot);
$new_generation->{sources}{$source->{id}}{generation} = 2;
my $new_binding = dclone($snapshot);
$new_binding->{state}{search} = 'changed';
my $new_source = dclone($source);
$new_source->{query}{limit} = 2;
my $new_position = dclone($snapshot);
$new_position->{sources}{$source->{id}}{result}{root_page}{after_values} = [4];
my $new_row = dclone($snapshot);
$new_row->{sources}{$source->{id}}{result}{rows} = [{id => 4}];
my $offset_source = dclone($source);
$offset_source->{query}{page} = {expression => 'state.root_page'};

for my $change (
    [$snapshot, $source, $other_tenant, $secret, $issued->{token}, 1001],
    [$snapshot, $source, $other_principal, $secret, $issued->{token}, 1001],
    [$snapshot, $source, $other_revision, $secret, $issued->{token}, 1001],
    [$snapshot, $source, $other_membership, $secret, $issued->{token}, 1001],
    [$new_release, $source, $scope, $secret, $issued->{token}, 1001],
    [$new_template, $source, $scope, $secret, $issued->{token}, 1001],
    [$new_generation, $source, $scope, $secret, $issued->{token}, 1001],
    [$new_binding, $source, $scope, $secret, $issued->{token}, 1001],
    [$snapshot, $new_source, $scope, $secret, $issued->{token}, 1001],
    [$new_position, $source, $scope, $secret, $issued->{token}, 1001],
    [$new_row, $source, $scope, $secret, $issued->{token}, 1001],
    [$snapshot, $source, $scope, ('t' x 32), $issued->{token}, 1001],
    [$snapshot, $source, $scope, $secret, "$issued->{token}" . '0', 1001],
    [$snapshot, $source, $scope, $secret, $issued->{token}, 1061],
) {
    my ($candidate, $candidate_source, $candidate_scope, $candidate_secret,
        $token, $now) = @$change;
    my $result = Selecto::Components::Templates::RootCursor->resolve(
        %current, snapshot => $candidate, source_plan => $candidate_source,
        scope => $candidate_scope, secret => $candidate_secret,
        token => $token, now => $now, ttl_seconds => 60,
    );
    is $result->{code}, 'invalid_root_cursor',
        'changed root scope, source or expired token fails closed';
}

my $undeclared = Selecto::Components::Templates::RootCursor->issue(
    %current, source_plan => $offset_source,
);
is $undeclared->{code}, 'invalid_root_cursor',
    'offset-paged source cannot issue a root keyset token';

my $named_source = dclone($source);
$named_source->{query}{order_by} = [];
$named_source->{query}{select} = [qw(id order_number ordered_at)];
$named_source->{query}{ordering_choice} = {
    binding => {expression => 'state.sort'}, choices => [qw(oldest newest)],
};
my $named_snapshot = dclone($snapshot);
$named_snapshot->{state}{sort} = 'newest';
$named_snapshot->{sources}{orders}{result} = {
    rows => [{id => 7, ordered_at => '2026-09-18'}],
    root_page => {
        config => {
            page_size => 1,
            order_by => [
                {field => 'ordered_at', direction => 'desc'},
                {field => 'id', direction => 'desc'},
            ],
            order_types => [qw(date integer)], primary_key => 'id',
        },
        has_more => JSON::PP::true, after_values => ['2026-09-18', 7],
    },
};
my $named_cursor = Selecto::Components::Templates::RootCursor->issue(
    %current, snapshot => $named_snapshot, source_plan => $named_source,
    now => 1000, ttl_seconds => 60,
);
is $named_cursor->{status}, 'ok',
    'host issues a cursor for a declared named date ordering';
my $named_resolved = Selecto::Components::Templates::RootCursor->resolve(
    %current, snapshot => $named_snapshot, source_plan => $named_source,
    token => $named_cursor->{token}, now => 1001, ttl_seconds => 60,
);
is_deeply $named_resolved->{position}, {after_values => ['2026-09-18', 7]},
    'date position stays server-held and typed';
$named_snapshot->{state}{sort} = 'oldest';
my $stale_named = Selecto::Components::Templates::RootCursor->resolve(
    %current, snapshot => $named_snapshot, source_plan => $named_source,
    token => $named_cursor->{token}, now => 1001, ttl_seconds => 60,
);
is $stale_named->{code}, 'invalid_root_cursor',
    'sorting invalidates the old named-order cursor';

my $decimal_source = dclone($source);
$decimal_source->{query}{select} = [qw(id order_number amount)];
$decimal_source->{query}{order_by} = [
    {field => 'amount', direction => 'asc'},
    {field => 'id', direction => 'asc'},
];
my $decimal_snapshot = dclone($snapshot);
$decimal_snapshot->{sources}{orders}{result} = {
    rows => [{id => 1, amount => '9007199254740993.2500'}],
    root_page => {
        config => {
            page_size => 1, order_by => $decimal_source->{query}{order_by},
            order_types => [qw(decimal integer)], primary_key => 'id',
        },
        has_more => JSON::PP::true,
        after_values => ['9007199254740993.25', 1],
    },
};
my $decimal_cursor = Selecto::Components::Templates::RootCursor->issue(
    %current, snapshot => $decimal_snapshot, source_plan => $decimal_source,
    now => 1000, ttl_seconds => 60,
);
is $decimal_cursor->{status}, 'ok',
    'host issues an exact-decimal root cursor from native numeric text';
my $decimal_resolved = Selecto::Components::Templates::RootCursor->resolve(
    %current, snapshot => $decimal_snapshot, source_plan => $decimal_source,
    token => $decimal_cursor->{token}, now => 1001, ttl_seconds => 60,
);
is_deeply $decimal_resolved->{position},
    {after_values => ['9007199254740993.25', 1]},
    'large decimal stays exact in the server-held position';
my $wrong_decimal = dclone($decimal_snapshot);
$wrong_decimal->{sources}{orders}{result}{root_page}{after_values}[0] =
    '9007199254740993.2500';
my $wrong_decimal_cursor = Selecto::Components::Templates::RootCursor->issue(
    %current, snapshot => $wrong_decimal, source_plan => $decimal_source,
);
is $wrong_decimal_cursor->{code}, 'invalid_root_cursor',
    'noncanonical decimal tuple cannot be issued';

my $descending_decimal = dclone($decimal_source);
$descending_decimal->{query}{order_by}[0]{direction} = 'desc';
my $null_decimal = dclone($decimal_snapshot);
$null_decimal->{sources}{orders}{result}{rows} = [{id => 5, amount => undef}];
$null_decimal->{sources}{orders}{result}{root_page}{config}{order_by} =
    $descending_decimal->{query}{order_by};
$null_decimal->{sources}{orders}{result}{root_page}{after_values} = [undef, 5];
my $null_cursor = Selecto::Components::Templates::RootCursor->issue(
    %current, snapshot => $null_decimal, source_plan => $descending_decimal,
    now => 1000, ttl_seconds => 60,
);
is $null_cursor->{status}, 'ok',
    'host issues a descending nullable-decimal cursor';
my $null_resolved = Selecto::Components::Templates::RootCursor->resolve(
    %current, snapshot => $null_decimal, source_plan => $descending_decimal,
    token => $null_cursor->{token}, now => 1001, ttl_seconds => 60,
);
is_deeply $null_resolved->{position}, {after_values => [undef, 5]},
    'nullable decimal position stays server-held';

done_testing;

sub _json {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "fixture unavailable: $path\n";
    local $/;
    my $bytes = <$handle>;
    close $handle;
    return JSON::PP->new->utf8(1)->decode($bytes);
}
