use 5.034;
use strict;
use warnings;

use FindBin ();
use DBI ();
use JSON::PP ();
use Mojolicious ();
use Mojo::Util qw(xml_escape);
use Test::More;
use Test::Mojo;
use Selecto::Components::Templates::Form ();
use Selecto::Components::Templates::InstanceStore::Memory ();

my $url = $ENV{SELECTO_PERL_COMPONENTS_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_COMPONENTS_TEST_POSTGRES_URL is not configured'
    unless defined($url) && length($url);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

my $dbh = DBI->connect($url, undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
}) or die 'test database connection failed';

# Temporary tables isolate this proof from other tests and leave no persistent
# application records behind. The writer transaction uses this same handle.
$dbh->do('CREATE TEMP TABLE template_form_orders (tenant text NOT NULL, id integer NOT NULL, status text NOT NULL, version integer NOT NULL, PRIMARY KEY (tenant, id))');
$dbh->do('CREATE TEMP TABLE template_form_lines (tenant text NOT NULL, id integer NOT NULL, order_id integer NOT NULL, sku text NOT NULL, quantity integer NOT NULL, PRIMARY KEY (tenant, id), FOREIGN KEY (tenant, order_id) REFERENCES template_form_orders (tenant, id))');
$dbh->do('CREATE TEMP TABLE template_form_allocations (tenant text NOT NULL, id integer NOT NULL, line_id integer NOT NULL, warehouse text NOT NULL, quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 2), PRIMARY KEY (tenant, id), FOREIGN KEY (tenant, line_id) REFERENCES template_form_lines (tenant, id))');
for my $tenant (qw(alpha beta)) {
    $dbh->do('INSERT INTO template_form_orders VALUES (?, 42, ?, 1)', undef, $tenant, 'open');
    $dbh->do('INSERT INTO template_form_lines VALUES (?, 7, 42, ?, 2)', undef, $tenant, 'A-100');
    $dbh->do('INSERT INTO template_form_allocations VALUES (?, 9, 7, ?, 1)', undef, $tenant, 'A1');
}

my $json = JSON::PP->new->utf8(1)->canonical(1);
my $fixture = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/order-editor.compile.json";
open my $handle, '<:raw', $fixture or die 'missing form contract fixture';
local $/;
my ($form) = @{$json->decode(<$handle>)->{forms}};
close $handle;
my $instance_sequence = 0;

sub load_record {
    my ($owner, $id) = @_;
    return undef unless defined($id) && !ref($id) && "$id" =~ /\A[1-9][0-9]*\z/;
    my $tenant = $owner->{tenant};
    my $root = $dbh->selectrow_hashref(
        'SELECT id, status FROM template_form_orders WHERE tenant = ? AND id = ?',
        undef, $tenant, $id,
    ) or return undef;
    my $lines = $dbh->selectall_arrayref(
        'SELECT id, sku, quantity FROM template_form_lines WHERE tenant = ? AND order_id = ? ORDER BY id',
        {Slice => {}}, $tenant, $id,
    );
    return {
        identity => "order:$root->{id}", fields => {status => $root->{status}},
        owned => {lines => [map {
            my $line = $_;
            my $allocations = $dbh->selectall_arrayref(
                'SELECT id, warehouse, quantity FROM template_form_allocations WHERE tenant = ? AND line_id = ? ORDER BY id',
                {Slice => {}}, $tenant, $line->{id},
            );
            +{
                identity => "line:$line->{id}",
                fields => {sku => $line->{sku}, quantity => 0 + $line->{quantity}},
                owned => {allocations => [map {
                    +{identity => "allocation:$_->{id}",
                      fields => {warehouse => $_->{warehouse}, quantity => 0 + $_->{quantity}},
                      owned => {}}
                } @$allocations]},
            }
        } @$lines]},
    };
}

