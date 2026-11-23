use 5.034;
use strict;
use warnings;
use Mojolicious;
use DBI;
use Selecto;
use Selecto::Components;
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1});
$dbh->do('CREATE TABLE loads (id integer primary key, region text, status text, revenue integer)');
$dbh->do("INSERT INTO loads VALUES (1,'East','P',10),(2,'East','G',30),(3,'West','D',20)");
my $domain=Selecto::Domain->new(name=>'Loads',table=>'loads',fields=>{id=>'integer',region=>'string',status=>'string',revenue=>'integer'});
my $adapter=Selecto->adapter(sqlite=>(dbh=>$dbh));
my $app=Mojolicious->new;
$app->secrets(['pivot-browser']);
$app->plugin('Selecto::Components'=>{websocket_mode=>'public',explorers=>{loads=>{path=>'/loads',
    default_fields=>['id'],engine_factory=>sub {Selecto::Engine->new(domain=>$domain,adapter=>$adapter)},
    measures=>[{id=>'revenue',label=>'Revenue',aggregate=>'sum',field=>'revenue'}]}}});
$app->start;
