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

# Independently authored synthetic orders and party star, with deliberately
# different origin/destination and duplicate display names. No physical key
# column exists for current_party_id.
sub contract {
    return {schema_version => 1, name => 'Orders',
        source => {source_table => 'orders', primary_key => 'id',
            fields => [qw(id state_code hold_code origin_party_id destination_party_id current_party_id)],
            columns => {id => {type => 'integer'}, state_code => {type => 'string'}, hold_code => {type => 'string'},
                origin_party_id => {type => 'integer'}, destination_party_id => {type => 'integer'},
                current_party_id => {type => 'integer', computed => {kind => 'expression', expression => [
                    'case',
                    [['and', ['eq', 'hold_code', 'H'], ['eq', 'state_code', 'DL']], ['field', 'destination_party_id']],
                    [['and', ['eq', 'hold_code', 'H'], ['not', ['in', 'state_code', ['OP', 'DL', 'CX']]]], ['field', 'origin_party_id']],
                ]}}},
            associations => {current_party => {queryable => 'parties',
                owner_key => 'current_party_id', related_key => 'id'}}},
        schemas => {parties => {source_table => 'parties', primary_key => 'id',
            fields => [qw(id party_name city region)],
            columns => {id => {type => 'integer'}, map { $_ => {type => 'string'} } qw(party_name city region)},
            associations => {}}},
        joins => {current_party => {type => 'star_dimension', name => 'Current Party',
            display_field => 'party_name', dimension_key => 'current_party_id'}}};
}
sub setup {
    my ($dbh) = @_;
    $dbh->do($_) for
        'CREATE TEMPORARY TABLE orders (id integer primary key, state_code varchar(2), hold_code varchar(1), origin_party_id integer, destination_party_id integer)',
        'CREATE TEMPORARY TABLE parties (id integer primary key, party_name varchar(50), city varchar(50), region varchar(2))',
        'CREATE TEMPORARY TABLE service_flags (order_id integer, flag varchar(20), set_at timestamp)',
        q{INSERT INTO parties VALUES (1,'Alpha','Arc','CO'), (2,'Beta','Bay','UT'), (3,'Alpha','Cove','AZ')},
        q{INSERT INTO service_flags VALUES (1,'expedite',NULL), (2,'expedite',NULL), (3,'liftgate',NULL)},
        q{INSERT INTO orders VALUES (1,'DL','H',1,2), (2,'PL','H',1,2), (3,'TR','H',2,1),
            (4,'OP','H',1,2), (5,'CX','H',1,2), (6,'DL','N',1,2), (7,'PL',NULL,1,2),
            (8,NULL,'H',1,2), (9,'DL','H',1,NULL), (10,'PL','H',NULL,2), (11,'PL','H',3,1)};
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
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {orders => {
            path => '/orders', title => 'Orders', default_fields => [qw(id current_party.party_name)],
            engine_factory => sub { $engine },
            measures => [{id => 'orders', label => 'Orders', aggregate => 'count'}],
        }}});
        my $t = Test::Mojo->new($app);
        my $get = sub {
            my (%input) = @_;
            $t->get_ok('/orders' => form => \%input)->status_is(200)
                or diag $t->tx->res->dom->find('.sc-error, [role=alert]')->map('all_text')->join('; ');
            return $t->tx->res->dom;
        };
        my $ids = sub {
            return [sort { $a <=> $b } map { 0 + text($_) }
                @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}];
        };
        my %summary = (q => 1, view => 'aggregate', field => 'id', group => 'current_party_id',
            measure => 'orders', limit => 25, page => 1);
        my $dom = $get->(%summary);
        my @rows = @{$dom->find('.sc-results tbody tr')};
        is scalar(@rows), 5, 'four key groups and the total';
        like $dom->all_text, qr/Current Party/, 'dimension name is displayed';
        is scalar(grep { text($_) =~ /Alpha/ } @rows), 2, 'equal display names keep separate stable-key groups';
        my ($beta) = grep { text($_) =~ /Beta/ } @rows;
        ok $beta, 'destination-based dimension displays its party name';
        my %drill = hidden($beta->at('form.sc-drilldown-form'));
        is_deeply $drill{filter_field}, ['current_party_id'], 'group drill filters computed key';
        is_deeply $drill{filter_value}, ['2'], 'group drill carries hidden ID, not label';
        $get->(%drill, field => 'id', order => 'id');
        is_deeply $ids->(), [1,3], 'group drill Detail rows match CASE (not origin_party_id)';

        $get->(q => 1, view => 'detail', field => 'id', filter_field => 'current_party_id',
            filter_op => 'eq', filter_value => 2, order => 'id');
        is_deeply $ids->(), [1,3], 'dimension filter matches the same Detail rows';
        $get->(q => 1, view => 'detail', field => 'id', filter_field => 'current_party.city',
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
        $dom = $get->(%summary, group => [qw(hold_code current_party_id)], pivot_column => 'current_party_id');
        ok $dom->at('table.sc-pivot-table'), 'computed dimension is a pivot column';
        like $dom->at('.sc-pivot-table thead')->all_text, qr/Beta/, 'pivot heading displays dimension name';
        my ($button) = grep {
            my $v = from_json($_->attr('value'));
            ref($v) eq 'ARRAY' && @$v == 2 && ($v->[0] // '') eq 'H' && ($v->[1] // '') eq '2'
        } @{$dom->find('.sc-pivot-table button[name="grid_cell"]')};
        ok $button, 'pivot cell retains stable computed ID';
        my %cell_drill = hidden($dom->at('form.sc-pivot-drill-form'));
        $get->(%cell_drill, grid_cell => $button->attr('value'), field => 'id', order => 'id');
        is_deeply $ids->(), [1,3], 'pivot cell drill Detail rows match computed key';

        # A filtered aggregate retains the same dimension and count.
        $dom = $get->(%summary, filter_field => 'current_party_id', filter_op => 'eq', filter_value => 2);
        my @filtered = @{$dom->find('.sc-results tbody tr')};
        is scalar(@filtered), 2, 'filtered dimension group and total only';
        like $dom->all_text, qr/Beta/, 'filtered aggregate keeps its display';
        $dbh->disconnect;
    };
}
done_testing;