my $service = Selecto::Components::Templates::Form->new(
    store => Selecto::Components::Templates::InstanceStore::Memory->new(
        id_generator => sub { 'pg-form-' . ++$instance_sequence },
    ),
    resolve_form => sub {
        my ($owner, $id) = @_;
        return load_record($owner, $id) ? $form : undef;
    },
    load_record => \&load_record,
    write_record => sub {
        my ($owner, $id, $authorized_form, $baseline, $draft) = @_;
        die "contract_changed: form changed\n"
            unless $authorized_form->{contract_fingerprint} eq $form->{contract_fingerprint};
        $dbh->begin_work;
        my $ok = eval {
            my $version = $dbh->selectrow_array(
                'SELECT version FROM template_form_orders WHERE tenant = ? AND id = ? FOR UPDATE',
                undef, $owner->{tenant}, $id,
            );
            die "record_unavailable: order is outside tenant\n" unless defined $version;
            die "stale_record: order changed since opening\n"
                unless $json->encode(load_record($owner, $id)) eq $json->encode($baseline);
            $dbh->do(
                'UPDATE template_form_orders SET status = ?, version = version + 1 WHERE tenant = ? AND id = ? AND version = ?',
                undef, $draft->{fields}{status}, $owner->{tenant}, $id, $version,
            ) == 1 or die "stale_record: version changed\n";
            for my $line (@{$draft->{owned}{lines}}) {
                die "unsupported_draft: this writer only handles edits\n" if exists $line->{intent};
                my ($line_id) = $line->{identity} =~ /\Aline:([1-9][0-9]*)\z/
                    or die "unsupported_draft: only existing lines are supported here\n";
                $dbh->do(
                    'UPDATE template_form_lines SET sku = ?, quantity = ? WHERE tenant = ? AND id = ? AND order_id = ?',
                    undef, $line->{fields}{sku}, $line->{fields}{quantity}, $owner->{tenant}, $line_id, $id,
                ) == 1 or die "record_unavailable: line is outside order\n";
                for my $allocation (@{$line->{owned}{allocations}}) {
                    die "unsupported_draft: this writer only handles edits\n"
                        if exists $allocation->{intent};
                    my ($allocation_id) = $allocation->{identity} =~ /\Aallocation:([1-9][0-9]*)\z/
                        or die "unsupported_draft: only existing allocations are supported here\n";
                    $dbh->do(
                        'UPDATE template_form_allocations SET warehouse = ?, quantity = ? WHERE tenant = ? AND id = ? AND line_id = ?',
                        undef, $allocation->{fields}{warehouse}, $allocation->{fields}{quantity},
                        $owner->{tenant}, $allocation_id, $line_id,
                    ) == 1 or die "record_unavailable: allocation is outside line\n";
                }
            }
            $dbh->commit;
            1;
        };
        unless ($ok) {
            my $error = $@;
            eval { $dbh->rollback };
            die $error =~ /\A[a-z_]+:/ ? $error : "write_rejected: database rejected the draft\n";
        }
        return {status => 'ok'};
    },
);

