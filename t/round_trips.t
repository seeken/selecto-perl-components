use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use Mojolicious;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::RoundTrips ();

# Query Debug's round trips, counted from libpq's protocol trace: these lines
# are what DBD::Pg 3.18 (libpq 17) writes for a do, two executes of one
# placeholder statement (the second prepares it first) and a rollback, with
# AutoCommit off (so the driver begins first).
my @begin = (
    qq{2026-11-13 16:32:41.974719\tF\t10\tQuery\t "begin"},
    qq{2026-11-13 16:32:41.975216\tB\t10\tCommandComplete\t "BEGIN"},
    qq{2026-11-13 16:32:41.975223\tB\t5\tReadyForQuery\t T},
);
my @select = (
    qq{2026-11-13 16:32:41.975228\tF\t13\tQuery\t "SELECT 1"},
    qq{2026-11-13 16:32:41.975534\tB\t33\tRowDescription\t 1 "?column?" 0 0 23 4 -1 0},
    qq{2026-11-13 16:32:41.975555\tB\t11\tDataRow\t 1 1 '1'},
    qq{2026-11-13 16:32:41.975560\tB\t13\tCommandComplete\t "SELECT 1"},
    qq{2026-11-13 16:32:41.975563\tB\t5\tReadyForQuery\t T},
);
my @first_execute = (
    qq{2026-11-13 16:32:41.975600\tF\t30\tParse\t "" "SELECT \$1::int + 1" 1 0},
    qq{2026-11-13 16:32:41.975604\tF\t19\tBind\t "" "" 0 1 1 '1' 1 0},
    qq{2026-11-13 16:32:41.975608\tF\t6\tDescribe\t P ""},
    qq{2026-11-13 16:32:41.975612\tF\t9\tExecute\t "" 0},
    qq{2026-11-13 16:32:41.975615\tF\t4\tSync},
    qq{2026-11-13 16:32:41.976064\tB\t4\tParseComplete},
    qq{2026-11-13 16:32:41.976070\tB\t4\tBindComplete},
    qq{2026-11-13 16:32:41.976078\tB\t11\tDataRow\t 1 1 '2'},
    qq{2026-11-13 16:32:41.976085\tB\t5\tReadyForQuery\t T},
);
my @second_execute = (
    qq{2026-11-13 16:32:41.976099\tF\t40\tParse\t "dbdpg_p12457_1" "SELECT \$1::int + 1" 0},
    qq{2026-11-13 16:32:41.976102\tF\t4\tSync},
    qq{2026-11-13 16:32:41.976323\tB\t4\tParseComplete},
    qq{2026-11-13 16:32:41.976329\tB\t5\tReadyForQuery\t T},
    qq{2026-11-13 16:32:41.976333\tF\t33\tBind\t "" "dbdpg_p12457_1" 0 1 1 '2' 1 0},
    qq{2026-11-13 16:32:41.976340\tF\t9\tExecute\t "" 0},
    qq{2026-11-13 16:32:41.976343\tF\t4\tSync},
    qq{2026-11-13 16:32:41.976534\tB\t4\tBindComplete},
    qq{2026-11-13 16:32:41.976551\tB\t5\tReadyForQuery\t T},
);
my @rollback = (
    qq{2026-11-13 16:32:41.976741\tF\t13\tQuery\t "rollback"},
    qq{2026-11-13 16:32:41.976909\tB\t13\tCommandComplete\t "ROLLBACK"},
    qq{2026-11-13 16:32:41.976915\tB\t5\tReadyForQuery\t I},
);

# A DBD::Pg handle as far as the tracer sees it: libpq writes to the handle
# it is given and flushes when tracing stops.
{
    package TestRoundTrips::DBH;
    sub new { bless {Driver => {Name => 'Pg'}, traces => 0}, shift }
    sub pg_server_trace { my ($self, $fh) = @_; $self->{traces}++; $self->{fh} = $fh; 1 }
    sub pg_server_untrace { my ($self) = @_; $self->{fh}->flush if $self->{fh}; delete $self->{fh}; 1 }
    sub send { my ($self, @lines) = @_; my $fh = $self->{fh} or return; print {$fh} map { "$_\n" } @lines }
    package TestRoundTrips::Adapter;
    use parent -norequire, 'TestSelectoComponents::Adapter';
    our $DBH;
    sub dbh { $DBH }
    sub execute_query {
        my ($self, $statement) = @_;
        my $count = @{$statement->columns} == 1 && $statement->columns->[0] eq 'selecto_total_count';
        $DBH->send(@begin, @select) unless $count;
        $DBH->send(@first_execute) if $count;
        return $self->SUPER::execute_query($statement);
    }
}

subtest 'counting a trace' => sub {
    my $dbh = TestRoundTrips::DBH->new;
    my $trips = Selecto::Components::RoundTrips->start(bless({}, 'TestRoundTrips::AdapterOf')->with($dbh));
    ok $trips, 'a DBD::Pg handle is traced';
    $dbh->send(@begin);
    is $trips->during(data => sub { $dbh->send(@select, @first_execute); 'rows' }), 'rows', 'during returns the work\'s result';
    $trips->during(count => sub { $dbh->send(@second_execute) });
    $dbh->send(@rollback);
    my $summary = $trips->finish;
    is $summary->{total}, 6, 'one round trip per ReadyForQuery, the driver\'s begin and prepare included';
    is_deeply $summary->{phases}, {other => 2, data => 2, count => 2}, 'credited to the phase they ran in';
    is_deeply [map { $_->{command} } @{$summary->{trips}}],
        ['begin', 'SELECT 1', 'SELECT $1::int + 1', 'SELECT $1::int + 1', 'Prepared statement dbdpg_p12457_1', 'rollback'],
        'each with what it sent';
    is $summary->{trips}[0]{ms}, 0.5, 'and how long it waited';
    my $sent = 0;
    my $received = 0;
    for (@begin, @select, @first_execute, @second_execute, @rollback) {
        my (undef, $direction, $length) = split /\t/;
        $direction eq 'F' ? ($sent += $length + 1) : ($received += $length + 1);
    }
    is $summary->{sent_bytes}, $sent, 'bytes sent';
    is $summary->{received_bytes}, $received, 'and received';
    ok !$dbh->{fh}, 'tracing has stopped';
};

