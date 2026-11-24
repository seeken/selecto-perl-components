use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use SavedViewsFixture;
use TestSelectoComponents;
use Scalar::Util qw(blessed);
use Mojolicious ();
use Test::Mojo;
sub refuses {
    my ($code, $work, $label) = @_;
    my $ok = eval { $work->(); 1 };
    my $error = $@;
    my $actual = blessed($error) ? $error->code : "$error";
    like($actual, qr/\A\Q$code\E(?:\z|:)/, $label) or diag($ok ? 'succeeded' : $actual);
}
for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? ('postgresql') : ())) {
    subtest "four sources on $backend" => sub {
        my $f = SavedViewsFixture->new($backend, $ENV{SELECTO_PERL_TEST_POSTGRES_URL});
        my ($store, $config, $dbh) = @{$f}{qw(store config dbh)};
        my $ctx = TestSelectoComponents::Controller->new;
        my $url = '/explore/orders?q=1&field=order_ref';
        is(scalar(@{$store->targets($ctx, $config)}), 4, 'four writable destinations');
        my $unicode_id = Selecto::Components::SavedQueryStore::Domains::_id({name => 'personal'}, "north/\x{2603}");
        my (undef, $unicode_key) = $store->_identity($unicode_id);
        is($unicode_key, "north/\x{2603}", 'Unicode and path characters round trip through source ids');
        my @ids;
        for my $source (@{$f->{sources}}) {
            my $name = $source->{name};
            my $saved = $store->save_new($ctx, $config, {name => 'First', target => $name, url => $url});
            like($saved->{id}, qr/\A\Q$name\E\.[A-Za-z0-9_-]+\z/, "$name URL-safe namespaced id");
            push @ids, $saved->{id};
            my ($row) = grep { $_->{id} eq $saved->{id} } @{$store->list($ctx, $config)};
            is($row->{scope}, $source->{scope}, "$name scope");
            ok(!$row->{readonly}, "$name writable row");
            like($row->{row_revision}, qr/\Asha256:/, "$name native revision");
            is($row->{id}, $saved->{id}, "$name id stable across reload");
            refuses('SAVED_QUERY_CONFLICT', sub { $store->save_new($ctx, $config, {name => 'First', target => $name, url => $url}) }, "$name duplicate mapped");
            $store->update($ctx, $config, {id => $saved->{id}, name => 'Changed', url => $url . '&filter_field=piece_count&filter_op=gte&filter_value=2', row_revision => $row->{row_revision}});
            my ($changed) = grep { $_->{id} eq $row->{id} } @{$store->list($ctx, $config)};
            is($changed->{name}, 'Changed', "$name in-place update");
            isnt($changed->{revision}, $row->{revision}, "$name revision advanced");
            is_deeply($dbh->selectrow_arrayref("SELECT schedule,official,owner_id,created_by,modified_by FROM sv_$name"),
                ['weekly', 1, 11, 101, 101], "$name unmapped and host columns preserved");
            for my $op (qw(update delete)) {
                refuses('SAVED_QUERY_STALE', sub { $store->$op($ctx, $config, {id => $row->{id}, name => 'Stale', url => $url, revision => $row->{revision}}) }, "$name stale $op");
            }
            $ctx->{deny_source} = $name;
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {name => 'No', target => $name, url => $url}) }, "$name forbidden destination");
            my ($readonly) = grep { $_->{id} eq $row->{id} } @{$store->list($ctx, $config)};
            ok($readonly->{readonly}, "$name readonly listed");
            delete $ctx->{deny_source};
            $store->delete($ctx, $config, {id => $row->{id}, revision => $changed->{revision}});
            for my $op (qw(update delete)) {
                refuses('SAVED_QUERY_STALE', sub { $store->$op($ctx, $config, {id => $row->{id}, name => 'Missing', url => $url, revision => $changed->{revision}}) }, "$name missing $op");
            }
        }
        is(scalar(keys %{ {map { $_ => 1 } @ids} }), 4, 'source ids never clash');
        refuses('SAVED_QUERY_INVALID', sub { $store->save_new($ctx, $config, {target => 'personal', name => 'Bad', url => '/explore/orders?q=1&field=absent'}) }, 'invalid save checked');
        $dbh->do(q{INSERT INTO sv_role_link (owner_id,name,url,kind,folder) VALUES (11,'Folder','/explore/orders','folder','Operations')});
        my ($folder) = grep { $_->{name} eq 'Folder' } @{$store->list($ctx, $config)};
        is($folder->{folder}, 'Operations', 'folder label retained');
        my ($folder_key) = $dbh->selectrow_array('SELECT id FROM sv_role_link');
        $store->save_new($ctx, $config, {target => 'role_link', name => 'Child', url => $url, parent => $folder_key, folder => 'Operations'});
        refuses('SAVED_QUERY_CONFLICT', sub { $store->delete($ctx, $config, {id => $folder->{id}, revision => $folder->{revision}}) }, 'nonempty folder cannot cascade');
        $dbh->do(q{INSERT INTO sv_personal (owner_id,name,url) VALUES (11,'Other Explorer','/explore/parties?q=1'), (11,'Other page','/reports'), (12,'Other owner','/explore/orders?q=1')});
        $dbh->do(q{INSERT INTO sv_company (owner_id,name,url) VALUES (11,'Shared private','/explore/orders?q=1&field=order_ref&field=contact_email')});
        $ctx->{private} = 1;
        my $rows = $store->list($ctx, $config);
        is_deeply([sort map { $_->{name} } @$rows], ['Child', 'Folder', 'Shared private'], 'only own Explorer and scope rows listed, including restricted shared view');
        my ($shared) = grep { $_->{name} eq 'Shared private' } @$rows;
        is(Selecto::Components::SavedView->explain($config, $ctx, $shared->{url})->{omitted_fields}, 1, 'shared view can be explained with redaction');
        my $app = Mojolicious->new;
        $app->secrets(['invented-saved-views-test']);
        $app->plugin('Selecto::Components' => {explorers => {orders => {%$config, websocket_enabled => 0}}});
        my $http = Test::Mojo->new($app);
        $http->get_ok('/explore/orders?q=1&field%5B%5D=order_ref&filter_field%5B%5D=piece_count&filter_value%5B%5D=2')
            ->status_is(200)->element_exists('input[name="filter_field"][value="piece_count"]');
        my $token = $http->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
        $http->post_ok('/explore/orders/saved-queries' => {Accept => 'application/json'} => form => {
            csrf_token => $token, saved_query_name => 'HTTP view', saved_query_target => 'personal', saved_query_url => $url,
        })->status_is(200)->json_is('/ok', 1);
        my ($http_row) = grep { $_->{name} eq 'HTTP view' } @{$store->list($ctx, $config)};
        $http->get_ok($url . '&saved_query_id=' . $http_row->{id})->status_is(200)
            ->element_exists('input[name="saved_query_revision"][value="' . $http_row->{revision} . '"]');
        $http->post_ok('/explore/orders/saved-queries' => {Accept => 'application/json'} => form => {
            csrf_token => $token, saved_query_operation => 'update', confirm_saved_query_update => 1,
            saved_query_name => 'HTTP changed', saved_query_id => $http_row->{id}, saved_query_revision => $http_row->{revision},
            saved_query_url => $url,
        })->status_is(200)->json_is('/ok', 1);
        $http->post_ok('/explore/orders/saved-queries/delete' => {Accept => 'application/json'} => form => {
            csrf_token => $token, saved_query_name => 'Folder', saved_query_id => $folder->{id}, saved_query_revision => $folder->{revision},
        })->status_is(409);
        my $column_saved = $store->save_new($ctx, $config, {target => 'personal', name => 'Column token', url => $url});
        $dbh->do(q{UPDATE sv_personal SET official = NULL WHERE name = 'Column token'});
        $ctx->{column_revision} = 1;
        my ($column) = grep { $_->{id} eq $column_saved->{id} } @{$store->list($ctx, $config)};
        ok(exists($column->{row_revision}) && !defined($column->{row_revision}), 'native null column token retained');
        $store->update($ctx, $config, {id => $column->{id}, name => 'Column changed', url => $url, row_revision => undef});
        $store->delete($ctx, $config, {id => $column->{id}, revision => $column->{revision}});
        pass('null token supports native update and form-envelope delete');
        delete $ctx->{column_revision};
        {
            local $f->{sources}[0]{fields}{name} = 'owner_id';
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'personal', name => '11', url => $url}) }, 'host_bound_field maps from native error');
        }
        {
            local $f->{sources}[0]{fields}{state} = 'url';
            local $f->{sources}[0]{fields}{url};
            delete $f->{sources}[0]{fields}{url};
            local $f->{sources}[0]{explorer_filter} = sub { $_[0]{name} =~ /\AState / };
            my $saved = $store->save_new($ctx, $config, {target => 'personal', name => 'State row', state => {q => 1, field => 'order_ref'}});
            my ($row) = grep { $_->{id} eq $saved->{id} } @{$store->list($ctx, $config)};
            like($row->{url}, qr/field=order_ref/, 'state storage emits Explorer URL');
            $store->update($ctx, $config, {id => $row->{id}, name => 'State changed', state => {q => 1, field => 'id'}, row_revision => $row->{row_revision}});
            my ($changed) = grep { $_->{id} eq $saved->{id} } @{$store->list($ctx, $config)};
            like($changed->{url}, qr/field=id/, 'state storage updates in place');
            $store->delete($ctx, $config, {id => $changed->{id}, revision => $changed->{revision}});
        }
        my $source = $f->{sources}[0];
        local $source->{readonly} = 1;
        refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'personal', name => 'No', url => $url}) }, 'explicit readonly source refuses');
        is(scalar(@{$store->targets($ctx, $config)}), 3, 'readonly source excluded from destinations');
        $f->cleanup;
    };
    subtest "destination and listing callbacks on $backend" => sub {
        my $f = SavedViewsFixture->new($backend, $ENV{SELECTO_PERL_TEST_POSTGRES_URL});
        my ($store, $config, $dbh) = @{$f}{qw(store config dbh)};
        my $ctx = TestSelectoComponents::Controller->new;
        my $source = $f->role_destinations($ctx);
        my $url = '/explore/orders?q=1&field=order_ref';
        $dbh->do(q{INSERT INTO sv_role_link (id,owner_id,name,url,kind) VALUES
            (101,11,'Studio','/explore/orders','folder'), (102,22,'Research','/explore/orders','folder')});
        my $targets = [grep { $_->{id} =~ /\Arole_link\./ } @{$store->targets($ctx, $config)}];
        is_deeply($targets, [
            {id => 'role_link.role_11', label => 'Role 11 (top level)'},
            {id => 'role_link.role_11_folder_101', label => 'Role 11 / Studio'},
            {id => 'role_link.role_22', label => 'Role 22 (top level)'},
            {id => 'role_link.role_22_folder_102', label => 'Role 22 / Research'},
        ], 'two roles each offer top level and scoped folder');
        for my $target (@$targets) {
            my $saved = $store->save_new($ctx, $config, {target => $target->{id}, name => $target->{id}, url => $url,
                parent => 999, folder => 'Forged label', values => {owner_id => 99, parent_id => 999}, owner_id => 99});
            my ($owner, $parent) = $target->{id} =~ /role_(\d+)(?:_folder_(\d+))?/;
            is_deeply($dbh->selectrow_arrayref('SELECT owner_id,parent_id,created_by,modified_by FROM sv_role_link WHERE name = ?', undef, $target->{id}),
                [$owner, $parent, 101, 101], "$target->{id} uses freshly trusted values, ignoring request assignments");
            my ($row) = grep { $_->{id} eq $saved->{id} } @{$store->list($ctx, $config)};
            is($row->{folder}, defined($parent) ? ($owner == 11 ? 'Studio' : 'Research') : undef, 'parent name supplies folder label');
        }
        for my $target ('role_link', 'role_link.forged', 'role_link.role_99', 'role_link.role_11_folder_102') {
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => $target, name => 'Forged', url => $url}) }, "$target refused");
        }
        $ctx->{deny_role} = 22;
        is(scalar(grep { $_->{id} =~ /\Arole_link\./ } @{$store->targets($ctx, $config)}), 2, 'revoked role excluded');
        refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.role_22', name => 'Revoked', url => $url}) }, 'target listed before role revocation refused');
        delete $ctx->{deny_role};
        $ctx->{deny_folder} = 101;
        refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.role_11_folder_101', name => 'Revoked folder', url => $url}) }, 'target listed before folder revocation refused');
        delete $ctx->{deny_folder};
        $ctx->{deny_source} = 'role_link';
        is(scalar(grep { $_->{id} =~ /\Arole_link\./ } @{$store->targets($ctx, $config)}), 0, 'write_check still narrows destinations');
        refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.role_11', name => 'Denied', url => $url}) }, 'write_check still narrows insert');
        delete $ctx->{deny_source};
        {
            my $factory = $source->{engine_factory};
            local $source->{engine_factory} = sub { # An unaware factory cannot turn an owner assignment into authority.
                my ($context, $config, $source) = @_;
                return $factory->($context, $config, $source);
            };
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.role_22', name => 'Wrong context', url => $url}) }, 'host-bound destination must match factory context');
        }
        $dbh->do(q{INSERT INTO sv_role_link (id,owner_id,name,url,kind,tenant_id) VALUES
            (1001,11,'Other tenant','/explore/orders','folder',8),
            (1002,33,'Other role','/explore/orders','folder',7)});
        {
            local $source->{destinations} = sub { return [{key => 'bad_parent', label => 'Bad parent', values => {owner_id => 11, parent_id => 1001}}] };
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.bad_parent', name => 'Tenant guard', url => $url}) }, 'core parent tenant guard still applies');
        }
        {
            my $factory = $source->{engine_factory};
            local $source->{engine_factory} = sub {
                my ($context, $config, $source, $destination) = @_;
                my $other = $destination ? {%$destination, values => {%{$destination->{values}}, parent_id => 102}} : undef;
                return $factory->($context, $config, $source, $other);
            };
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.role_11_folder_101', name => 'Parent context', url => $url}) }, 'core context-sourced foreign key refuses mismatch');
        }
        {
            local $source->{destinations} = sub { return [{key => 'denied_field', label => 'Denied field', values => {owner_id => 11, schedule => 'daily'}}] };
            refuses('SAVED_QUERY_FORBIDDEN', sub { $store->save_new($ctx, $config, {target => 'role_link.denied_field', name => 'Field grant', url => $url}) }, 'destination assignments need core field grants');
        }
        $dbh->do(q{INSERT INTO sv_role_link (owner_id,name,url,parent_id) VALUES
            (11,'Invisible tenant parent','/explore/orders?q=1',1001),
            (11,'Invisible role parent','/explore/orders?q=1',1002)});
        $dbh->do(q{INSERT INTO sv_role_link (id,owner_id,name,url) VALUES (1200,11,'Not a folder','/explore/orders?q=1')});
        $dbh->do(q{INSERT INTO sv_role_link (owner_id,name,url,parent_id) VALUES (11,'Invisible nonfolder parent','/explore/orders?q=1',1200)});
        my $rows = $store->list($ctx, $config);
        is(scalar(grep { $_->{name} =~ /\AInvisible/ } @$rows), 0, 'children with out-of-scope or nonfolder parents omitted');
        {
            local $source->{explorer_filter} = sub { return ($_[0]{kind} // '') ne 'folder' };
            my ($child) = grep { $_->{name} eq 'role_link.role_11_folder_101' } @{$store->list($ctx, $config)};
            is($child->{folder}, 'Studio', 'parent label uses read scope even when menu filter excludes parent');
        }
        $dbh->do(q{INSERT INTO sv_personal (owner_id,name,url) VALUES (11,'Legacy','/explore/orders?legacy=order_ref')});
        my $personal = $f->{sources}[0];
        my $calls = 0;
        $personal->{list_url} = sub {
            my ($url, $row, $context, $config, $source) = @_;
            ++$calls;
            is($row->{name}, 'Legacy', 'list_url receives stored row');
            is($source->{name}, 'personal', 'list_url receives source');
            return '/explore/orders?q=1&field=order_ref&field=contact_email';
        };
        $dbh->do(q{INSERT INTO sv_personal (owner_id,name,url) VALUES (11,'Excluded','/reports'), (12,'Out of scope','/explore/orders')});
        $ctx->{private} = 1;
        my ($legacy) = grep { $_->{name} eq 'Legacy' } @{$store->list($ctx, $config)};
        is($calls, 1, 'list_url runs only after read scope and explorer filter');
        like($legacy->{url}, qr/field=contact_email/, 'listing rewrites without checking unreadable selection');
        is($dbh->selectrow_array(q{SELECT url FROM sv_personal WHERE name = 'Legacy'}), '/explore/orders?legacy=order_ref', 'listing leaves stored URL alone');
        delete $personal->{list_url};
        $store->update($ctx, $config, {id => $legacy->{id}, name => 'Migrated', url => $url, revision => $legacy->{revision}});
        pass('update uses actual stored revision despite rewritten URL');
        my ($migrated) = grep { $_->{name} eq 'Migrated' } @{$store->list($ctx, $config)};
        $personal->{list_url} = sub { return '/explore/orders?q=1&field=contact_email' };
        my ($rewritten) = grep { $_->{id} eq $migrated->{id} } @{$store->list($ctx, $config)};
        $store->delete($ctx, $config, {id => $rewritten->{id}, row_revision => $rewritten->{row_revision}});
        pass('delete uses actual stored revision despite rewritten URL');
        delete $personal->{list_url};
        $ctx->{private} = 0;
        my $app = Mojolicious->new;
        $app->secrets(['invented-destination-test']);
        $app->hook(before_dispatch => sub { $_[0]{role_destinations} = 1 });
        $app->plugin('Selecto::Components' => {explorers => {orders => {%$config, websocket_enabled => 0}}});
        my $http = Test::Mojo->new($app);
        $http->get_ok($url)->status_is(200)->element_exists('select[name="saved_query_target"] option[value="role_link.role_22_folder_102"]');
        my $token = $http->tx->res->dom->at('input[name="csrf_token"]')->attr('value');
        $http->post_ok('/explore/orders/saved-queries' => {Accept => 'application/json'} => form => {
            csrf_token => $token, saved_query_name => 'HTTP destination', saved_query_target => 'role_link.role_22_folder_102', saved_query_url => $url,
        })->status_is(200)->json_is('/ok', 1);
        is_deeply($dbh->selectrow_arrayref(q{SELECT owner_id,parent_id FROM sv_role_link WHERE name = 'HTTP destination'}), [22,102], 'HTTP target reaches chosen role and folder');
        $http->post_ok('/explore/orders/saved-queries' => {Accept => 'application/json'} => form => {
            csrf_token => $token, saved_query_name => 'HTTP forged', saved_query_target => 'role_link.forged', saved_query_url => $url,
        })->status_is(403);
        $f->cleanup;
    };
}
done_testing;
