use 5.034;
use strict;
use warnings;
# Lets the expiry tests move the clock; undef keeps the real time.
our $NOW;
BEGIN { *CORE::GLOBAL::time = sub () { defined($main::NOW) ? $main::NOW : CORE::time() } }
use Test::More;
use Test::Mojo;
use Digest::SHA qw(hmac_sha256_hex);
use lib 't/lib';
use TestSelectoComponents;

# S23/SURF-06: the record editor signs the original values it hands the
# browser with the application secret. Mojolicious falls back to its moniker,
# which anyone can guess, so the editor neither signs nor verifies a snapshot
# without a secret the host chose.

my $editor_url = '/explore/products/records/101/edit?editor=product_profile';
my $snapshot = '{"created_on":"1999-01-01","discontinued":false,"product_name":"Forged","unit_price":"0"}';

sub app_with {
    my ($secrets) = @_;
    my $app = TestSelectoComponents::app();
    $secrets->($app);
    $app->routes->get('/test-csrf' => sub { my ($c) = @_; $c->render(text => $c->csrf_token) });
    return Test::Mojo->new($app);
}

my %weak = (
    'the Mojolicious default secret' => [sub { delete $_[0]{secrets} }, 'mojolicious'],
    'no secret at all' => [sub { $_[0]->secrets([]) }, 'selecto-components'],
    'an empty secret' => [sub { $_[0]->secrets(['']) }, ''],
    'the moniker as the secret' => [sub { $_[0]->secrets([$_[0]->moniker]) }, 'mojolicious'],
);
for my $name (sort keys %weak) {
    my ($configure, $guess) = @{$weak{$name}};
    # Mojolicious itself warns when it signs a session with no secret.
    local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ m{Mojolicious/Controller\.pm} };
    my $t = app_with($configure);
    $t->get_ok($editor_url)->status_is(500)
        ->element_exists_not('input[name="record_signature"]', "no snapshot is signed with $name");
    my $csrf = $t->get_ok('/test-csrf')->tx->res->text;
    $TestSelectoComponents::Adapter::LAST_WRITE = undef;
    $t->post_ok($editor_url => {Accept => 'application/json'} => form => {
        csrf_token => $csrf,
        record_snapshot => $snapshot,
        record_signature => hmac_sha256_hex(join("\x1f", 'product_profile', '101', $snapshot), $guess),
        editor_field_product_name => 'Overwritten',
        editor_field_unit_price => '0',
        editor_field_created_on => '1999-01-01',
    })->status_isnt(200, "a snapshot signed with the guessable key for $name is refused")
        ->json_is('/ok' => 0);
    ok(!$TestSelectoComponents::Adapter::LAST_WRITE, "nothing is written under $name");
}

my $t = app_with(sub { $_[0]->secrets(['a-host-chosen-secret']) });
$t->get_ok($editor_url)->status_is(200)->element_exists('input[name="record_signature"]');
my $form = $t->tx->res->dom->at('form[data-sc-record-editor-form]');
my %hidden = map { $_->attr('name') => $_->attr('value') } @{$form->find('input[type="hidden"]')->to_array};
$t->post_ok($editor_url => {Accept => 'application/json'} => form => {
    %hidden,
    record_signature => hmac_sha256_hex(join("\x1f", 'product_profile', '101', $hidden{record_snapshot}),
        'mojolicious'),
    editor_field_product_name => 'Overwritten',
})->status_is(403)->json_like('/message' => qr/snapshot is invalid/);
$t->post_ok($editor_url => {Accept => 'application/json'} => form => {
    %hidden,
    editor_field_product_name => 'Updated Widget',
    editor_field_unit_price => '12.5',
    editor_field_created_on => '2026-09-15',
})->status_is(200)->json_is('/ok' => 1);

