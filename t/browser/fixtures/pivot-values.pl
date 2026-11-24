use 5.034;
use strict;
use warnings;
use Mojolicious;
use DBI;
use Selecto;
use Selecto::Components;
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1});
$dbh->do('CREATE TABLE orders (id integer primary key, region text, state_code text, quoted_amount integer)');
$dbh->do("INSERT INTO orders VALUES (1,'East','PL',10),(2,'East','OP',30),(3,'West','DL',20)");
my $domain=Selecto::Domain->new(name=>'Orders',table=>'orders',fields=>{id=>'integer',region=>'string',state_code=>'string',quoted_amount=>'integer'});
my $adapter=Selecto->adapter(sqlite=>(dbh=>$dbh));
my $app=Mojolicious->new;
$app->secrets(['pivot-browser']);
$app->plugin('Selecto::Components'=>{websocket_mode=>'public',explorers=>{orders=>{path=>'/orders',
    default_fields=>['id'],engine_factory=>sub {Selecto::Engine->new(domain=>$domain,adapter=>$adapter)},
    measures=>[{id=>'quoted_amount',label=>'Quoted Amount',aggregate=>'sum',field=>'quoted_amount'}]}}});
$app->start;