my $app = Mojolicious->new;
$app->secrets(['live-form-test']);
$app->routes->get('/orders/:id/edit')->to(cb => sub {
    my ($c) = @_;
    my $tenant = $c->req->headers->header('X-Test-Tenant') // '';
    return $c->render(text => 'Unavailable', status => 404)
        unless $tenant eq 'alpha' || $tenant eq 'beta';
    return response($c, $service->open(
        owner_scope => {tenant => $tenant, actor => 'editor'},
        record_id => $c->stash('id'),
    ));
});
$app->routes->post('/forms/:instance/:operation')->to(cb => sub {
    my ($c) = @_;
    my $tenant = $c->req->headers->header('X-Test-Tenant') // '';
    return $c->render(text => 'Unavailable', status => 404)
        unless $tenant eq 'alpha' || $tenant eq 'beta';
    my %args = (
        owner_scope => {tenant => $tenant, actor => 'editor'},
        instance_id => $c->stash('instance'), revision => $c->param('revision'),
    );
    my $operation = $c->stash('operation');
    my $result;
    if ($operation eq 'save') {
        $result = $service->save(%args);
    } elsif ($operation eq 'edit') {
        my $path = eval { $json->decode($c->param('path') // '[]') };
        $path = undef if $@;
        my $value = $c->param('value');
        $value = 0 + $value if ($c->param('field') // '') eq 'quantity'
            && defined($value) && $value =~ /\A[0-9]+\z/;
        $result = $service->change(%args, operation => 'edit', path => $path,
            field => $c->param('field'), value => $value);
    } else {
        return $c->render(text => 'Unavailable', status => 404);
    }
    return response($c, $result);
});

sub response {
    my ($c, $result) = @_;
    my $status = $result->{status};
    return $c->render(text => xml_escape($status), status =>
        $status eq 'not_found' ? 404 : 409)
        unless $status eq 'ok' || $status eq 'saved';
    my $snapshot = $result->{snapshot};
    my $revision = $snapshot->{revision};
    my $instance = xml_escape($snapshot->{instance_id});
    my $html = '<section id="order-editor" data-revision="' . $revision . '">' .
        '<p data-status="' . xml_escape($snapshot->{draft}{fields}{status}) . '"></p>' .
        '<p data-quantity="' . $snapshot->{draft}{owned}{lines}[0]{owned}{allocations}[0]{fields}{quantity} . '"></p>' .
        '<form hx-post="/forms/' . $instance . '/save" hx-target="#order-editor" hx-swap="outerHTML">' .
        '<input type="hidden" name="revision" value="' . $revision . '"><button>Save</button></form></section>';
    return $c->render(text => $html, format => 'html');
}

my $t = Test::Mojo->new($app);
my $alpha = {'X-Test-Tenant' => 'alpha', 'HX-Request' => 'true'};
$t->get_ok('/orders/42/edit' => $alpha)->status_is(200)
    ->element_exists('#order-editor[data-revision="0"]');
my $instance = $t->tx->res->dom->at('form')->attr('hx-post');
$instance =~ s{/save\z}{};
my $allocation_path = $json->encode(['lines', 'line:7', 'allocations', 'allocation:9']);
$t->post_ok("$instance/edit" => $alpha => form => {
    revision => 0, path => '[]', field => 'status', value => 'approved',
})->status_is(200)->element_exists('#order-editor[data-revision="1"]');
$t->post_ok("$instance/edit" => $alpha => form => {
    revision => 1, path => $allocation_path, field => 'quantity', value => 3,
})->status_is(200)->element_exists('[data-quantity="3"]');
$t->post_ok("$instance/save" => $alpha => form => {revision => 2})
    ->status_is(409)->content_is('write_rejected');
is($dbh->selectrow_array('SELECT status FROM template_form_orders WHERE tenant = ? AND id = 42', undef, 'alpha'),
    'open', 'failed nested write rolled back the root update');
is($dbh->selectrow_array('SELECT quantity FROM template_form_allocations WHERE tenant = ? AND id = 9', undef, 'alpha'),
    1, 'failed nested write did not change the allocation');
$t->post_ok("$instance/edit" => {'X-Test-Tenant' => 'beta'} => form => {
    revision => 4, path => '[]', field => 'status', value => 'foreign',
})->status_is(404)->content_is('not_found');
$t->post_ok("$instance/edit" => $alpha => form => {
    revision => 4, path => $allocation_path, field => 'quantity', value => 2,
})->status_is(200)->element_exists('[data-quantity="2"]');
$t->post_ok("$instance/save" => $alpha => form => {revision => 5})
    ->status_is(200)->element_exists('#order-editor[data-revision="7"]');
is($dbh->selectrow_array('SELECT status FROM template_form_orders WHERE tenant = ? AND id = 42', undef, 'alpha'),
    'approved', 'corrected draft committed root update');
is($dbh->selectrow_array('SELECT quantity FROM template_form_allocations WHERE tenant = ? AND id = 9', undef, 'alpha'),
    2, 'corrected draft committed nested allocation update');
is($dbh->selectrow_array('SELECT status FROM template_form_orders WHERE tenant = ? AND id = 42', undef, 'beta'),
    'open', 'other tenant root stayed unchanged');
is($dbh->selectrow_array('SELECT quantity FROM template_form_allocations WHERE tenant = ? AND id = 9', undef, 'beta'),
    1, 'other tenant allocation stayed unchanged');

$dbh->disconnect;
done_testing;
