use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use SavedViewsFixture;
use TestSelectoComponents;
use Selecto::Components::SavedView;
use Selecto::Components::Controller::SavedQueries;
use Mojo::URL;
my $f = SavedViewsFixture->new;
my $config = $f->{config};
my $ctx = TestSelectoComponents::Controller->new;
my $view = 'Selecto::Components::SavedView';
my $url = '/explore/orders?q=1&field=order_ref&limit=25&page=3';
my $valid = $view->check($config, $ctx, $url);
ok($valid->{ok}, 'valid URL');
is(Mojo::URL->new($valid->{url})->query->param('page'), 1, 'normalized to first page for saving');
ok($view->check($config, $ctx, {q => 1, field => 'order_ref'})->{ok}, 'form state accepted');
for my $test (
    ['unknown field', {q => 1, field => 'absent'}, 'absent'],
    ['bad value', {q => 1, field => 'order_ref', filter_field => 'piece_count', filter_op => 'eq', filter_value => 'bad'}, 'piece_count'],
    ['bad date', {q => 1, field => 'order_ref', filter_field => 'received_on', filter_value => 'nonsense'}, 'received_on'],
) {
    my ($label, $state, $field) = @$test;
    my $checked = $view->check($config, $ctx, $state);
    ok(!$checked->{ok}, "$label refused");
    ok(grep(($_->{field} // '') eq $field, @{$checked->{errors}}), "$label names field");
}
$ctx->{private} = 1;
my $hidden = '/explore/orders?q=1&field=order_ref&field=contact_email&filter_field=contact_email&filter_op=eq&filter_value=hidden';
ok(!$view->check($config, $ctx, $hidden)->{ok}, 'unreadable field refused');
my $explain = $view->explain($config, $ctx, $hidden);
is($explain->{kind}, 'explorer_view', 'shared restricted view explained');
is($explain->{omitted_fields}, 1, 'unreadable source field counted once');
is_deeply([map { $_->{field} } @{$explain->{fields}}], ['order_ref'], 'readable selection retained');
is_deeply($explain->{filters}, [], 'unreadable filter omitted with its value');
is_deeply($view->explain($config, $ctx, '/other?q=1'), {kind => 'not_an_explorer_view', path => '/other'}, 'other page is context');
for my $bad ('https://outside.invalid/explore/orders', '//outside.invalid/explore/orders', '/explore/orders#fragment') {
    ok(!$view->check($config, $ctx, $bad)->{ok}, 'unsafe URL rejected');
}
my $bad_option = $view->check($config, $ctx, {q => 1, field => 'order_ref', adapter => 'sqlite'});
ok(!$bad_option->{ok} && grep(($_->{option} // '') eq 'adapter', @{$bad_option->{errors}}), 'unknown option named');
# Exercise the actual sibling MCP builder, without making it a distribution
# dependency. The generated URL is parsed by the public API for every view.
SKIP: {
    my $mcp = '../selecto-perl-mcp/lib';
    skip 'optional MCP sibling absent', 35 unless -f "$mcp/Selecto/MCP/ExplorerURLBuilder.pm";
    unshift @INC, $mcp;
    require Selecto::MCP::ExplorerURLBuilder;
    for my $type (qw(detail aggregate graph)) {
        my $aggregate = $type ne 'detail';
        my $q = {select => ['order_ref'], filters => [{field => 'piece_count', operator => 'gte', value => 2}],
            limit => 25, offset => 0, order_by => [], ($aggregate ? (group_by => [{field => 'order_ref', as => 'Reference', bucket => 'identity'}],
            aggregates => [{field => 'piece_count', function => 'sum', as => 'Pieces'}]) : ())};
        my $target = {url => '/explore/orders', query_params => JSON::PP::true, views => [qw(detail aggregate graph)],
            max_limit => 100, field_map => {map { $_ => $_ } qw(order_ref piece_count received_on)}};
        my $built = Selecto::MCP::ExplorerURLBuilder->build($target, {public => $q}, $type,
            {order_ref => 'string', piece_count => 'integer'}, {});
        my $explained = $view->explain($config, $ctx, $built->{url});
        is($explained->{kind}, 'explorer_view', "$type builder URL explained");
        is($explained->{view}, $type, "$type round trip");
        is($explained->{filters}[0]{field}, 'piece_count', "$type filter field retained");
        is($explained->{page_size}, 25, "$type page size retained");
        is_deeply($explained->{errors}, [], "$type URL passes full State validation") or diag explain $explained->{errors};
        is($explained->{filters}[0]{op}, 'gte', "$type operator retained");
        is($explained->{filters}[0]{value}, '2', "$type value retained");
        is($explained->{fields}[0]{field}, 'order_ref', "$type detail field retained");
        if ($aggregate) {
            is($explained->{groups}[0]{field}, 'order_ref', "$type group retained");
            is($explained->{measures}[0]{function}, 'sum', "$type aggregate retained");
            is($explained->{measures}[0]{field}, 'piece_count', "$type measure source retained");
            is($explained->{measures}[0]{label}, 'Piece Count', "$type measure label retained");
        }
        if ($type eq 'aggregate') {
            push @{$q->{group_by}}, {field => 'received_on', as => 'Received', bucket => 'identity'};
            my $pivot = Selecto::MCP::ExplorerURLBuilder->build($target, {public => $q}, $type,
                {order_ref => 'string', piece_count => 'integer', received_on => 'date'}, {aggregate_grid => JSON::PP::true, pivot_column => 1});
            my $roundtrip = $view->explain($config, $ctx, $pivot->{url});
            is_deeply($roundtrip->{errors}, [], 'pivot builder URL validates') or diag explain $roundtrip->{errors};
            is($roundtrip->{state}{pivot_column}, 'received_on', 'pivot column retained');
            ok($roundtrip->{state}{aggregate_grid}, 'pivot grid retained');
        }
    }
}
my $all_private = $view->explain($config, $ctx, '/explore/orders?q=1&field=contact_email&graph_category_field=contact_email&graph_category_value=hidden&graph_category_color=%23ffffff');
is_deeply($all_private->{fields}, [], 'all unreadable fields omitted');
is_deeply($all_private->{state}{fields}, [], 'state also omits all unreadable fields');
is_deeply($all_private->{state}{graph_category_colors}, [], 'unreadable graph category values omitted');
my $private_pivot = $view->explain($config, $ctx, '/explore/orders?q=1&view=aggregate&field=order_ref&group=order_ref&group=contact_email&pivot_column=contact_email&pivot_column_value=hidden');
is_deeply($private_pivot->{state}{pivot_column_values}, [], 'unreadable pivot choices omitted with their axis');
$ctx->{private} = 0;
my $formatted = $view->explain($config, $ctx, '/explore/orders?q=1&view=aggregate&field=order_ref&group=order_ref&group=contact_email&group_format=&group_format=text_prefix&pivot_column=contact_email&pivot_column_value=hidden');
$ctx->{private} = 1;
my $formatted_private = $view->explain($config, $ctx, $formatted->{url});
is_deeply($formatted_private->{state}{pivot_column_values}, [], 'formatted private pivot choices omitted after canonical round trip');
my $period = $view->explain($config, $ctx, $url . '&as_of=2026-11-01');
is($period->{period}, '2026-11-01', 'period retained');
is($period->{state}{page}, 3, 'explain retains original page');
my $normalized = Selecto::Components::Controller::SavedQueries::_normalize_saved_queries($config,
    [{id => 'personal.WyIxIl0', name => 'Saved', url => $url, revision => 'sha256:' . ('a' x 64), scope => 'team'}]);
is($normalized->[0]{revision}, 'sha256:' . ('a' x 64), 'UI preserves native revision');
is($normalized->[0]{scope}, 'team', 'UI preserves source scope');
$f->cleanup;
done_testing;
