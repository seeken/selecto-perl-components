package DomainCatalogFixture;
use strict;
use warnings;
use File::Temp qw(tempdir);
use JSON::PP ();
use Storable qw(dclone);
use Mojolicious;
use Selecto::Domain;
use Selecto::DomainCatalog;
use Selecto::DomainCatalog::Source::Code;
use Selecto::DomainCatalog::Source::File;
use Selecto::DomainCatalog::Source::Store;
use Selecto::DomainCatalog::MemoryStore;
use Selecto::Expression;
use Selecto::Components::DomainCatalog;

sub contract {
    my ($id, $name) = @_;
    return {schema_version => 1, domain_version => '1', name => $name // 'Orders',
        source => {source_table => 'orders', primary_key => 'id',
            fields => [qw(id account_id state private_note secret)],
            columns => {id => {type => 'integer', label => 'Order ID', description => 'Stable order identity'},
                account_id => {type => 'integer'}, state => {type => 'string', label => 'State'},
                private_note => {type => 'string', hidden => 1}, secret => {type => 'string', redacted => 1}},
            associations => {customer => {queryable => 'customers', owner_key => 'id', related_key => 'id', cardinality => 'one'}}},
        schemas => {customers => {source_table => 'customers', primary_key => 'id', fields => ['id'],
            columns => {id => {type => 'integer', description => 'Customer identity'}}, associations => {}}},
        joins => {customer => {source => 'customers', type => 'left'}},
        writes => {operations => {update => {enabled => 1, require_filter => 1}}, fields => {state => {updatable => 1}}},
        actions => {finish => {label => 'Finish', type => 'bulk_action', scope => 'bulk', capability => 'orders.finish',
            execution => {kind => 'updato', operation => 'update', set => {state => 'done'}}}},
        capabilities => {'orders.finish' => {operations => ['action', 'update'], action => 'finish'}},
        query_library => {segments => {open => {filters => [['eq', 'state', 'open']]}}},
        extensions => {catalog => {id => $id, adapter => 'sqlite', scope_policy => 'by_account'},
            i18n => {namespace => 'orders'}, authorization => {field_groups => {account => {
                tag => 'orders.account', label => 'Account', fields => ['account_id']}}}}};
}
sub fixture {
    my $directory = tempdir(CLEANUP => 1);
    my $files = contract('file_orders', 'File orders');
    open my $out, '>', "$directory/orders.json" or die $!;
    print {$out} JSON::PP->new->encode($files);
    close $out or die $!;
    my $before = contract('store_orders', 'Stored orders');
    my $store = Selecto::DomainCatalog::MemoryStore->new->put('orders', 'one', $before);
    my $after = dclone($before);
    $after->{domain_version} = '2';
    $after->{source}{fields} = [@{$after->{source}{fields}}, 'priority'];
    $after->{source}{columns}{priority} = {type => 'integer', description => 'Order priority'};
    $store->put('orders', 'two', $after);
    my $catalog = Selecto::DomainCatalog->new(adapter => 'sqlite', allowed_sources => [qw(orders customers)],
        scope_policies => {by_account => sub { {required_predicate => Selecto::Expression->eq('account_id', 11)} }},
        checks => [sub { my ($domain, $entry) = @_; return $entry->{id} eq 'file_orders'
            ? [{status => 'warning', code => 'review_label', message => 'Review <label>', path => '$.name'}] : [] }],
        pins => {store_orders => {revision => 'one', fingerprint => Selecto::Domain->parse($before)->fingerprint}},
        sources => [Selecto::DomainCatalog::Source::Code->new(label => 'Orders registry',
                domains => {code_orders => sub { contract('code_orders', 'Code orders') }}),
            Selecto::DomainCatalog::Source::File->new(directory => $directory, commit => 'abc123'),
            Selecto::DomainCatalog::Source::Store->new(store => $store, label => 'Reference store')]);
    return {catalog => $catalog, before => $before, directory => $directory};
}
sub app {
    my (%options) = @_;
    my $fixture = fixture();
    my $app = Mojolicious->new;
    $app->secrets(['catalog-invented-orders']);
    $app->log->level('fatal');
    $app->defaults(catalog_fixture => $fixture);
    Selecto::Components::DomainCatalog->mount($app, path => '/catalog', catalog => $fixture->{catalog},
        label_domain => Selecto::Domain->parse(contract('labels')),
        theme_resolver => sub { my ($c) = @_; return {scheme => $c->param('scheme') // 'light'} },
        domain_links_resolver => sub { my ($c, $entry) = @_; return [
            {label => 'Explorer', href => '/inspect?domain=' . $entry->{id}, kind => 'explorer'},
            {label => 'Privileges', href => '/access?domain=' . $entry->{id}, kind => 'privileges'}] },
        domain_columns_resolver => sub { return [{id => 'mcp', label => 'MCP', value => sub { 'Published / 3 fields left out' }}] },
        baselines_resolver => sub { return [{id => 'first', label => 'First document', against => $fixture->{before}}] },
        %options);
    return $app;
}
1;
