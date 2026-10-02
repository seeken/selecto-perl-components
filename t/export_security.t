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
done_testing;
