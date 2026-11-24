use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use DBI;
use Encode qw(decode);
use Mojolicious;
use Mojo::JSON qw(from_json to_json);
use Mojo::URL;
use IO::Uncompress::Unzip qw($UnzipError);
use Selecto;
use Selecto::Components;
use Selecto::Components::Dashboard;

for my $backend (qw(sqlite postgresql)) {
    next if $backend eq 'postgresql' && !$ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    subtest $backend => sub {
        my $dbh;
        if ($backend eq 'sqlite') {
            $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError=>1});
        } else {
            my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
            $dbh = DBI->connect('dbi:Pg:dbname='.substr($url->path,1).';host='.$url->host.';port='.$url->port,
                $url->username, $url->password, {RaiseError=>1});
        }
        # Synthetic pre-aggregated orders exercise unequal totals and missing values.
        $dbh->do('CREATE TEMP TABLE orders (id integer primary key, origin varchar(20), destination varchar(20), piece_count integer, delivered_on date, band integer)');
        my @states = ('MO','FL','CA',undef,qw(AL TN GA TX AZ CO IL IN KS LA MA MI));
        my @piece_count = (1821,654,632,611,603,415,350,297,290,280,275,270,265,260,255,250);
        my $insert = $dbh->prepare('INSERT INTO orders VALUES (?,?,?,?,?,?)');
        for my $i (0..$#states) {
            $insert->execute($i+1, $i % 2 ? 'West' : 'East', $states[$i], $piece_count[$i],
                $i < 3 ? ('2026-12-01','2026-02-01','2026-10-01')[$i] : undef,
                $i < 3 ? (15,6,25)[$i] : undef);
        }
        my $domain = Selecto::Domain->parse({schema_version=>1,name=>'Orders',source=>{source_table=>'orders',primary_key=>'id',
            fields=>[qw(id origin destination piece_count delivered_on band)],columns=>{map {$_=>{type=>($_ eq 'delivered_on' ? 'date' : /\A(?:id|piece_count|band)\z/ ? 'integer' : 'string')}} qw(id origin destination piece_count delivered_on band)}}},strict=>1);
        my $adapter = Selecto->adapter($backend => (dbh=>$dbh));
        my $app = Mojolicious->new;
        $app->secrets(['top-column-order']); $app->log->level('fatal');
        $app->plugin('Selecto::Components'=>{websocket_mode=>'public',explorers=>{
            orders=>{path=>'/orders',default_fields=>['id'],
                engine_factory=>sub {Selecto::Engine->new(domain=>$domain,adapter=>$adapter)},
                measures=>[{id=>'piece_count',label=>'Piece Count',aggregate=>'sum',field=>'piece_count'}]}}});
        my $t = Test::Mojo->new($app);
        my $c = $app->build_controller;
        my $e = $c->selecto_components_explorer('orders');
        my %base = (q=>1,view=>'aggregate',field=>'id',group=>[qw(origin destination)],measure=>'piece_count',
            pivot_column=>'destination',pivot_column_top=>8,pivot_column_other=>1);
        my $model = sub {
            my %input = (%base,@_);
            my $m = $e->model($c,\%input);
            ok $m->{state}->valid, 'valid state' or diag explain $m->{state}->errors;
            ok !$m->{runtime_error}, 'query executes' or diag $m->{runtime_error};
            return $m;
        };
        my $heads = sub { [map {$_->{value}} @{$_[0]{result}{pivot_data}{columns}}] };
        my $grid_heads = sub { [map {$_->{value}} @{$_[0]{result}{grid_data}{columns}}] };
        my $rank = $model->();
        is_deeply $heads->($rank), ['MO','FL','CA','[NULL]',qw(AL TN GA TX Other)], 'Orders default retains exact rank, including missing in fourth place';
        my $rank_csv = $e->export($rank,'csv'); $rank_csv =~ s/"//g;
        like $rank_csv, qr/1 · MO · Piece Count/, 'rank shown in CSV';
        like $rank_csv, qr/4 · \[NULL\] · Piece Count/, 'missing has its rank in CSV';
        like $rank_csv, qr/Total,1821,654,632,611,603,415,350,297,2145,7528/, 'Orders totals match the specified shape';
        my $natural = $model->(pivot_column_top_order=>'natural');
        is_deeply $heads->($natural), [qw(AL CA FL GA MO TN TX),'[NULL]','Other'], 'natural order sorts only selected values, missing then Other';
        my $natural_csv = $e->export($natural,'csv'); $natural_csv =~ s/"//g;
        like $natural_csv, qr/Total,603,632,654,350,1821,415,297,611,2145,7528/, 'natural display keeps membership and totals';
        unlike $natural_csv, qr/1 ·/, 'natural headers have no ranks';
        is_deeply $grid_heads->($model->(aggregate_grid=>1)), $heads->($rank), 'grid shares rank selection';
        is_deeply $grid_heads->($model->(aggregate_grid=>1,pivot_column_top_order=>'natural')), $heads->($natural), 'grid shares natural selection';
        for my $order ('rank','natural') {
            for my $grid (0,1) {
                $t->get_ok('/orders'=>form=>{%base,pivot_column_top_order=>$order,aggregate_grid=>$grid})->status_is(200);
                my $selector = $grid ? '.sc-aggregate-grid thead' : '.sc-pivot-table thead';
                my $head = $t->tx->res->dom->at($selector);
                ok $head, 'table rendered';
                if ($head) {
                    if ($order eq 'rank') { like $head->all_text, qr/4 · \[NULL\]/, 'ranked missing heading visible' }
                    else { unlike $head->all_text, qr/1 ·/, 'natural table is unnumbered' }
                }
                is $t->tx->res->dom->at('[data-sc-pivot-values]:not([hidden]) [data-sc-pivot-top-order] select option[selected]')->attr('value'), $order, 'Configure retains column order';
            }
        }
        for my $m ($rank,$natural) {
            my $url = $e->canonical_url($m->{state},$domain);
            if ($m == $rank) { unlike $url, qr/pivot_column_top_order/, 'default rank omitted from legacy-compatible permalink' }
            else { like $url, qr/pivot_column_top_order=natural/, 'natural encoded in permalink' }
            my $saved = Selecto::Components::Controller::SavedQueries::_canonical_saved_query_url($c,$e,$url);
            for my $source ($url,$saved) {
                my $again = $e->model($c,Selecto::Components::Dashboard->new->input_from_url($source));
                is_deeply $heads->($again), $heads->($m), 'permalink and saved query round-trip order';
            }
            my $xlsx = $e->export($m,'xlsx');
            my $zip = IO::Uncompress::Unzip->new(\$xlsx) or die $UnzipError;
            my $xml = '';
            do { my $chunk; while ($zip->read($chunk)>0) { $xml .= $chunk } } while $zip->nextStream;
            $xml = decode('UTF-8',$xml);
            if ($m == $rank) { like $xml, qr/4 · \[NULL\] · Piece Count/, 'XLSX uses same ranked header as CSV' }
            else { unlike $xml, qr/1 · MO/, 'XLSX natural headers unnumbered' }
        }
        # Series use the resolved display order, with their original labels.
        for my $order ('rank','natural') {
            $t->get_ok('/orders'=>form=>{%base,view=>'graph',graph_series_group=>'destination',pivot_column_top_order=>$order})->status_is(200);
            my $chart = $t->tx->res->dom->at('[data-sc-chart]');
            ok $chart, 'graph renders';
            is_deeply [map {$_->{label}} @{from_json($chart->attr('data-chart-data'))->{datasets}}],
                $heads->($order eq 'rank' ? $rank : $natural), 'graph series follow pivot order' if $chart;
        }
        my $chosen = $model->(pivot_column_value=>['TX','missing','MO'],pivot_column_value_null=>1,pivot_column_top_order=>'natural');
        is_deeply $heads->($chosen), ['TX','[NULL]','MO','Other'], 'explicit chosen order and middle missing unaffected';
        unlike $e->export($chosen,'csv'), qr/1 ·/, 'explicit choices do not acquire ranks';
        # Detail receives resolved keys and the reordered missing-value index.
        $t->get_ok('/orders'=>form=>{%base,pivot_column_top_order=>'natural'})->status_is(200);
        my %drill;
        push @{$drill{$_->attr('name')}}, $_->attr('value') for @{$t->tx->res->dom->find('.sc-pivot-drill-form input')};
        is_deeply $drill{pivot_column_value}, [qw(AL CA FL GA MO TN TX),'__selecto_pivot_missing__'], 'Detail carries the resolved list';
        is_deeply $drill{pivot_column_value_null}, [7], 'Detail carries missing position after sorting';
        $t->get_ok('/orders'=>form=>{%drill,grid_axis=>to_json({axis=>1,value=>'__selecto_pivot_other__'})})->status_is(200);
        is_deeply [sort {$a<=>$b} map {0+$_->all_text} @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}], [9..16], 'Detail Other keeps original membership without reranking';
        my $invalid = $e->model($c,{%base,pivot_column_top_order=>'random'});
        ok !$invalid->{state}->valid, 'unknown display order rejected';
        # Typed dates, formatted dates and authored/stepped numeric ranges.
        my %date = (group=>[qw(origin delivered_on)],pivot_column=>'delivered_on',pivot_column_top=>3,group_exclude_missing=>'delivered_on');
        is_deeply $heads->($model->(%date)), ['2026-12-01','2026-02-01','2026-10-01','Other'], 'date rank differs from time order';
        is_deeply $heads->($model->(%date,pivot_column_top_order=>'natural')), ['2026-02-01','2026-10-01','2026-12-01','Other'], 'typed dates in time order';
        my %month = (%date,group_format=>['','month']);
        is_deeply $heads->($model->(%month,pivot_column_top_order=>'natural')), ['2026-02','2026-10','2026-12','Other'], 'formatted date top N in time order';
        my %bucket = (group=>[qw(origin band)],pivot_column=>'band',pivot_column_top=>2,group_format=>['','buckets'],group_bucket_ranges=>['','5-9, 10-20, 21+'],group_exclude_missing=>'band');
        my $bucket_rank = $model->(%bucket);
        is_deeply $heads->($bucket_rank), ['10-20','5-9','Other'], 'bucket top N ranks by measure';
        my $bucket_natural = $model->(%bucket,pivot_column_top_order=>'natural');
        is_deeply $heads->($bucket_natural), ['5-9','10-20','Other'], 'bucket top N follows range order';
        my $bucket_csv = $e->export($bucket_natural,'csv'); $bucket_csv =~ s/"//g;
        like $bucket_csv, qr/Total,654,1821,632,3107/, 'bucket Other excludes values outside authored ranges';
        is_deeply $heads->($model->(%bucket,group_bucket_ranges=>['','*/10'],pivot_column_top_order=>'natural')), ['0-9','10-19','Other'], 'stepped buckets follow numeric bounds';
        is_deeply $heads->($model->(%bucket,pivot_column_top=>3,group_bucket_ranges=>['','21+, 10-20, 5-9'],pivot_column_top_order=>'natural')),
            ['21+','10-20','5-9','Other'], 'natural range order follows authorship rather than numeric labels';
        # A formatted missing value still ranks and moves behind real dates.
        my %missing_month = (%month,group_exclude_missing=>'',pivot_column_top=>4);
        is_deeply $heads->($model->(%missing_month)), ['[NULL]','2026-12','2026-02','2026-10','Other'], 'formatted missing value retains measure rank';
        is_deeply $heads->($model->(%missing_month,pivot_column_top_order=>'natural')), ['2026-02','2026-10','2026-12','[NULL]','Other'], 'formatted missing follows real dates in natural order';
        $t->get_ok('/orders'=>form=>{%base,%bucket,pivot_column_top_order=>'natural'})->status_is(200);
        %drill = ();
        push @{$drill{$_->attr('name')}}, $_->attr('value') for @{$t->tx->res->dom->find('.sc-pivot-drill-form input')};
        $t->get_ok('/orders'=>form=>{%drill,grid_axis=>to_json({axis=>1,value=>'__selecto_pivot_other__'})})->status_is(200);
        is_deeply [map {0+$_->all_text} @{$t->tx->res->dom->find('.sc-results tbody tr td:first-child')}], [3], 'bucket Other Detail keeps selected labels and authored range exclusion';
        my $empty_month = $model->(%missing_month,pivot_column_value=>['1999-01'],pivot_column_top_order=>'natural');
        is_deeply $heads->($empty_month), ['1999-01','Other'], 'empty carried formatted choice remains a column';
        # Host value_order overrides text for natural display only.
        my $contract = $domain->contract;
        $contract->{source}{columns}{destination}{value_order} = [qw(TX MO)];
        $domain = Selecto::Domain->parse($contract,strict=>1);
        is_deeply $heads->($model->(pivot_column_top_order=>'natural')), [qw(TX MO AL CA FL GA TN),'[NULL]','Other'], 'natural honors value_order';
        is_deeply $heads->($model->()), $heads->($rank), 'value_order cannot change rank selection or ordering';
        $dbh->disconnect;
    };
}
done_testing;
