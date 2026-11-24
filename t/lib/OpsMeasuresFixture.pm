package OpsMeasuresFixture;
use 5.034;
use strict;
use warnings;
use Selecto::Domain;
use Selecto::Engine;
use Selecto;
sub build {
 my ($dbh,$backend)=@_;
 $dbh->do('CREATE TEMP TABLE orders(id INTEGER,region TEXT,state_code TEXT,quoted_amount INTEGER,piece_count INTEGER)');
 $dbh->do(q{INSERT INTO orders VALUES(1,'East','OP',100,1),(2,'East','OP',100,9),(3,'East','PL',300,2),(4,'West','OP',120,2),(5,'West','PL',80,0)});
 my $d=Selecto::Domain->parse({schema_version=>1,name=>'Orders',source=>{source_table=>'orders',primary_key=>'id',fields=>[qw(id region state_code quoted_amount piece_count)],columns=>{id=>{type=>'integer'},region=>{type=>'string'},state_code=>{type=>'string'},quoted_amount=>{type=>'integer',unit=>{kind=>'currency',code=>'USD'}},piece_count=>{type=>'integer',unit=>{kind=>'count'}}},associations=>{}},schemas=>{},joins=>{},ratio_measures=>{
 amount_per_piece=>{label=>'Quoted amount per piece',numerator=>{field=>'quoted_amount',function=>'sum'},denominator=>{field=>'piece_count',function=>'sum'},unit=>{kind=>'currency',code=>'USD'}},
 derived_amount_per_piece=>{label=>'Derived quoted amount per piece',numerator=>{field=>'quoted_amount',function=>'sum'},denominator=>{field=>'piece_count',function=>'sum'}},
 }},strict=>1);
 return Selecto::Engine->new(domain=>$d,adapter=>Selecto->adapter($backend=>(dbh=>$dbh,temporary_relations=>1)));
}
sub settings {
 my ($e)=@_;
 return {path=>'/orders',title=>'Orders',default_fields=>['id'],default_group=>['region'],engine_factory=>sub{$e},measures=>[{id=>'quoted_amount',field=>'quoted_amount',aggregate=>'sum',label=>'Quoted amount'}]};
}
1;
