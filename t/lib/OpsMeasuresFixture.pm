package OpsMeasuresFixture;
use 5.034;
use strict;
use warnings;
use Selecto::Domain;
use Selecto::Engine;
use Selecto;
sub build {
 my ($dbh,$backend)=@_;
 $dbh->do('CREATE TEMP TABLE ops_loads(id INTEGER,region TEXT,status TEXT,revenue INTEGER,units INTEGER)');
 $dbh->do(q{INSERT INTO ops_loads VALUES(1,'East','A',100,1),(2,'East','A',100,9),(3,'East','B',300,2),(4,'West','A',120,2),(5,'West','B',80,0)});
 my $d=Selecto::Domain->parse({schema_version=>1,name=>'Synthetic loads',source=>{source_table=>'ops_loads',primary_key=>'id',fields=>[qw(id region status revenue units)],columns=>{id=>{type=>'integer'},region=>{type=>'string'},status=>{type=>'string'},revenue=>{type=>'integer',unit=>{kind=>'currency',code=>'USD'}},units=>{type=>'integer',unit=>{kind=>'count'}}},associations=>{}},schemas=>{},joins=>{},ratio_measures=>{
 rpu=>{label=>'Revenue per unit',numerator=>{field=>'revenue',function=>'sum'},denominator=>{field=>'units',function=>'sum'},unit=>{kind=>'currency',code=>'USD'}},
 derived_rpu=>{label=>'Derived revenue per unit',numerator=>{field=>'revenue',function=>'sum'},denominator=>{field=>'units',function=>'sum'}},
 }},strict=>1);
 return Selecto::Engine->new(domain=>$d,adapter=>Selecto->adapter($backend=>(dbh=>$dbh,temporary_relations=>1)));
}
sub settings {
 my ($e)=@_;
 return {path=>'/loads',title=>'Loads',default_fields=>['id'],default_group=>['region'],engine_factory=>sub{$e},measures=>[{id=>'revenue',field=>'revenue',aggregate=>'sum',label=>'Revenue'}]};
}
1;
