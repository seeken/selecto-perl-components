use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::URL ();
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::BucketParser;

# Month buckets: ranges of calendar months ago, labelled by month name.
# SQLite runs in memory; PostgreSQL runs when SELECTO_PERL_TEST_POSTGRES_URL is set.
my $parser = 'Selecto::Components::BucketParser';
subtest 'labels' => sub {
    my $now = [2026, 10];   # November 2026
    my $spec = $parser->specification('12-6, 5-3, 2, 1, 0, 13+, -1', 'month_ranges', $now);
    is_deeply [map { $_->{label} } @{$spec->{ranges}}],
        ["Nov 2025 - May 2026", "Jun 2026 - Aug 2026", 'Sep 2026', 'Oct 2026', 'Nov 2026',
            'Oct 2025 and earlier', 'Oct 2026 and later'],
        'oldest month first, a single month by itself, open ends';
    is_deeply [map { [$_->{minimum}, $_->{maximum}] } @{$spec->{ranges}}[0, 5, 6]], [[6, 12], [13, undef], [undef, 1]],
        'boundaries in months ago, either order';
    is_deeply $parser->specification('6-12', 'month_ranges', $now), {kind => 'month_ranges', ranges => [$spec->{ranges}[0]]},
        '6-12 is 12-6';
    is $parser->specification('*/3', 'month_ranges', $now), undef, 'no steps';
    is $parser->specification('soon', 'month_ranges', $now), undef, 'nothing else';
    is $parser->specification('1-3', 'month_ranges', [2026, 0])->{ranges}[0]{label}, "Oct 2025 - Dec 2025",
        'across the turn of a year';
    is $parser->group_kind('month_buckets'), 'month_ranges';
};

my $table = 'selecto_components_month_buckets_' . $$;
my @local = localtime;
my ($year, $month) = ($local[5] + 1900, $local[4]);
my @names = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
sub month_of { my $index = $year * 12 + $month - $_[0]; return ($names[$index % 12] . ' ' . int($index / 12), $index) }
sub day_in { my (undef, $index) = month_of($_[0]); return sprintf '%04d-%02d-15', int($index / 12), $index % 12 + 1 }

my %connect = (
    sqlite => sub {
        return undef unless eval { require DBD::SQLite; 1 };
        return DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
    postgresql => sub {
        my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
        return undef unless defined($url) && length($url) && eval { require DBD::Pg; 1 };
        my $parsed = Mojo::URL->new($url);
        return DBI->connect('dbi:Pg:dbname=' . substr($parsed->path, 1) . ';host=' . ($parsed->host // 'localhost')
            . ';port=' . ($parsed->port // 5432), $parsed->username, $parsed->password,
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
);
my @cleanup;
END { eval { $_->do("DROP TABLE IF EXISTS $table") } for @cleanup }
sub text_of { my $text = $_[0]->all_text; $text =~ s/\s+/ /g; $text =~ s/\A | \z//g; return $text }

my $ran = 0;
for my $backend (qw(sqlite postgresql)) {
    my $dbh = $connect{$backend}->() or next;
    $ran++;
    subtest $backend => sub {
        $dbh->do("CREATE TABLE $table (id integer primary key, origin varchar(4), received_on date, quoted_amount integer)");
        push @cleanup, $dbh if $backend eq 'postgresql';
        # Months ago: 0, 1, 1, 4, 8, 20 (outside every range), and one with no date.
        my @rows = ([1, 'MI', 0, 10], [2, 'MI', 1, 20], [3, 'OH', 1, 30], [4, 'OH', 4, 40], [5, 'MI', 8, 50], [6, 'OH', 20, 60]);
        $dbh->do("INSERT INTO $table VALUES (?, ?, ?, ?)", undef, $_->[0], $_->[1], day_in($_->[2]), $_->[3]) for @rows;
        $dbh->do("INSERT INTO $table VALUES (7, 'MI', NULL, 70)");
        my $domain = Selecto::Domain->new(name => 'Orders', table => $table,
            fields => {id => 'integer', origin => 'string', received_on => 'date', quoted_amount => 'integer'});
        my $adapter = Selecto->adapter($backend => (dbh => $dbh));
        my $app = Mojolicious->new;
        $app->secrets(['month-buckets-test']);
        $app->log->level('fatal');
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {orders => {
            path => '/orders', title => 'Orders', default_fields => [qw(id origin received_on)],
            engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
            measures => [{id => 'quoted_amount', label => 'Amount', aggregate => 'sum', field => 'quoted_amount'},
                {id => 'orders', label => 'Count', aggregate => 'count'}],
        }}});
        my $t = Test::Mojo->new($app);
        my @monthly = (q => 1, view => 'aggregate', field => 'id', group_alias => '', measure => [qw(quoted_amount orders)], limit => 25, page => 1);
        my ($span, $two, $one, $this) = ((join ' - ', (month_of(12))[0], (month_of(3))[0]), (month_of(2))[0], (month_of(1))[0], (month_of(0))[0]);

        $t->get_ok('/orders' => form => {@monthly, group => 'received_on', group_format => 'month_buckets',
            group_bucket_ranges => '12-3, 2, 1, 0'})->status_is(200);
        my $dom = $t->tx->res->dom;
        ok $dom->at('select[name="group_format"] option[value="month_buckets"][selected]'), 'Month buckets is a date group format';
        like $dom->at('[data-sc-picker-set-item][data-field="received_on"] input[name="group_bucket_ranges"]')->attr('placeholder'),
            qr/Months ago/, 'with a months-ago example';
        is_deeply [map { join '|', map { text_of($_) } @{$_->children} } @{$dom->find('.sc-results tbody tr')}],
            ['Total|150|5', "$span|90|2", "$one|50|2", "$this|10|1"],
            'rows in month order, empty months absent from rows, older and undated orders left out';

        $t->get_ok('/orders' => form => {@monthly, group => [qw(origin received_on)], group_alias => ['', ''],
            group_format => ['', 'month_buckets'], group_bucket_ranges => ['', '12-3, 2, 1, 0'], pivot_column => 'received_on'})->status_is(200);
        $dom = $t->tx->res->dom;
        is_deeply [map { text_of($_) } @{$dom->find('.sc-pivot-table thead tr:nth-child(2) > th')}], [$span, $two, $one, $this],
            'pivot columns in month order, the empty month included';
        is_deeply [map { join '|', map { text_of($_) } @{$_->children} } @{$dom->find('.sc-pivot-table tbody tr')}],
            ['Total|90|2|—|—|50|2|10|1|150|5', "MI|50|1|—|—|20|1|10|1|80|3", "OH|40|1|—|—|30|1|—|—|70|2"],
            'cells, with the old and undated orders left out of every total';
        my %drill;
        push @{$drill{$_->attr('name')}}, $_->attr('value') for @{$dom->find('form.sc-pivot-drill-form input[type="hidden"]')};
        $t->get_ok('/orders' => form => {%drill, grid_axis => qq({"axis":1,"value":"$one"})})->status_is(200);
        is_deeply [sort map { text_of($_) } @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}], [2, 3],
            'a month column drills to its orders';

        $t->get_ok('/orders' => form => {@monthly, group => 'received_on', group_format => 'month_buckets',
            group_bucket_ranges => 'lately'})->status_is(422);
    };
}

done_testing;
