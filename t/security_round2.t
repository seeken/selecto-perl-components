use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Transaction::HTTP;
use Mojo::IOLoop;
use File::Temp qw(tempdir tempfile);
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Controller::QueryAssistant;
use Selecto::Components::QueryAssistant::Store;
use Selecto::Components::ResponseBudget;
use Selecto::Components::ExportBudget;
use Selecto::Components::ExplorerSession;
use Selecto::Components::Renderer::Debug;
use Selecto::Components::Renderer::Results;

subtest 'cache namespace is mandatory and immutable key material' => sub {
    my $statement=Selecto::Statement->new(sql=>'SELECT x',columns=>['x'],params=>[],adapter_name=>'postgresql');
    my $key=Selecto::Components::Explorer->result_cache_key($statement,'source1:tenant1:policy1','domain1');
    for my $namespace ('source2:tenant1:policy1','source1:tenant2:policy1','source1:tenant1:policy2') {
        isnt(Selecto::Components::Explorer->result_cache_key($statement,$namespace,'domain1'),$key,'authority/data source changes isolate same statement');
    }
    isnt(Selecto::Components::Explorer->result_cache_key($statement,'source1:tenant1:policy1','domain2'),$key,'domain also isolates');
    ok !eval {Selecto::Components::Explorer->result_cache_key($statement,undef,'domain1');1},'missing namespace refused';
    my $spec=TestSelectoComponents::config(); delete $spec->{result_cache_namespace};
    my $explorer=Selecto::Components::Explorer->new(config=>Selecto::Components::Config->new(%$spec,id=>'products'));
    ok !eval {$explorer->model(TestSelectoComponents::Controller->new,{}, {result_cache=>Selecto::Components::ExplorerSession->new});1},'explicit cache cannot silently use unscoped key';
    my $controller=TestSelectoComponents::Controller->new;
    $explorer->model($controller,{reuse_count=>1});
    ok !defined($controller->stash('selecto_count_cache')),'missing namespace also disables persistent count reuse';

};

subtest 'assistant budgets precede callbacks and both range endpoints are checked' => sub {
    my @calls;
    my $spec=TestSelectoComponents::config();
    $spec->{query_assistant}={store=>Selecto::Components::QueryAssistant::Store->new,
        actor=>sub{'actor'},choice_fields=>{unit_price=>1},choice_range_fields=>{unit_price=>1},
        choice_resolver=>sub {my ($c,$r)=@_;push @calls,$r;return [{value=>'1'}]}};
    my $app=Mojolicious->new; $app->secrets(['bounded-assistant']);
    $app->plugin('Selecto::Components'=>{explorers=>{products=>$spec}});
    my $t=Test::Mojo->new($app);
    $t->get_ok('/explore/products')->status_is(200);
    my $csrf=$t->tx->res->dom->at('[data-sc-query-assistant]')->attr('data-sc-query-assistant-csrf');
    my $headers={'Content-Type'=>'application/json','X-CSRF-Token'=>$csrf};
    $t->post_ok('/explore/products/assistant/drafts'=>$headers=>json=>{input=>{}})->status_is(201);
    my $draft=$t->tx->res->json;
    my $target={view=>'detail',fields=>['product_name'],orders=>[],limit=>25,
        filters=>[{field=>'unit_price',operator=>'between',value=>'1',value_end=>'999'}]};
    for my $tool (qw(validate_query_target apply_query_draft)) {
        @calls=();
        $t->post_ok("/explore/products/assistant/drafts/$draft->{draft_id}/tools/$tool"=>$headers=>json=>{
            draft_id=>$draft->{draft_id},base_revision=>0,context_version=>$draft->{context_version},($tool eq 'apply_query_draft' ? (request_id=>$tool) : ()),target=>$target})
            ->status_is(422)->json_is('/code'=>'choice_unavailable');
        is_deeply $calls[0]{values},['1','999'],'both normalized endpoints reach resolver';
        is $spec->{query_assistant}{store}->get($draft->{draft_id})->{revision},0,'rejection leaves draft unchanged';
    }
    for my $filters ([map {{field=>'unit_price',operator=>'eq',value=>'1'}} 1..100],
        [{field=>'unit_price',operator=>'in',value=>[(1)x101]}]) {
        @calls=();$target->{filters}=$filters;
        $t->post_ok("/explore/products/assistant/drafts/$draft->{draft_id}/tools/validate_query_target"=>$headers=>json=>{
            draft_id=>$draft->{draft_id},base_revision=>0,context_version=>$draft->{context_version},target=>$target})->status_is(422);
        is scalar(@calls),0,'oversized target refused before resolver';
    }
    my $config=Selecto::Components::Config->new(%$spec,id=>'products');
    my $error=Selecto::Components::Controller::QueryAssistant::_validate_membership_choices(undef,
        {%{$spec->{query_assistant}},choice_range_fields=>{}},
        {filters=>[{field=>'unit_price',operator=>'between',value=>'1',value_end=>'2'}]},$config);
    is $error->{code},'choice_unavailable','ranges require explicit host semantics';
};

