use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Encode qw(encode);
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::Util qw(decode_driver_json);

# Nested to-many columns arrive as JSON text from the driver: characters from
# DBD::Pg on a UTF-8 database or DBD::SQLite with sqlite_unicode, UTF-8 bytes
# otherwise. Either way the nested table must show the value.
my $note = "Café \x{2615}";
my $json = qq([{"body":"$note"}]);
is_deeply(decode_driver_json($json), [{body => $note}], 'character JSON text decodes');
is_deeply(decode_driver_json(encode('UTF-8', $json)), [{body => $note}],
    'UTF-8 byte JSON text decodes');
is_deeply(decode_driver_json('[{"body":"plain"}]'), [{body => 'plain'}],
    'ASCII JSON text decodes');

sub relation {
    my ($table, $columns, %extra) = @_;
    return {
        source_table => $table, primary_key => 'id',
        fields => [sort keys %$columns],
        columns => {map { ($_ => {type => $columns->{$_}}) } keys %$columns},
        associations => {}, %extra,
    };
}

sub domain {
    return Selecto::Domain->parse({
        schema_version => 1, name => 'Customers',
        source => relation('nu_customers', {id => 'integer', name => 'string'},
            associations => {notes => {queryable => 'note', owner_key => 'id',
                related_key => 'customer_id'}}),
        schemas => {note => relation('nu_notes',
            {id => 'integer', customer_id => 'integer', body => 'string'})},
        joins => {},
    });
}

sub populate {
    my ($dbh, $temp, $stored) = @_;
    $dbh->do("CREATE $temp TABLE nu_customers (id integer primary key, name text)");
    $dbh->do("CREATE $temp TABLE nu_notes (id integer primary key, customer_id integer, body text)");
    $dbh->do(q{INSERT INTO nu_customers VALUES (1, 'Ann'), (2, 'Bob')});
    $dbh->do('INSERT INTO nu_notes VALUES (?, ?, ?)', undef, @$_)
        for [10, 1, $stored // $note], [11, 2, 'plain'];
}

sub check_nested {
    my ($label, $dbh, $adapter_name) = @_;
    my $domain = domain();
    my $engine_factory = sub {
        Selecto::Engine->new(domain => $domain,
            adapter => Selecto->adapter($adapter_name => (dbh => $dbh)));
    };
    my $engine = $engine_factory->();
    my $app = Mojolicious->new;
    $app->secrets(['nested-unicode-test']);
    $app->plugin('Selecto::Components' => {
        explorers => {customers => {path => '/customers', title => 'Customers',
            engine_factory => $engine_factory,
            default_fields => [qw(id name notes.body)]}},
        pages => {customer_notes => {
            domain => $domain, engine_factory => $engine_factory,
            path => '/customer-notes', title => 'Customer notes',
            dataset => {query => $engine->query, entity_key => ['id']},
            views => [{id => 'list', kind => 'detail', label => 'Customers',
                query => $engine->query->select('id', 'name',
                    Selecto::Expression->related_collection('notes', ['body'])->as('notes'))
                    ->order_by('id')}],
            controls => [],
            initial_state => {view => 'list'},
        }},
    });
    my $t = Test::Mojo->new($app);
    $t->get_ok('/customers' => form => {q => 1, view => 'detail',
        field => [qw(id name notes.body)], order => 'id', direction => 'asc'})
        ->status_is(200);
    my $explorer_cells = $t->tx->res->dom->find('.sc-nested-table td')->map('text')->to_array;
    ok((grep { $_ eq $note } @$explorer_cells), "$label: Explorer nested table shows $note")
        or diag explain $explorer_cells;
    ok((grep { $_ eq 'plain' } @$explorer_cells), "$label: Explorer nested table shows ASCII rows");

    $t->get_ok('/customer-notes')->status_is(200);
    my $page_cells = $t->tx->res->dom->find('.sc-nested-table td')->map('text')->to_array;
    ok((grep { $_ eq $note } @$page_cells), "$label: canned page nested table shows $note")
        or diag explain $page_cells;
}

SKIP: {
    skip 'DBD::SQLite is not installed', 1 unless eval { require DBD::SQLite; 1 };
    for my $unicode (1, 0) {
        my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
            RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => $unicode,
        });
        # Without sqlite_unicode, DBD::SQLite binds and returns UTF-8 bytes.
        populate($dbh, '', $unicode ? $note : encode('UTF-8', $note));
        check_nested("SQLite sqlite_unicode=$unicode", $dbh, 'sqlite');
    }
}

subtest 'PostgreSQL' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured'
        unless defined($url) && length $url;
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
    my ($user, $password, $host, $port, $database) = $url =~
        m{\Apostgres(?:ql)?://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/]*)(?::(\d+))?/([^?]+)}
        or plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not a postgres:// URL';
    my $dbh = DBI->connect("dbi:Pg:dbname=$database" . (length($host) ? ";host=$host" : '') .
        (defined($port) ? ";port=$port" : ''), $user, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    # Temporary tables live on this one connection, which every engine shares.
    populate($dbh, 'TEMPORARY');
    check_nested('PostgreSQL', $dbh, 'postgresql');
    $dbh->disconnect;
};

done_testing;