subtest 'limits and failures' => sub {
    my $dbh = TestRoundTrips::DBH->new;
    my $trips = Selecto::Components::RoundTrips->start(bless({}, 'TestRoundTrips::AdapterOf')->with($dbh));
    my $long = 'SELECT ' . ('x, ' x 100) . "\x{e9}";
    $dbh->send((map { (qq{2026-11-13 23:59:59.999000\tF\t9\tQuery\t "$long"},
        qq{2026-11-14 00:00:00.000500\tB\t5\tReadyForQuery\t I}) } 1 .. 60));
    ok !eval { $trips->during(data => sub { $dbh->send(@select); die "boom\n" }); 1 }, 'a failure is rethrown';
    is $@, "boom\n", 'as it was';
    ok $dbh->{fh}, 'and tracing goes on';
    my $summary = $trips->finish;
    is $summary->{total}, 61, 'every round trip is counted';
    is $summary->{phases}{data}, 1, 'the failed work\'s too';
    is scalar(@{$summary->{trips}}), 50, 'the first 50 are listed';
    is length($summary->{trips}[0]{command}), 160, 'a command is cut to 160 characters';
    like $summary->{trips}[0]{command}, qr/…\z/, 'marked as cut';
    is $summary->{trips}[0]{ms}, 1.5, 'a round trip over midnight';

    my $abandoned = TestRoundTrips::DBH->new;
    {
        my $dropped = Selecto::Components::RoundTrips->start(bless({}, 'TestRoundTrips::AdapterOf')->with($abandoned));
        ok $abandoned->{fh}, 'traced';
    }
    ok !$abandoned->{fh}, 'an abandoned tracer stops tracing';

    ok !Selecto::Components::RoundTrips->start(bless({}, 'TestRoundTrips::AdapterOf')->with(bless {Driver => {Name => 'SQLite'}}, 'TestRoundTrips::Other')),
        'other drivers have no trace';
    ok !Selecto::Components::RoundTrips->start(bless({}, 'TestRoundTrips::AdapterOf')), 'nor adapters without a handle';
    ok !Selecto::Components::RoundTrips->start(undef), 'nor no adapter';
};

{
    package TestRoundTrips::AdapterOf;
    sub with { my ($self, $dbh) = @_; $self->{dbh} = $dbh; $self }
    sub dbh { $_[0]{dbh} }
}

subtest 'the Query Debug panel' => sub {
    local $TestRoundTrips::Adapter::DBH = TestRoundTrips::DBH->new;
    local $TestSelectoComponents::Adapter::PAGE_ROWS = 'full';   # (more than a page: counted)
    my $app = Mojolicious->new;
    $app->secrets(['test-only-secret']);
    my $config = TestSelectoComponents::config();
    $config->{engine_factory} = sub {
        Selecto::Engine->new(domain => TestSelectoComponents::domain(),
            adapter => TestRoundTrips::Adapter->new(dbh => bless({}, 'TestSelectoComponents::DBH')));
    };
    $app->plugin('Selecto::Components' => {explorers => {products => $config}});
    my $t = Test::Mojo->new($app);
    $t->get_ok('/explore/products?q=1&view=detail&field=product_name&limit=25&page=1')->status_is(200)
        ->text_is('.sc-debug-stat:nth-child(12) span' => 'Database round trips')
        ->text_is('.sc-debug-stat:nth-child(12) strong' => '3')
        ->text_like('[data-sc-debug-round-trips]' => qr/\ARound trips: data 2, count 1, other 0 · waiting \d/)
        ->text_like('[data-sc-debug-round-trips]' => qr/sent 98 bytes · received \d+ bytes\z/)
        ->text_is('.sc-debug-trips > summary' => '3 round trips')
        ->text_is('.sc-debug-trips li:nth-child(1) .sc-debug-trip-phase' => 'data')
        ->text_is('.sc-debug-trips li:nth-child(2) code' => 'SELECT 1')
        ->text_is('.sc-debug-trips li:nth-child(3) .sc-debug-trip-phase' => 'count')
        ->text_like('.sc-debug-trips li:nth-child(3) .sc-debug-trip-ms' => qr{\A0\.4[89] ms\z});
    ok !$TestRoundTrips::Adapter::DBH->{fh}, 'tracing stops with the model';

    $config->{show_sql} = 0;
    $app = Mojolicious->new;
    $app->secrets(['test-only-secret']);
    $app->plugin('Selecto::Components' => {explorers => {products => $config}});
    $TestRoundTrips::Adapter::DBH->{traces} = 0;
    Test::Mojo->new($app)->get_ok('/explore/products?q=1&view=detail&field=product_name&limit=25&page=1')
        ->status_is(200)->element_exists_not('.sc-debug-panel');
    is $TestRoundTrips::Adapter::DBH->{traces}, 0, 'without show_sql nothing is traced';
};

done_testing;
