use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use JSON::PP ();
use Mojolicious;
use Mojo::Util qw(xml_escape);
use Storable qw(dclone);
use Test::More;
use Test::Mojo;
use Selecto::Components::Templates::Form ();
use Selecto::Components::Templates::InstanceStore::Memory ();

my $json = JSON::PP->new->utf8(1)->canonical(1);
sub fixture {
    my ($name) = @_;
    open my $handle, '<:raw', "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/$name"
        or die "missing protocol fixture\n";
    local $/;
    return $json->decode(<$handle>);
}
my $manifest = fixture('order-editor.compile.json');
my $case = fixture('order-editor.draft.json');
my ($form) = @{$manifest->{forms}};
my %records = (
    alpha => {42 => dclone($case->{record})},
    beta => {42 => dclone($case->{record})},
);
my $form_changed = 0;
my $writes = 0;
my $sequence = 0;
my $service = Selecto::Components::Templates::Form->new(
    store => Selecto::Components::Templates::InstanceStore::Memory->new(
        id_generator => sub { 'form-' . ++$sequence },
    ),
    row_id_generator => sub { 'draft:row-' . ++$sequence },
    resolve_form => sub {
        my ($owner, $id) = @_;
        return undef unless $records{$owner->{tenant}}{$id};
        my $resolved = dclone($form);
        $resolved->{contract_fingerprint} = 'sha256:' . ('f' x 64)
            if $form_changed;
        return $resolved;
    },
    load_record => sub {
        my ($owner, $id) = @_;
        return dclone($records{$owner->{tenant}}{$id});
    },
    write_record => sub {
        my ($owner, $id, $authorized_form, $baseline, $draft) = @_;
        die "stale_record: changed since opening\n"
            unless $json->encode($records{$owner->{tenant}}{$id}) eq $json->encode($baseline);
        die "contract_changed: fingerprint changed\n"
            unless $authorized_form->{contract_fingerprint} eq $form->{contract_fingerprint};
        $records{$owner->{tenant}}{$id} = _persist($draft);
        $writes++;
        return {status => 'ok'};
    },
);

