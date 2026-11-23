use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(from_json);
use Mojo::URL ();
use DBI ();
use Mojolicious;
use Selecto;
use Selecto::Components;

# Independently authored synthetic loads and client star, with deliberately
# different origin/destination and duplicate display names. No physical key
# column exists for inventory_location_id.
sub contract {
    return {schema_version => 1, name => 'Synthetic loads',
        source => {source_table => 'ck_ui_load', primary_key => 'id',
            fields => [qw(id status status2 orig_id dest_id inventory_location_id)],
            columns => {id => {type => 'integer'}, status => {type => 'string'}, status2 => {type => 'string'},
                orig_id => {type => 'integer'}, dest_id => {type => 'integer'},
                inventory_location_id => {type => 'integer', computed => {kind => 'expression', expression => [
                    'case',
                    [['and', ['eq', 'status2', 'I'], ['eq', 'status', 'D']], ['field', 'dest_id']],
                    [['and', ['eq', 'status2', 'I'], ['not', ['in', 'status', ['G', 'D', 'C']]]], ['field', 'orig_id']],
                ]}}},
            associations => {inventory_location => {queryable => 'client_party',
                owner_key => 'inventory_location_id', related_key => 'id'}}},
        schemas => {client_party => {source_table => 'ck_ui_client_profile', primary_key => 'id',
            fields => [qw(id co_name city state)],
            columns => {id => {type => 'integer'}, map { $_ => {type => 'string'} } qw(co_name city state)},
            associations => {}}},
        joins => {inventory_location => {type => 'star_dimension', name => 'Inventory Location',
            display_field => 'co_name', dimension_key => 'inventory_location_id'}}};
}
sub setup {
    my ($dbh) = @_;
    $dbh->do($_) for
        'CREATE TEMPORARY TABLE ck_ui_load (id integer primary key, status varchar(1), status2 varchar(1), orig_id integer, dest_id integer)',
        'CREATE TEMPORARY TABLE ck_ui_client_profile (id integer primary key, co_name varchar(50), city varchar(50), state varchar(2))',
        'CREATE TEMPORARY TABLE ck_ui_client_flags (client_id integer, flag_id integer, info varchar(1))',
        q{INSERT INTO ck_ui_client_profile VALUES (1,'Alpha','Arc','CO'), (2,'Beta','Bay','UT'), (3,'Alpha','Cove','AZ')},
        q{INSERT INTO ck_ui_client_flags VALUES (1,22,'Y'), (2,22,'Y'), (3,22,'N')},
        q{INSERT INTO ck_ui_load VALUES (1,'D','I',1,2), (2,'P','I',1,2), (3,'R','I',2,1),
            (4,'G','I',1,2), (5,'C','I',1,2), (6,'D','N',1,2), (7,'P',NULL,1,2),
            (8,NULL,'I',1,2), (9,'D','I',1,NULL), (10,'P','I',NULL,2), (11,'P','I',3,1)};
}
sub hidden {
    my ($form) = @_;
    my %input;
    push @{$input{$_->attr('name')}}, $_->attr('value') for @{$form->find('input[type="hidden"]')};
    return %input;
}
sub text { my $v = $_[0]->all_text; $v =~ s/\s+/ /g; $v =~ s/^ | $//g; return $v }

for my $backend (qw(sqlite postgresql)) {
    subtest $backend => sub {
        my $dbh;
        if ($backend eq 'sqlite') {
            $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
        } else {
            plan skip_all => 'PostgreSQL test URL not set' unless $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
            my $u = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
            die 'explicit PostgreSQL host and port required' unless $u->host && $u->port;
            $dbh = DBI->connect('dbi:Pg:dbname=' . substr($u->path, 1) . ';host=' . $u->host . ';port=' . $u->port,
                $u->username, $u->password, {RaiseError => 1, PrintError => 0});
        }
        setup($dbh);
        my $domain = Selecto::Domain->parse(contract(), strict => 1);
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend, dbh => $dbh));
        my $app = Mojolicious->new;
        $app->secrets(['computed-key-fixture']);
        $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {loads => {
            path => '/loads', title => 'Synthetic loads', default_fields => [qw(id inventory_location.co_name)],
            engine_factory => sub { $engine },
            measures => [{id => 'loads', label => 'Loads', aggregate => 'count'}],
        }}});
        my $t = Test::Mojo->new($app);
        my $get = sub {
            my (%input) = @_;
            $t->get_ok('/loads' => form => \%input)->status_is(200)
                or diag $t->tx->res->dom->find('.sc-error, [role=alert]')->map('all_text')->join('; ');
            return $t->tx->res->dom;
        };
        my $ids = sub {
            return [sort { $a <=> $b } map { 0 + text($_) }
                @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}];
        };
        my %summary = (q => 1, view => 'aggregate', field => 'id', group => 'inventory_location_id',
            measure => 'loads', limit => 25, page => 1);
        my $dom = $get->(%summary);
        my @rows = @{$dom->find('.sc-results tbody tr')};
        is scalar(@rows), 5, 'four key groups and the total';
        like $dom->all_text, qr/Inventory Location/, 'dimension name is displayed';
        is scalar(grep { text($_) =~ /Alpha/ } @rows), 2, 'equal display names keep separate stable-key groups';
        my ($beta) = grep { text($_) =~ /Beta/ } @rows;
        ok $beta, 'destination-based dimension displays its client name';
        my %drill = hidden($beta->at('form.sc-drilldown-form'));
        is_deeply $drill{filter_field}, ['inventory_location_id'], 'group drill filters computed key';
        is_deeply $drill{filter_value}, ['2'], 'group drill carries hidden ID, not label';
        $get->(%drill, field => 'id', order => 'id');
        is_deeply $ids->(), [1,3], 'group drill Detail rows match CASE (not orig_id)';

        $get->(q => 1, view => 'detail', field => 'id', filter_field => 'inventory_location_id',
            filter_op => 'eq', filter_value => 2, order => 'id');
        is_deeply $ids->(), [1,3], 'dimension filter matches the same Detail rows';
        $get->(q => 1, view => 'detail', field => 'id', filter_field => 'inventory_location.city',
            filter_op => 'eq', filter_value => 'Cove', order => 'id');
        is_deeply $ids->(), [11], 'association fields filter normally in Explorer';

        $dom = $get->(%summary);
        my ($missing) = grep { text($_) =~ /\[NULL\]/ } @{$dom->find('.sc-results tbody tr')};
        ok $missing, 'NULL key has a missing group';
        my %missing_drill = hidden($missing->at('form.sc-drilldown-form'));
        is_deeply $missing_drill{filter_op}, ['is_null'], 'missing drill filters NULL expression';
        $get->(%missing_drill, field => 'id', order => 'id');
        is_deeply $ids->(), [4..10], 'missing group Detail rows match';

        # Exercise the existing pivot path without changing pivot implementation.
        $dom = $get->(%summary, group => [qw(status2 inventory_location_id)], pivot_column => 'inventory_location_id');
        ok $dom->at('table.sc-pivot-table'), 'computed dimension is a pivot column';
        like $dom->at('.sc-pivot-table thead')->all_text, qr/Beta/, 'pivot heading displays dimension name';
        my ($button) = grep {
            my $v = from_json($_->attr('value'));
            ref($v) eq 'ARRAY' && @$v == 2 && ($v->[0] // '') eq 'I' && ($v->[1] // '') eq '2'
        } @{$dom->find('.sc-pivot-table button[name="grid_cell"]')};
        ok $button, 'pivot cell retains stable computed ID';
        my %cell_drill = hidden($dom->at('form.sc-pivot-drill-form'));
        $get->(%cell_drill, grid_cell => $button->attr('value'), field => 'id', order => 'id');
        is_deeply $ids->(), [1,3], 'pivot cell drill Detail rows match computed key';

        # A filtered aggregate retains the same dimension and count.
        $dom = $get->(%summary, filter_field => 'inventory_location_id', filter_op => 'eq', filter_value => 2);
        my @filtered = @{$dom->find('.sc-results tbody tr')};
        is scalar(@filtered), 2, 'filtered dimension group and total only';
        like $dom->all_text, qr/Beta/, 'filtered aggregate keeps its display';
        $dbh->disconnect;
    };
}
done_testing;
