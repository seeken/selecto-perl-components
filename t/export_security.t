use 5.034;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::ExportBudget;
use Selecto::Components::Explorer;
use Selecto::Components::Config;
use Selecto::Components::InputBudget;
use Selecto::Limits;
use Selecto::Query;
use Selecto::Expression;

my $dir = tempdir(CLEANUP => 1);
sub config { Selecto::Components::Config->new(%{TestSelectoComponents::config()}, id=>'products', title=>'Products', export_lock_dir=>$dir, @_) }
my $config = config(max_export_rows=>2, max_export_bytes=>10, max_concurrent_exports=>1);
my $engine = $config->engine(undef);
my $budget = Selecto::Components::ExportBudget->new($config, $engine, undef);
$budget->row(['one']); $budget->row(['two']);
ok !eval { $budget->row(['three']); 1 }, 'over-limit row refused before formatting';
$budget->output('12345'); $budget->output('67890');
ok !eval { $budget->output('x'); 1 }, 'output byte ceiling is cumulative';
ok !eval { Selecto::Components::ExportBudget->new($config,$engine,undef); 1 }, 'active lease blocks another export';
$budget->{started} -= 31;
ok !eval { $budget->check; 1 }, 'deadline refuses further reads';
$budget->close;
$budget->close;
ok eval { my $next = Selecto::Components::ExportBudget->new($config,$engine,undef); $next->close; 1 }, 'lease released after close, idempotently';
{
    no warnings 'redefine';
    local *TestSelectoComponents::Adapter::bounded_stream_supported = sub { 0 };
    ok !eval { Selecto::Components::ExportBudget->new($config,$engine,undef); 1 }, 'buffering-only drivers cannot export';
}
ok eval { my $next = Selecto::Components::ExportBudget->new($config,$engine,undef); $next->close; 1 }, 'failed capability check releases lease';

my $limits = Selecto::Limits->new(max_generated_parameters=>3);
my $query = Selecto::Query->new->select('id')->where(Selecto::Expression->in('id',1,2,3,4));
ok !eval { Selecto::Components::InputBudget->query($limits,$query); 1 }, 'final query counts raw IN values as generated parameters';
my $same = Selecto::Expression->literal(1);
$query = Selecto::Query->new->select($same,$same,$same,$same);
ok !eval { Selecto::Components::InputBudget->query($limits,$query); 1 }, 'reused expression objects count each generated occurrence';

my $controller = TestSelectoComponents::Controller->new(params=>{q=>1,field=>'product_name'});
my $explorer = Selecto::Components::Explorer->new(config=>config(max_export_bytes=>1_000_000,max_export_temp_bytes=>100));
ok !eval { $explorer->xlsx_file_export($controller); 1 }, 'XLSX reserves its spool before writing headers';
like $@, qr/temporary disk limit/, 'XLSX spool rejection is explicit';
ok !eval { $explorer->model($controller,undef,{all_rows=>1}); 1 }, 'materializing all_rows fallback is unavailable';

# Real SQLite result iteration and query-budget cleanup, not an adapter mock.
SKIP: {
    skip 'DBD::SQLite unavailable', 3 unless eval { require DBI; require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $dbh->do('CREATE TABLE export_rows (id integer primary key, label text)');
    $dbh->do('INSERT INTO export_rows VALUES (?,?)',undef,$_,'row'.$_) for 1..10;
    my $domain = Selecto::Domain->new(name=>'Rows',table=>'export_rows',fields=>{id=>'integer',label=>'string'});
    my $adapter = Selecto->adapter(sqlite=>(dbh=>$dbh));
    my $real = Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
    my $cfg = Selecto::Components::Config->new(id=>'rows',title=>'Rows',path=>'/rows',max_export_rows=>3,
        export_lock_dir=>$dir,engine_factory=>sub{$real});
    my $view = Selecto::Components::Explorer->new(config=>$cfg);
    my $request = TestSelectoComponents::Controller->new(params=>{q=>1,field=>'label',order=>'id'});
    my $export = $view->stream_export($request,'csv');
    my $output = ''; while (defined(my $chunk = $export->{next_chunk}->())) { $output .= $chunk }
    $export->{close}->();
    like $output, qr/row3/, 'real SQLite export reads allowed rows';
    unlike $output, qr/row4/, 'real SQLite query receives hard row cap';
    ok eval { my $guard=$adapter->begin_query_budget(timeout_ms=>1000); $guard->close; 1 }, 'database timeout ownership released after export';
}

# Real PostgreSQL server cursor: exports fetch EXPORT_FETCH_ROWS rows per round
# trip, and the row cap and byte budget still apply row by row across batches.
SKIP: {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    skip 'SELECTO_PERL_TEST_POSTGRES_URL not set', 7
        unless $url && eval { require DBI; require DBD::Pg; require Mojo::URL; 1 };
    my $parsed = Mojo::URL->new($url);
    my $dbh = DBI->connect('dbi:Pg:dbname=' . substr($parsed->path, 1) . ';host=' . ($parsed->host // 'localhost')
        . ';port=' . ($parsed->port // 5432), $parsed->username, $parsed->password,
        {RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $dbh->do('DROP TABLE IF EXISTS selecto_components_export_rows');
    $dbh->do('CREATE TABLE selecto_components_export_rows (id integer primary key, label text, amount numeric(10,2))');
    $dbh->do(q{INSERT INTO selecto_components_export_rows SELECT n, 'row' || n, n / 4.0 FROM generate_series(1,250) n});
    my $domain = Selecto::Domain->new(name=>'PgRows',table=>'selecto_components_export_rows',
        fields=>{id=>'integer',label=>'string',amount=>'decimal'});
    my $adapter = Selecto->adapter(postgresql=>(dbh=>$dbh));
    my $real = Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
    my $export_csv = sub {
        my (%limits) = @_;
        my $cfg = Selecto::Components::Config->new(id=>'pgrows',title=>'Rows',path=>'/pgrows',
            export_lock_dir=>$dir,engine_factory=>sub{$real},%limits);
        my $view = Selecto::Components::Explorer->new(config=>$cfg);
        my $request = TestSelectoComponents::Controller->new(params=>{q=>1,field=>['id','label','amount'],order=>'id'});
        my $export = $view->stream_export($request,'csv');
        my $output = '';
        my $ok = eval { while (defined(my $chunk = $export->{next_chunk}->())) { $output .= $chunk } 1 };
        my $error = $@;
        eval { $export->{close}->() };
        return ($ok, $output, $error);
    };
    my ($ok, $output) = $export_csv->(max_export_rows=>1000, max_export_bytes=>1_000_000);
    my @lines = grep { length } split /\r\n/, $output;
    ok $ok, 'PostgreSQL export completes across several fetch batches';
    is scalar(@lines), 251, 'header plus every row';
    is_deeply [map { (split /,/, $_)[0] } @lines[1..250]], [map { qq{"$_"} } 1..250], 'rows arrive in order across batch boundaries';
    is $lines[10], '"10","row10","2.5"', 'decimal cells are decoded as before';
    ($ok, $output) = $export_csv->(max_export_rows=>150, max_export_bytes=>1_000_000);
    is scalar(grep { length } split /\r\n/, $output), 151, 'row cap applies inside a batch';
    my $error;
    ($ok, $output, $error) = $export_csv->(max_export_rows=>1000, max_export_bytes=>600);
    ok !$ok, 'byte budget still stops an export partway through a batch';
    ok $dbh->{AutoCommit}, 'cursor transaction released after an export';
    $dbh->do('DROP TABLE selecto_components_export_rows');
}
done_testing;
