use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::URL;
use DBI;
use IO::Uncompress::Unzip;
use lib 't/lib';
use OpsMeasuresFixture;
use Selecto::Components;
use Selecto::Components::Config;
use Selecto::Components::Explorer;
use Selecto::Components::State;
use Selecto::Components::QueryBuilder;
use Selecto::Components::NumberFormat;
for my $backend(qw(sqlite postgresql)) {
 my $dbh;
 if($backend eq 'sqlite') {$dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0})}
 else {
  next unless $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
  my $u=Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
  $dbh=DBI->connect('dbi:Pg:dbname='.substr($u->path,1).';host='.$u->host.';port='.$u->port,$u->username,$u->password,{RaiseError=>1,PrintError=>0});
 }
 subtest $backend=>sub {
 my $e=OpsMeasuresFixture::build($dbh,$backend);
 my $settings=OpsMeasuresFixture::settings($e);
 my $config=Selecto::Components::Config->new(id=>'loads',%$settings);
 my $explorer=Selecto::Components::Explorer->new(config=>$config);
 my $app=Mojolicious->new;$app->secrets(['ops-ratio-tests']);$app->log->level('fatal');
 $app->plugin('Selecto::Components'=>{websocket_mode=>'public',explorers=>{loads=>$settings}});
 my $t=Test::Mojo->new($app);
 my %input=(q=>1,view=>'aggregate',field=>'id',group=>[qw(region status)],measure=>'rpu');
 my $controller=$app->build_controller;
 sub model {
  my ($explorer,$controller,$input)=@_;
  my $m=$explorer->model($controller,$input);
  ok !$m->{runtime_error},'query executes' or diag explain $m->{runtime_error};
  ok $m->{state}->valid,'ratio state valid' or diag explain $m->{state}->errors;
  return $m;
 }
 my $m=model($explorer,$controller,\%input);
 my $records=$m->{result}{records};
 my %by=map {join('|',$_->{region}//'',$_->{status}//'')=>$_->{rpu}} @$records;
 cmp_ok abs($by{'East|'}-500/12),'<',1e-10,'rollup East ratio of sums';
 cmp_ok abs($by{'|'}-700/14),'<',1e-10,'grand total ratio of sums';
 is 0+$by{'East|A'},20,'unequal size loads give 200 / 10, not average of per-row ratios';
 ok !defined $by{'West|B'},'zero denominator returns NULL';
 my $pivot=model($explorer,$controller,{%input,pivot_column=>'status'});
 my $grid=model($explorer,$controller,{%input,aggregate_grid=>1});
 my $east_record=(grep {($_->{region}//'') eq 'East'} @{$pivot->{result}{records}})[0];
 cmp_ok abs($east_record->{rpu}-500/12),'<',1e-10,'pivot Total column uses ratio of sums';
 my $cells=$pivot->{result}{pivot_data}{cells_for}->($east_record);
 my @cell_values=map {$_->{rpu}} values %$cells;
 ok scalar(grep {defined($_) && abs($_-20)<1e-10} @cell_values),'pivot A cell uses 200/10';
 cmp_ok abs($grid->{result}{grid_data}{totals}{grand}{value}-50),'<',1e-10,'grid rendered grand total uses sums';
 # Their source records include separately evaluated subtotal measures.
 for my $case([$pivot,'pivot'],[$grid,'grid']) {
  my @total=grep {!defined($_->{region}) && !defined($_->{status})} @{$case->[0]{result}{records}};
  cmp_ok abs($total[0]{rpu}-50),'<',1e-10,"$case->[1] grand total uses sums";
 }
 my $sorted=model($explorer,$controller,{%input,group=>'region',order=>'measure:rpu',direction=>'desc'});
 my @detail=grep {defined $_->{region}} @{$sorted->{result}{records}};
 is $detail[0]{region},'West','ratio ordering works';
 my $top=model($explorer,$controller,{%input,pivot_column=>'status',pivot_column_top=>1,pivot_column_top_measure=>'rpu'});
 is_deeply $top->{state}->group_configs->{status}{pivot_values},['B'],'Top N chooses highest ratio (B=380/2, A=320/12)';
 my $graph=model($explorer,$controller,{%input,view=>'graph',group=>'region'});
 my %graph=map {$_->{region}=>0+$_->{rpu}} @{$graph->{result}{records}};
 cmp_ok abs($graph{East}-500/12),'<',1e-10,'graph values are ratios of sums';
 $t->get_ok('/loads'=>form=>\%input)->status_is(200)
  ->element_exists('[data-sc-picker-set-item][data-field="rpu"] input[name="measure_function"][value="ratio_of_sums"]')
  ->element_exists_not('[data-sc-picker-set-item][data-field="rpu"] select[name="measure_function"]');
 like $t->tx->res->body,qr/41\.67/,'currency ratio displays two decimals';
 my $csv=$explorer->csv($m);
 like $csv,qr/41\.6666/,'CSV exports raw ratio';
 my $xlsx=$explorer->xlsx($m);
 my $z=IO::Uncompress::Unzip->new(\$xlsx);my %parts;
 do {my $part='';while($z->read(my $chunk)>0){$part.=$chunk}$parts{$z->getHeaderInfo->{Name}}=$part} while($z->nextStream>0);
 like $parts{'xl/worksheets/sheet1.xml'},qr/41\.6666/,'XLSX exports raw ratio';
 like $parts{'xl/styles.xml'},qr/0\.00/,'XLSX currency number format';
 my $derived=$config->measure('derived_rpu',$e->domain);
 is $derived->{unit}{denominator}{kind},'count','derived per-unit metadata retained';
 };
 $dbh->disconnect;
}
done_testing;