subtest 'lookup phase authorizes before metadata callbacks' => sub {
    my (@phases,$lookups);$lookups=0;
    my $spec=TestSelectoComponents::config();
    $spec->{action_authorizer}=sub {my($c,$r)=@_;push @phases,$r->{phase};return $r->{phase} eq 'lookup'?'hidden':'enabled'};
    $spec->{co_domain_engines}={client=>sub {$lookups++;die 'must not resolve'}};
    my $app=Mojolicious->new;$app->secrets(['lookup-phase']);
    $app->plugin('Selecto::Components'=>{explorers=>{products=>$spec}});
    Test::Mojo->new($app)->get_ok('/explore/products/actions/build_shipments/lookups/carrier_id?q=acme&selected_id=101&selected_id=102')->status_is(404);
    is_deeply \@phases,['lookup'],'lookup authorization used';
    is $lookups,0,'no metadata backend invoked after denial';
};

subtest 'bounded nested render, cache encode and final JSON' => sub {
    my $value=[map {{v=>'x'}} 1..101];
    ok !eval {Selecto::Components::Renderer::Results::_nested_table({nested_fields=>[{field=>'v',label=>'V'}]},$value);1},'root count cannot hide excessive children';
    my $limits=Selecto::Limits->new(max_response_bytes=>16);
    is(Selecto::Components::ResponseBudget->json(['x'x12],$limits),'["'.('x'x12).'"]','exact JSON byte boundary');
    ok !eval {Selecto::Components::ResponseBudget->json(['x'x13],$limits);1},'encoded byte limit plus one refused';
    ok !eval {Selecto::Components::ResponseBudget->json(["\x00"x3],$limits);1},'JSON escape expansion counted before encoding';
    ok !eval {Selecto::Components::ResponseBudget->render(Selecto::Limits->new,sub {
        Selecto::Components::ResponseBudget->render($limits,sub {'x'x17})});1},
        'nested render cannot discard tighter response policy';
    my $spec=TestSelectoComponents::config();
    my $factory=$spec->{engine_factory};
    $spec->{engine_factory}=sub {my $engine=$factory->(@_);$engine->{limits}=Selecto::Limits->new(max_response_bytes=>4096);$engine};
    my $explorer=Selecto::Components::Explorer->new(config=>Selecto::Components::Config->new(%$spec,id=>'products'));
    my $model=$explorer->model(TestSelectoComponents::Controller->new,{});
    is $model->{config}->limits->get('max_response_bytes'),4096,'model rendering inherits tighter engine ceiling';
    my $cache=Selecto::Components::ExplorerSession->new(max_bytes=>64);
    $cache->store('bad',{columns=>['x'],rows=>[["\x00"x30]]});
    ok !defined($cache->fetch('bad')),'cache preflights escaped JSON admission';
};

{
    package StalledResponse;
    use Mojo::Base -base;
    has tx=>sub{Mojo::Transaction::HTTP->new};has events=>sub{{}};has writes=>0;has callback=>undef;
    sub reply {shift} sub file {shift} sub res {shift->tx->res} sub on {my($s,$event,$cb)=@_;$s->events->{$event}=$cb;return $s}
    sub render_later {shift} sub write {my($s,$chunk,$cb)=@_;$s->writes($s->writes+1);$s->callback($cb);return $s}
}
subtest 'deadline releases resources independent of write progress' => sub {
    my $dir=tempdir(CLEANUP=>1);
    my $config=Selecto::Components::Config->new(%{TestSelectoComponents::config()},id=>'products',
        export_lock_dir=>$dir,max_export_seconds=>1,max_concurrent_exports=>1);
    my $engine=$config->engine(undef);
    my $budget=Selecto::Components::ExportBudget->new($config,$engine,undef);
    my $closed=0;my $controller=StalledResponse->new;
    Selecto::Components::_render_stream_export($controller,{config=>$config,budget=>$budget,
        next_chunk=>sub{$budget->output('x');return 'x'},close=>sub{$closed++;$budget->close}},'csv');
    Mojo::IOLoop->timer(1.1=>sub{Mojo::IOLoop->stop});Mojo::IOLoop->start;
    ok $budget->closed,'absolute timer closes stalled export';
    is $closed,1,'deadline invokes resource cleanup';
    ok eval {my $new=Selecto::Components::ExportBudget->new($config,$engine,undef);$new->close;1},'next export immediately acquires released lease';
    $controller->callback->();is $controller->writes,1,'late callback does not restart writes';
    $controller->events->{finish}->();ok $budget->closed,'later finish remains safe';
    my ($fh,$path)=tempfile(DIR=>$dir);print {$fh} 'workbook';close $fh;
    my $file_budget=Selecto::Components::ExportBudget->new($config,$engine,undef);
    my $file_controller=StalledResponse->new;my $file_closed=0;
    Selecto::Components::_render_file_export($file_controller,{config=>$config,budget=>$file_budget,path=>$path,
        close=>sub{$file_closed++;unlink $path;$file_budget->close}},'xlsx');
    Mojo::IOLoop->timer(1.1=>sub{Mojo::IOLoop->stop});Mojo::IOLoop->start;
    ok $file_budget->closed,'absolute timer also closes stalled file delivery';
    ok !-e $path,'deadline removes workbook spool';
    is $file_closed,1,'file deadline invokes resource cleanup';

};

done_testing;
