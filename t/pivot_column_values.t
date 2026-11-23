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
        my $domain = Selecto::Domain->new(name=>'Loads',table=>$table,
            fields=>{id=>'integer',region=>'string',status=>'string',client_id=>'integer',revenue=>'integer'},
            associations=>{client=>{table=>$clients,owner_key=>'client_id',related_key=>'id',cardinality=>'one',
                join_mode=>'star_dimension',dimension_key=>'client_id',display_field=>'name',fields=>{id=>'integer',name=>'string'}}});
        my $adapter = Selecto->adapter($backend => (dbh=>$dbh));
        my $app=Mojolicious->new;
        $app->secrets(['pivot-values']);$app->log->level('fatal');
        $app->plugin('Selecto::Components'=>{websocket_mode=>'public',explorers=>{
            loads=>{path=>'/loads',default_fields=>[qw(id status client_id)],max_grid_columns=>5,
                engine_factory=>sub { Selecto::Engine->new(domain=>$domain,adapter=>$adapter) },
                measures=>[{id=>'revenue',label=>'Revenue',aggregate=>'sum',field=>'revenue'},{id=>'loads',label=>'Loads',aggregate=>'count'}]}}});
        my $t=Test::Mojo->new($app);
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
        my $dim=$model->(group=>['region','client.name'],pivot_column=>'client.name',pivot_column_value=>[3,2,1]);
        is_deeply $heads->($dim),['Empty','Same','Same'],'empty dimension heading and duplicate names';
        is_deeply [map {$_->{selection_value}} @{$dim->{result}{pivot_data}{columns}}],[3,2,1],'dimension identity is key';
        my $grid=$model->(group=>['region','client.name'],pivot_column=>'client.name',pivot_column_value=>[3,2,1],aggregate_grid=>1);
        is_deeply [map {$_->{value}} @{$grid->{result}{grid_data}{columns}}],['Empty','Same','Same'],'grid keeps duplicate keys and empty heading';
        $t->get_ok('/loads/column-values?field=client.name&term=Emp')->status_is(200)->json_is('/choices/0/value',3)->json_is('/choices/0/label','Empty');
        $t->get_ok('/loads/column-values?field=status&term=P')->status_is(200)->json_is('/choices/0/value','P');
        my $bad=$e->model($c,{%base,pivot_column_value=>['x'x1001]});ok !$bad->{state}->valid,'value length bounded';
        $bad=$e->model($c,{%base,pivot_column_value=>[1..101]});ok !$bad->{state}->valid,'value count bounded';
        my $injection=$model->(pivot_column_value=>["P' OR 1=1 --",'G']);
        is scalar(@{$injection->{result}{records}}),2,'chosen text is bound, never SQL';
        my $insert=$dbh->prepare("INSERT INTO $table VALUES (?, 'East', ?, NULL, 0)");
        $insert->execute(1000+$_, 'S'.$_) for 1..367;
        my $wide=$model->();ok $wide->{result}{pivot_data}{limit},'unselected high cardinality refused';
        my $five=$model->(pivot_column_value=>[qw(G P X Y Z)]);
        is_deeply $heads->($five),[qw(G P X Y Z)], 'five chosen values out of 367 render';
        $dbh->do("DELETE FROM $table WHERE id > 1000");
        # XLSX is a valid archive and carries the same headers.
        my $xlsx=$e->export($dim,'xlsx');my $xml='';
        my $zip=IO::Uncompress::Unzip->new(\$xlsx) or die $UnzipError;
        do {my $buf='';my $chunk;while ($zip->read($chunk)>0) {$buf.=$chunk} $xml.=$buf} while $zip->nextStream;
        like $xml,qr/Empty.*Revenue/s,'XLSX dimension headers';
    };
}
done_testing;
