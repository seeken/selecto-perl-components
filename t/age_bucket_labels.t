use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::JSON qw(from_json);
use Mojolicious;
use Selecto;
use Selecto::Components;

# Age buckets count days back from today, so their labels say "days ago".
# The bucket value that drilldowns and grid selections carry stays the bare
# range, so links and saved views keep matching.
plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE orders (id integer primary key, origin text, received_on date, quoted_amount integer)');
$dbh->do(q{INSERT INTO orders VALUES
    (1, 'MI', date('now'), 10), (2, 'MI', date('now', '-1 day'), 20),
    (3, 'OH', date('now', '-12 days'), 30), (4, 'OH', date('now', '-400 days'), 40)});
my $domain = Selecto::Domain->new(name => 'Orders', table => 'orders',
    fields => {id => 'integer', origin => 'string', received_on => 'date', quoted_amount => 'integer'});
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
my $app = Mojolicious->new;
$app->secrets(['age-bucket-labels-test']);
$app->log->level('fatal');
$app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {orders => {
    path => '/orders', title => 'Orders', default_fields => [qw(id origin received_on)],
    engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
    measures => [{id => 'quoted_amount', label => 'Amount', aggregate => 'sum', field => 'quoted_amount'}],
}}});
my $t = Test::Mojo->new($app);

sub text_of { my $text = $_[0]->all_text; $text =~ s/\s+/ /g; $text =~ s/\A | \z//g; return $text }
my @form = (q => 1, view => 'aggregate', field => 'id', group => [qw(origin received_on)],
    group_alias => ['', ''], group_format => ['', 'age_buckets'], group_bucket_ranges => ['', '0, 1, 2-30, 31+'],
    measure => ['quoted_amount'], limit => 25, page => 1);

$t->get_ok('/orders' => form => {@form, pivot_column => 'received_on'})->status_is(200);
my $dom = $t->tx->res->dom;
is_deeply [map { text_of($_) } @{$dom->find('.sc-pivot-table thead tr:nth-child(2) > th')}],
    ['today', '1 day ago', '2-30 days ago', '31+ days ago'], 'pivot column headings say how many days ago';
my @drills = map { from_json($_->attr('value')) } @{$dom->find('.sc-pivot-table thead tr:nth-child(2) button')};
is_deeply [map { $_->{value} } @drills], ['0', '1', '2-30', '31+'], 'their drilldowns carry the bare ranges';
like $dom->at('.sc-pivot-table thead tr:nth-child(2) button')->attr('aria-label'), qr/Received On today\z/i,
    'and read the same to assistive technology';

$t->get_ok('/orders' => form => {@form, aggregate_grid => 1})->status_is(200);
$dom = $t->tx->res->dom;
my @grid = map { text_of($_) } @{$dom->find('.sc-aggregate-grid thead th:not(.sc-grid-corner) span')};
is_deeply [grep { /day|today/ } @grid], ['today', '1 day ago', '2-30 days ago', '31+ days ago'],
    'grid column headings say so too';

# "-N" after a range continues it: "0, -1, -30, 31+" is "0, 1, 2-30, 31+",
# and its drilldowns find the same rows.
$t->get_ok('/orders' => form => {@form, group_bucket_ranges => ['', '0, -1, -30, 31+'], pivot_column => 'received_on'})
    ->status_is(200);
$dom = $t->tx->res->dom;
is_deeply [map { text_of($_) } @{$dom->find('.sc-pivot-table thead tr:nth-child(2) > th')}],
    ['today', '1 day ago', '2-30 days ago', '31+ days ago'], 'the shorthand reads as the full ranges';
my ($shorthand_drill) = grep { from_json($_->attr('value'))->{value} eq '2-30' }
    @{$dom->find('.sc-pivot-table thead tr:nth-child(2) button')};
ok $shorthand_drill, 'and drills by the inferred range';
my %drill_pairs;
my $drill_form = $dom->at('form#' . ($shorthand_drill->attr('form') // ''));
push @{$drill_pairs{$_->attr('name')}}, $_->attr('value') for @{$drill_form->find('input[type="hidden"]')};
push @{$drill_pairs{$shorthand_drill->attr('name')}}, $shorthand_drill->attr('value');
$t->get_ok('/orders' => form => \%drill_pairs)->status_is(200)->element_exists_not('.sc-alert');
is_deeply [map { text_of($_) } @{$t->tx->res->dom->find('.sc-results table tbody tr td:first-child')}], ['3'],
    'which finds the order received_on 12 days ago';

# A drilldown from a 250-row summary opens Detail at Detail's own page size.
$t->get_ok('/orders' => form => {@form, limit => 250})->status_is(200);
$dom = $t->tx->res->dom;
my $drill = $dom->at('form.sc-drilldown-form');
ok $drill, 'the summary has drilldowns';
ok !$drill->at('input[name="limit"]'), 'which leave the page size to Detail';
my %pairs;
push @{$pairs{$_->attr('name')}}, $_->attr('value') for @{$drill->find('input[type="hidden"]')};
$t->get_ok('/orders' => form => \%pairs)->status_is(200)->element_exists_not('.sc-alert');
is $t->tx->res->dom->at('select[name="limit"] option[selected]')->attr('value'), 25, 'Detail opens at 25 rows';

done_testing;