my $app = Mojolicious->new;
$app->secrets(['form-http-test']);
my $owner = sub {
    my ($c) = @_;
    my $tenant = $c->req->headers->header('X-Test-Tenant') // '';
    return undef unless $tenant eq 'alpha' || $tenant eq 'beta';
    return {tenant => $tenant, actor => 'editor'};
};
$app->routes->get('/editor/:id')->to(cb => sub {
    my ($c) = @_;
    my $scope = $owner->($c);
    return $c->render(text => 'Unauthenticated', status => 401) unless $scope;
    my $model = $service->open(owner_scope => $scope, record_id => $c->stash('id'));
    return _response($c, $model);
});
$app->routes->post('/editor/:instance/:operation')->to(cb => sub {
    my ($c) = @_;
    my $scope = $owner->($c);
    return $c->render(text => 'Unauthenticated', status => 401) unless $scope;
    my $operation = $c->stash('operation');
    my $path = eval { $json->decode($c->param('path') // '[]') };
    $path = undef if $@;
    my %args = (
        owner_scope => $scope, instance_id => $c->stash('instance'),
        revision => $c->param('revision'), operation => $operation,
        path => $path,
    );
    my $model;
    if ($operation eq 'save') {
        $model = $service->save(%args);
    }
    else {
        $args{field} = $c->param('field');
        $args{value} = $c->param('value');
        $args{value} = 0 + $args{value}
            if ($args{field} // '') eq 'quantity'
            && defined($args{value}) && $args{value} =~ /\A[0-9]+\z/;
        $args{relationship} = $c->param('relationship');
        $args{fields} = {sku => ($c->param('sku') // 'NEW'), quantity => 1}
            if $operation eq 'add';
        $model = $service->change(%args);
    }
    return _response($c, $model);
});

sub _response {
    my ($c, $model) = @_;
    my $status = $model->{status};
    return $c->render(text => xml_escape($status),
        status => $status eq 'not_found' ? 404 : 409)
        unless $status eq 'ok' || $status eq 'saved';
    my $snapshot = $model->{snapshot};
    my $instance = xml_escape($snapshot->{instance_id});
    my $revision = $snapshot->{revision};
    my $base = "/editor/$instance";
    my $html = '<section id="order-editor" data-revision="' . $revision . '">' .
        '<form hx-post="' . $base . '/edit" hx-target="#order-editor" hx-swap="outerHTML">' .
        '<input type="hidden" name="revision" value="' . $revision . '">' .
        '<input type="hidden" name="path" value="[]">' .
        '<input type="hidden" name="field" value="status">' .
        '<input name="value" value="' . xml_escape($snapshot->{draft}{fields}{status}) . '">' .
        '<button type="submit">Edit status</button></form>';
    my $line = $snapshot->{draft}{owned}{lines}[0];
    my $allocation = $line->{owned}{allocations}[0];
    my $nested_path = $json->encode([
        lines => $line->{identity}, allocations => $allocation->{identity},
    ]);
    $html .= '<form hx-post="' . $base . '/edit" hx-target="#order-editor" hx-swap="outerHTML">' .
        '<input type="hidden" name="revision" value="' . $revision . '">' .
        '<input type="hidden" name="path" value="' . xml_escape($nested_path) . '">' .
        '<input type="hidden" name="field" value="quantity">' .
        '<input name="value" value="' . $allocation->{fields}{quantity} . '">' .
        '<button type="submit">Edit allocation</button></form>';
    for my $action (qw(add discard save)) {
        $html .= '<form hx-post="' . $base . '/' . $action .
            '" hx-target="#order-editor" hx-swap="outerHTML">' .
            '<input type="hidden" name="revision" value="' . $revision . '">' .
            ($action eq 'add' ? '<input type="hidden" name="relationship" value="lines">' : '') .
            '<button type="submit">' . $action . '</button></form>';
    }
    $html .= '</section>';
    return $c->render(text => $html, format => 'html');
}

sub _persist {
    my ($node) = @_;
    my $saved = dclone($node);
    delete $saved->{intent};
    $saved->{identity} =~ s/\Adraft:/saved:/;
    for my $name (keys %{$saved->{owned}}) {
        $saved->{owned}{$name} = [
            map { _persist($_) }
            grep { ($_->{intent} // '') ne 'delete' }
            @{$saved->{owned}{$name}}
        ];
    }
    return $saved;
}

my $t = Test::Mojo->new($app);
$t->get_ok('/editor/42')->status_is(401);
$t->get_ok('/editor/42' => {'X-Test-Tenant' => 'alpha'})
    ->status_is(200)
    ->element_exists('#order-editor[data-revision="0"]')
    ->element_exists('form[hx-post="/editor/form-1/edit"][hx-target="#order-editor"]')
    ->content_unlike(qr/tenant|contract_fingerprint/);
my $headers = {'X-Test-Tenant' => 'alpha', 'HX-Request' => 'true'};
$t->post_ok('/editor/form-1/edit' => $headers => form => {
    revision => 0, path => $json->encode(['lines', 'line:7', 'allocations', 'allocation:9']),
    field => 'quantity', value => 3,
})->status_is(200)->element_exists('#order-editor[data-revision="1"]')
    ->element_exists('input[name="value"][value="3"]');
$t->post_ok('/editor/form-1/edit' => $headers => form => {
    revision => 0, path => '[]', field => 'status', value => 'stale',
})->status_is(409)->content_is('conflict');
$t->post_ok('/editor/form-1/edit' => {'X-Test-Tenant' => 'beta'} => form => {
    revision => 1, path => '[]', field => 'status', value => 'foreign',
})->status_is(404)->content_is('not_found');
$t->post_ok('/editor/form-1/edit' => $headers => form => {
    revision => 1, path => '["lines","line:other"]', field => 'quantity', value => 9,
})->status_is(409)->content_is('invalid_change');
$t->post_ok('/editor/form-1/add' => $headers => form => {
    revision => 1, path => '[]', relationship => 'lines', sku => 'C-300',
})->status_is(200)->element_exists('#order-editor[data-revision="2"]');
is $writes, 0, 'HTMX edits remain server-owned drafts until save';
$t->post_ok('/editor/form-1/save' => $headers => form => {revision => 2})
    ->status_is(200)->element_exists('#order-editor[data-revision="4"]');
is $writes, 1, 'save invokes the host write callback once';
is $records{alpha}{42}{owned}{lines}[0]{owned}{allocations}[0]{fields}{quantity}, 3,
    'nested edit reached the authorized tenant record';
is scalar @{$records{alpha}{42}{owned}{lines}}, 2, 'nested create reached the host writer';
is $records{beta}{42}{owned}{lines}[0]{owned}{allocations}[0]{fields}{quantity}, 1,
    'other tenant record remains unchanged';
$t->post_ok('/editor/form-1/save' => $headers => form => {revision => 2})
    ->status_is(409)->content_is('conflict');
is $writes, 1, 'stale save does not write twice';

$t->get_ok('/editor/42' => $headers)->status_is(200)
    ->element_exists('#order-editor[data-revision="0"]');
$t->post_ok('/editor/form-3/edit' => $headers => form => {
    revision => 0, path => '[]', field => 'status', value => 'approved',
})->status_is(200)->element_exists('#order-editor[data-revision="1"]');
$records{alpha}{42}{fields}{status} = 'changed elsewhere';
my $rejected = $service->save(
    owner_scope => {tenant => 'alpha', actor => 'editor'},
    instance_id => 'form-3', revision => 1,
);
is $rejected->{status}, 'write_rejected', 'host rejects stale record inside write boundary';
is $rejected->{code}, 'stale_record', 'host failure stays structured';
is $rejected->{snapshot}{revision}, 3, 'rejected write releases reservation at a fresh revision';
is $records{alpha}{42}{fields}{status}, 'changed elsewhere', 'rejected write does not mutate record';
$t->post_ok('/editor/form-3/discard' => $headers => form => {revision => 3})
    ->status_is(200)->element_exists('#order-editor[data-revision="4"]');
$form_changed = 1;
$t->post_ok('/editor/form-3/edit' => $headers => form => {
    revision => 4, path => '[]', field => 'status', value => 'closed',
})->status_is(409)->content_is('contract_changed');

done_testing;
