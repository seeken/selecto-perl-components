use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI ();
use Mojo::URL ();
use Mojo::JSON qw(from_json to_json);
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::Dashboard;
use IO::Uncompress::Unzip qw(unzip $UnzipError);

my @cleanup;
END { for my $entry (@cleanup) { eval { $entry->[0]->do("DROP TABLE $entry->[1]") } } }
for my $backend (qw(sqlite postgresql)) {
    my $dbh;
    if ($backend eq 'sqlite') {
        next unless eval { require DBD::SQLite; 1 };
        $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError=>1, PrintError=>0});
    } else {
        next unless $ENV{SELECTO_PERL_TEST_POSTGRES_URL} && eval { require DBD::Pg; 1 };
        my $u = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
        $dbh = DBI->connect('dbi:Pg:dbname='.substr($u->path,1).';host='.$u->host.';port='.$u->port,
            $u->username,$u->password,{RaiseError=>1,PrintError=>0});
    }
    subtest $backend => sub {
        my $table = 'pivot_values_'.$$;
        my $clients = 'pivot_clients_'.$$;
        $dbh->do("CREATE TABLE $table (id integer primary key, region varchar(20), status varchar(80), client_id integer, revenue integer)");
        $dbh->do("CREATE TABLE $clients (id integer primary key, name varchar(80))");
        push @cleanup, [$dbh,$table],[$dbh,$clients];
        $dbh->do("INSERT INTO $clients VALUES (1,'Same'),(2,'Same'),(3,'Empty')");
        $dbh->do("INSERT INTO $table VALUES (1,'East','P',1,10),(2,'East','G',2,30),(3,'West','D',1,20),(4,'West','C',2,40),(5,'East',NULL,NULL,50)");
        my $domain = Selecto::Domain->parse({schema_version=>1,name=>'Loads',
            source=>{source_table=>$table,primary_key=>'id',fields=>[qw(id region status client_id revenue)],
                columns=>{id=>{type=>'integer'},region=>{type=>'string'},status=>{type=>'string',value_order=>[qw(P G)]},
                    client_id=>{type=>'integer'},revenue=>{type=>'integer'}},
                associations=>{client=>{queryable=>'clients',owner_key=>'client_id',related_key=>'id'}}},
            schemas=>{clients=>{source_table=>$clients,primary_key=>'id',fields=>[qw(id name)],
                columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}}},
            joins=>{client=>{type=>'star_dimension',name=>'Client',dimension_key=>'client_id',display_field=>'name'}}},strict=>1);
        my $adapter = Selecto->adapter($backend => (dbh=>$dbh));
        my $app=Mojolicious->new;
        $app->secrets(['pivot-values']);$app->log->level('fatal');
        $app->plugin('Selecto::Components'=>{websocket_mode=>'public',explorers=>{
            loads=>{path=>'/loads',default_fields=>[qw(id status client_id)],max_grid_columns=>5,
                engine_factory=>sub { Selecto::Engine->new(domain=>$domain,adapter=>$adapter) },
                measures=>[{id=>'revenue',label=>'Revenue',aggregate=>'sum',field=>'revenue'},{id=>'loads',label=>'Loads',aggregate=>'count'}]}}});
        my $t=Test::Mojo->new($app);
        $t->get_ok('/loads')->status_is(200);
        my $csrf=$t->tx->res->dom->at('[data-sc-column-values-csrf]')->attr('data-sc-column-values-csrf');
        $t->post_ok('/loads/column-values'=>form=>{field=>'status',term=>'P'})->status_is(403);
        my $c=$app->build_controller;
        my $e=$c->selecto_components_explorer('loads');
        my %base=(q=>1,view=>'aggregate',field=>[qw(id status client_id)],group=>[qw(region status)],measure=>[qw(revenue loads)],pivot_column=>'status');
        my $model=sub {my (%more)=@_;my $m=$e->model($c,{%base,%more});ok !$m->{runtime_error}, 'query executes' or diag $m->{runtime_error};ok $m->{state}->valid, 'state validates' or diag join(';',@{$m->{state}->errors});return $m};
        my $heads=sub { [map {$_->{value}} @{$_[0]{result}{pivot_data}{columns}}] };
        my $chosen=$model->(pivot_column_value=>[qw(G P X)]);
        is_deeply $heads->($chosen),[qw(G P X)],'chosen order including empty value';
        my $csv=$e->export($chosen,'csv');$csv =~ s/"//g;
        like $csv,qr/Region,G · Revenue,G · Loads,P · Revenue,P · Loads,X · Revenue,X · Loads,Total · Revenue,Total · Loads/,'CSV layout';
        like $csv,qr/Total,30,1,10,1,,,40,2/, 'Total equals exactly the chosen columns';
        # Look at the complete result's column cells, independent of rollup support.
        my $again=$e->model($c,Selecto::Components::Dashboard->new->input_from_url($e->canonical_url($chosen->{state},$domain)));
        is_deeply $heads->($again),[qw(G P X)],'permalink and saved-view URL preserve values';
        $t->get_ok('/loads'=>form=>{%base,pivot_column_value=>[qw(G P X)]})->status_is(200);
        like $t->tx->res->dom->at('[data-sc-group-filters]')->all_text,qr/chosen column values/,'group filter listed';
        my $form=$t->tx->res->dom->at('.sc-pivot-drill-form');
        my %drill;
        push @{$drill{$_->attr('name')}},$_->attr('value') for @{$form->find('input')};
        $t->get_ok('/loads'=>form=>{%drill,grid_axis=>to_json({axis=>1,value=>'G'})})->status_is(200);
        is_deeply [map {$_->all_text} @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}],[2],'chosen drill opens matching detail';
        my $other=$model->(pivot_column_value=>[qw(G P X)],pivot_column_other=>1);
        is_deeply $heads->($other),[qw(G P X),'Other'],'Other last';
        my $other_csv=$e->export($other,'csv');$other_csv =~ s/"//g;
        like $other_csv,qr/Other · Revenue/,'Other exports';
        like $other_csv,qr/Total,30,1,10,1,,,110,3,150,5/, 'Other includes the rest and missing; Total is unfiltered';
        $t->get_ok('/loads'=>form=>{%base,pivot_column_value=>[qw(G P X)],pivot_column_other=>1})->status_is(200);
        $form=$t->tx->res->dom->at('.sc-pivot-drill-form');%drill=();
        push @{$drill{$_->attr('name')}},$_->attr('value') for @{$form->find('input')};
        $t->get_ok('/loads'=>form=>{%drill,grid_axis=>to_json({axis=>1,value=>'__selecto_pivot_other__'})})->status_is(200);
        is_deeply [sort map {$_->all_text} @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}],[3,4,5],'Other drill includes missing and excludes chosen';
        my $present_other=$model->(pivot_column_value=>[qw(G P X)],pivot_column_other=>1,group_exclude_missing=>'status');
        my $present_csv=$e->export($present_other,'csv');$present_csv =~ s/"//g;
        like $present_csv,qr/Total,30,1,10,1,,,60,2,100,4/, 'Other respects Leave out rows with no value';
        my $dim=$model->(group=>['region','client.name'],pivot_column=>'client.name',pivot_column_value=>[3,2,1]);
        is_deeply $heads->($dim),['Empty','Same','Same'],'empty dimension heading and duplicate names';
        is_deeply [map {$_->{selection_value}} @{$dim->{result}{pivot_data}{columns}}],[3,2,1],'dimension identity is key';
        my $grid=$model->(group=>['region','client.name'],pivot_column=>'client.name',pivot_column_value=>[3,2,1],aggregate_grid=>1);
        is_deeply [map {$_->{value}} @{$grid->{result}{grid_data}{columns}}],['Empty','Same','Same'],'grid keeps duplicate keys and empty heading';
        $t->post_ok('/loads/column-values'=>form=>{csrf_token=>$csrf,field=>'client.name',term=>'Emp'})->status_is(200)->json_is('/choices/0/value',3)->json_is('/choices/0/label','Empty');
        $t->post_ok('/loads/column-values'=>form=>{csrf_token=>$csrf,field=>'status',term=>'P'})->status_is(200)->json_is('/choices/0/value','P');
        my $bad=$e->model($c,{%base,pivot_column_value=>['x'x1001]});ok !$bad->{state}->valid,'value length bounded';
        $bad=$e->model($c,{%base,pivot_column_value=>[1..101]});ok !$bad->{state}->valid,'value count bounded';
        my $injection=$model->(pivot_column_value=>["P' OR 1=1 --",'G']);
        is scalar(@{$injection->{result}{records}}),2,'chosen text is bound, never SQL';
        my $top=$model->(pivot_column_top=>2,pivot_column_top_measure=>'revenue');
        is_deeply $heads->($top),['[NULL]','C'],'top N descends by selected measure including missing';
        my $top_csv=$e->export($top,'csv');$top_csv =~ s/"//g;
        like $top_csv,qr/Total,50,1,40,1,90,2/, 'top N totals exclude values outside the columns';
        my $top_other=$model->(pivot_column_top=>2,pivot_column_top_measure=>'revenue',pivot_column_other=>1);
        is_deeply $heads->($top_other),['[NULL]','C','Other'],'top N with Other';
        my $top_other_csv=$e->export($top_other,'csv');$top_other_csv =~ s/"//g;
        like $top_other_csv,qr/Total,50,1,40,1,60,3,150,5/, 'top N plus Other preserves unfiltered total';
        my $tie=$model->(pivot_column_top=>3,pivot_column_top_measure=>'loads');
        is_deeply $heads->($tie),[qw(C D G)],'ties break deterministically by label';
        my $dimension_tie=$model->(group=>['region','client.name'],pivot_column=>'client.name',pivot_column_top=>3,pivot_column_top_measure=>'loads');
        is_deeply $heads->($dimension_tie),['Same','Same','[NULL]'],'dimension rank ties retain labels';
        is_deeply [map {$_->{selection_value}} @{$dimension_tie->{result}{pivot_data}{columns}}],
            [1,2,'__selecto_pivot_missing__'],'dimension ties break by label then stable key';
        my $top2=$model->(pivot_column_top=>2,pivot_column_top_measure=>'revenue',page=>2,limit=>1);
        is_deeply $heads->($top2),$heads->($top),'page two shares the global top columns';
        my $top_grid=$model->(pivot_column_top=>2,pivot_column_top_measure=>'revenue',aggregate_grid=>1,pivot_column_other=>1);
        is_deeply [map {$_->{value}} @{$top_grid->{result}{grid_data}{columns}}],['[NULL]','C','Other'],'grid shares top order';
        my $top_url=$e->canonical_url($top->{state},$domain);
        my $top_again=$e->model($c,Selecto::Components::Dashboard->new->input_from_url($top_url));
        is_deeply $heads->($top_again),$heads->($top),'top N URL roundtrip';
        my $override=$model->(pivot_column_top=>1,pivot_column_value=>[qw(G P)]);
        is_deeply $heads->($override),[qw(G P)],'explicit choices override top N';
        for my $invalid (0, -1, 501, '2.5', 'bad') {
            my $m=$e->model($c,{%base,pivot_column_top=>$invalid});ok !$m->{state}->valid,"reject invalid N $invalid";
        }
        my $invalid_measure=$e->model($c,{%base,pivot_column_top=>2,pivot_column_top_measure=>'unknown'});
        ok !$invalid_measure->{state}->valid,'top measure must be selected';
        $t->get_ok('/loads'=>form=>{%base,pivot_column_top=>2,pivot_column_other=>1})->status_is(200);
        $form=$t->tx->res->dom->at('.sc-pivot-drill-form');%drill=();
        push @{$drill{$_->attr('name')}},$_->attr('value') for @{$form->find('input')};
        $t->get_ok('/loads'=>form=>{%drill,grid_axis=>to_json({axis=>1,value=>'__selecto_pivot_other__'})})->status_is(200);
        is_deeply [sort map {$_->all_text} @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}],[1,2,3],'top Other drill retains global list';
        my $ordered=$model->();
        is_deeply $heads->($ordered),['P','G','C','D',undef],'declared order, unlisted text then missing';
        my $axis_rows=$model->(group=>[qw(status region)],pivot_column=>'region',aggregate_grid=>1);
        is_deeply [map {$_->{value}} @{$axis_rows->{result}{grid_data}{rows}}],['P','G','C','D',undef],'declared order on row grid axis';
        my $ordered_summary=$model->(group=>['status'],pivot_column=>'',limit=>250);
        is_deeply [map {$_->{status}} grep {($_->{__selecto_rollup_level}//1)==1} @{$ordered_summary->{result}{records}}],
            ['P','G','C','D',undef],'summary rows follow declared order';
        my $summary_page=$model->(group=>['status'],pivot_column=>'',limit=>1,page=>2);
        is $summary_page->{result}{records}[0]{status},'P','SQL paging honors declared order after total';
        my $graph_data=sub {
            my (%more)=@_;
            $t->get_ok('/loads'=>form=>{%base,view=>'graph',graph_series_group=>'status',measure=>'revenue',%more})->status_is(200);
            my $chart=$t->tx->res->dom->at('[data-sc-chart]');
            ok $chart,'graph renders' or diag $t->tx->res->body;
            return $chart ? from_json($chart->attr('data-chart-data')) : {};
        };
        my $graph=$graph_data->(pivot_column_value=>[qw(G P X)],pivot_column_other=>1);
        is_deeply [map {$_->{label}} @{$graph->{datasets}}],['G','P','X','Other'],'chosen graph series order including empty and Other';
        is_deeply $graph->{datasets}[2]{data},[undef,undef],'empty chosen series remains empty';
        my $top_graph=$graph_data->(pivot_column_top=>2,pivot_column_other=>1);
        is_deeply [map {$_->{label}} @{$top_graph->{datasets}}],['[NULL]','C','Other'],'top graph series match pivot order';
        my $plain_graph=$graph_data->();
        is_deeply [map {$_->{label}} @{$plain_graph->{datasets}}],['P','G','C','D','—'],'declared graph series order';
        my $dim_graph=$graph_data->(group=>['region','client.name'],pivot_column=>'client.name',graph_series_group=>'client.name',pivot_column_value=>[3,2,1]);
        is_deeply [map {$_->{label}} @{$dim_graph->{datasets}}],['Empty','Same','Same'],'graph keeps duplicate dimension names separate';
        my $saved=Selecto::Components::Controller::SavedQueries::_canonical_saved_query_url($c,$e,$top_url);
        my $saved_model=$e->model($c,Selecto::Components::Dashboard->new->input_from_url($saved));
        is_deeply $heads->($saved_model),$heads->($top),'saved-query canonicalization retains top state';
        my $chosen_saved=Selecto::Components::Controller::SavedQueries::_canonical_saved_query_url($c,$e,$e->canonical_url($chosen->{state},$domain));
        my $chosen_saved_model=$e->model($c,Selecto::Components::Dashboard->new->input_from_url($chosen_saved));
        is_deeply $heads->($chosen_saved_model),$heads->($chosen),'saved-query canonicalization retains chosen state';
        my $insert=$dbh->prepare("INSERT INTO $table VALUES (?, 'East', ?, NULL, 0)");
        $insert->execute(1000+$_, 'S'.$_) for 1..362;
        my ($distinct)=$dbh->selectrow_array("SELECT COUNT(*) FROM (SELECT status FROM $table GROUP BY status) AS column_values");
        is $distinct,367,'high-cardinality fixture has exactly 367 values';
        my $wide=$model->();ok $wide->{result}{pivot_data}{limit},'unselected high cardinality refused';
        $t->get_ok('/loads'=>form=>\%base)->status_is(200);
        like $t->tx->res->dom->at('.sc-grid-warning')->all_text,qr/choose the values, or show the top N/i,'column limit offers both fixes';
        my $wide_grid=$model->(aggregate_grid=>1,measure=>'revenue');
        is $wide_grid->{result}{grid_limit}{kind},'columns','single-measure explicit grid also respects column limit';
        my $five=$model->(pivot_column_value=>[qw(G P X Y Z)]);
        is_deeply $heads->($five),[qw(G P X Y Z)], 'five chosen values out of 367 render';
        $dbh->do("DELETE FROM $table WHERE id > 1000");
        $dbh->do("ALTER TABLE $table ADD COLUMN tenant integer DEFAULT 1");
        $dbh->do("ALTER TABLE $clients ADD COLUMN tenant integer DEFAULT 1");
        $dbh->do("ALTER TABLE $clients ADD COLUMN active integer DEFAULT 1");
        $dbh->do("INSERT INTO $clients VALUES (4,'Foreign',2,1),(5,'Inactive',1,0)");
        my $original_domain=$domain;
        my $scoped_contract=$domain->contract;
        push @{$scoped_contract->{source}{fields}},'tenant';
        $scoped_contract->{source}{columns}{tenant}={type=>'integer'};
        $scoped_contract->{source}{tenant_field}='tenant';
        push @{$scoped_contract->{schemas}{clients}{fields}},'tenant','active';
        $scoped_contract->{schemas}{clients}{columns}{tenant}={type=>'integer'};
        $scoped_contract->{schemas}{clients}{columns}{active}={type=>'integer'};
        $scoped_contract->{schemas}{clients}{tenant_field}='tenant';
        $scoped_contract->{source}{associations}{client}{where}={active=>1};
        $domain=Selecto::Domain->parse($scoped_contract,strict=>1);
        my $factory=$e->config->engine_factory;
        $e->config->engine_factory(sub {Selecto::Engine->new(domain=>$domain,adapter=>$adapter)->with_tenant(1)});
        my $scoped=$model->(group=>['region','client.name'],pivot_column=>'client.name',pivot_column_value=>[3]);
        is_deeply $heads->($scoped),['Empty'],'unused dimension label keeps tenant and target predicates';
        $t->post_ok('/loads/column-values'=>form=>{csrf_token=>$csrf,field=>'client.name',term=>'Foreign'})->status_is(200)->json_is('/choices',[]);
        $t->post_ok('/loads/column-values'=>form=>{csrf_token=>$csrf,field=>'client.name',term=>'Inactive'})->status_is(200)->json_is('/choices',[]);
        $t->post_ok('/loads/column-values'=>form=>{csrf_token=>$csrf,field=>'client.name',term=>'Empty'})->status_is(200)->json_is('/choices/0/label','Empty');
        $e->config->engine_factory($factory);$domain=$original_domain;
        $dbh->do("INSERT INTO $table (id,region,status,client_id,revenue) VALUES (6,'East','',NULL,7),(7,'East','R',NULL,100),(8,'East','S',NULL,9)");
        my $empty=$model->(pivot_column_value=>['','G'],pivot_column_other=>1);
        is_deeply $heads->($empty),['','G','Other'],'empty stored text is distinct from missing and Other';
        $t->get_ok('/loads'=>form=>{%base,pivot_column_value=>['','G'],pivot_column_other=>1})->status_is(200);
        $form=$t->tx->res->dom->at('.sc-pivot-drill-form');%drill=();
        push @{$drill{$_->attr('name')}},$_->attr('value') for @{$form->find('input')};
        $t->get_ok('/loads'=>form=>{%drill,grid_axis=>to_json({axis=>1,value=>''})})->status_is(200);
        is_deeply [map {$_->all_text} @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}],[6],'empty stored value drilldown is executable';
        my $numeric_contract=$domain->contract;
        $numeric_contract->{source}{columns}{revenue}{value_order}=[30,10];
        $domain=Selecto::Domain->parse($numeric_contract,strict=>1);
        my $numeric_order=$model->(group=>['revenue'],pivot_column=>'',measure=>'loads');
        is_deeply [map {$_->{revenue}} grep {($_->{__selecto_rollup_level}//1)==1} @{$numeric_order->{result}{records}}],
            [30,10,100,20,40,50,7,9],'unlisted numeric values use text order in SQL too';
        $domain=$original_domain;
        $dbh->do("DELETE FROM $table WHERE id IN (6,7,8)");
        # XLSX is a valid archive and carries the same headers.
        my $xlsx=$e->export($dim,'xlsx');my $xml='';
        my $zip=IO::Uncompress::Unzip->new(\$xlsx) or die $UnzipError;
        do {my $buf='';my $chunk;while ($zip->read($chunk)>0) {$buf.=$chunk} $xml.=$buf} while $zip->nextStream;
        like $xml,qr/Empty.*Revenue/s,'XLSX dimension headers';
        my $private_contract=$domain->contract;$private_contract->{components}{query_params}=0;
        $domain=Selecto::Domain->parse($private_contract,strict=>1);
        my $private_model=$model->(pivot_column_value=>[qw(G P X)]);
        is $e->canonical_url($private_model->{state},$domain),'/loads','private pivot state stays out of URLs';
        is_deeply $heads->($private_model),[qw(G P X)],'private body state keeps ordered columns';
        $t->post_ok('/loads/column-values'=>form=>{csrf_token=>$csrf,field=>'status',term=>'G'})
            ->status_is(200)->json_is('/choices/0/value','G');
        $t->get_ok('/loads/column-values')->status_is(404);
        $domain=$original_domain;
    };
}
done_testing;