# The signature also binds the session (its CSRF token), the engine tenant,
# the domain and when it was issued, so a signed form cannot be replayed in
# another session or tenant, or after record_editor_max_age.
my $bound_app = Mojolicious->new;
$bound_app->secrets(['a-host-chosen-secret']);
my $bound_config = TestSelectoComponents::config();
$bound_app->plugin('Selecto::Components' => {explorers => {products => {
    %$bound_config,
    record_editor_max_age => 60,
    engine_factory => sub {
        my ($c) = @_;
        return Selecto::Engine->new(
            domain => TestSelectoComponents::domain(),
            adapter => TestSelectoComponents::Adapter->new(dbh => bless({}, 'TestSelectoComponents::DBH')),
            scope => {tenant => $c->req->headers->header('X-Tenant') // 10},
        );
    },
}}});
$bound_app->routes->get('/test-csrf' => sub { my ($c) = @_; $c->render(text => $c->csrf_token) });
my $edit = {
    editor_field_product_name => 'Replayed Widget', editor_field_unit_price => '12.5',
    editor_field_created_on => '2026-09-15',
};
my $signed_form = sub {
    my ($t, %headers) = @_;
    $t->get_ok($editor_url => \%headers)->status_is(200)->element_exists('input[name="record_signed_at"]');
    my $form = $t->tx->res->dom->at('form[data-sc-record-editor-form]');
    return {map { $_->attr('name') => $_->attr('value') } @{$form->find('input[type="hidden"]')->to_array}};
};
my $save = sub {
    my ($t, $form, %headers) = @_;
    $TestSelectoComponents::Adapter::LAST_WRITE = undef;
    return $t->post_ok($editor_url => {Accept => 'application/json', %headers} => form => {%$form, %$edit});
};

my $alice = Test::Mojo->new($bound_app);
my $mallory = Test::Mojo->new($bound_app);
my $alice_form = $signed_form->($alice);
my $mallory_csrf = $mallory->get_ok('/test-csrf')->tx->res->text;
$save->($mallory, {%$alice_form, csrf_token => $mallory_csrf})->status_is(403)
    ->json_like('/message' => qr/snapshot is invalid/);
ok(!$TestSelectoComponents::Adapter::LAST_WRITE, 'a form signed for one session is refused in another');

my $tenant_form = $signed_form->($alice, 'X-Tenant' => 10);
$save->($alice, $tenant_form, 'X-Tenant' => 20)->status_is(403)->json_like('/message' => qr/snapshot is invalid/);
ok(!$TestSelectoComponents::Adapter::LAST_WRITE, 'a form signed for one tenant is refused for another');

my $forged_time = {%$tenant_form, record_signed_at => $tenant_form->{record_signed_at} + 30};
$save->($alice, $forged_time, 'X-Tenant' => 10)->status_is(403)->json_like('/message' => qr/snapshot is invalid/);
ok(!$TestSelectoComponents::Adapter::LAST_WRITE, 'the issue time is covered by the signature');

{
    local $NOW = $tenant_form->{record_signed_at} + 61;
    $save->($alice, $tenant_form, 'X-Tenant' => 10)->status_is(403)->json_like('/message' => qr/expired/);
    ok(!$TestSelectoComponents::Adapter::LAST_WRITE, 'a form older than record_editor_max_age is refused');
}
{
    local $NOW = $tenant_form->{record_signed_at} - 120;
    $save->($alice, $tenant_form, 'X-Tenant' => 10)->status_is(403)->json_like('/message' => qr/expired/);
    ok(!$TestSelectoComponents::Adapter::LAST_WRITE, 'a form issued in the future is refused');
}
{
    local $NOW = $tenant_form->{record_signed_at} + 59;
    $save->($alice, $tenant_form, 'X-Tenant' => 10)->status_is(200)->json_is('/ok' => 1);
    ok($TestSelectoComponents::Adapter::LAST_WRITE, 'the same session, tenant and domain within the age saves');
}

like(eval { Selecto::Components::Config->new(%$bound_config, id => 'products', record_editor_max_age => 0); 1 }
    ? '' : $@, qr/record_editor_max_age/, 'record_editor_max_age must be positive');

done_testing;
