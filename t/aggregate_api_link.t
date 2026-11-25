use 5.034;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use DBI;
use Mojo::JSON qw(decode_json);
use Mojo::URL;
use Mojo::Util qw(url_unescape);
use Mojolicious;
use Selecto;
use Selecto::Components;
use Selecto::Components::APIHandoff;
use Selecto::Components::Renderer;

for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? ('postgresql') : ())) {
    subtest $backend => sub {
        my $dbh;
        if ($backend eq 'postgresql') {
            my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
            die 'An explicit disposable PostgreSQL port is required' unless $url->port && $url->port == 55448;
            $dbh = DBI->connect('dbi:Pg:dbname=' . substr($url->path, 1) . ';host=' . $url->host . ';port=' . $url->port,
                $url->username, $url->password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        } else {
            $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
        }
        $dbh->do('CREATE TEMP TABLE api_link_orders (id integer primary key, region varchar(12) NOT NULL, channel varchar(12) NOT NULL, amount integer, day date)');
        $dbh->do('INSERT INTO api_link_orders VALUES (?, ?, ?, ?, ?)', undef, @$_) for
            [1, 'East', 'Direct', 10, '2026-03-01'], [2, 'East', 'Direct', 20, '2026-03-02'],
            [3, 'East', 'Online', 30, '2026-04-01'], [4, 'West', 'Direct', 40, '2026-04-02'],
            [5, 'West', 'Online', undef, '2026-04-03'];
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Orders',
            source => {source_table => 'api_link_orders', primary_key => 'id', fields => [qw(id region channel amount day)],
                columns => {id => {type => 'integer'}, region => {type => 'string', nullable => 0},
                    channel => {type => 'string', nullable => 0}, amount => {type => 'integer'}, day => {type => 'date'}}, associations => {}},
            schemas => {}, joins => {}, query_library => {segments => {
                at_least => {parameters => {minimum => {type => 'integer', required => 1}},
                    filters => [['gte', 'id', ['param', 'minimum']]]},
            }}}, strict => 1);
        my $adapter = Selecto->adapter($backend => dbh => $dbh);
        my $plain_groups = 0;
        my $supports = $adapter->can('supports');
        @AggregateLinkAdapter::ISA = (ref $adapter);
        local $AggregateLinkAdapter::supports = $supports;
        local $AggregateLinkAdapter::plain = \$plain_groups;
        bless $adapter, 'AggregateLinkAdapter';
        my $app = Mojolicious->new;
        $app->secrets(['aggregate-api-link-invented-fixture']);
        $app->log->level('fatal');
        my %settings = (path => '/orders', title => 'Orders', default_fields => [qw(id region channel amount)],
            default_group => ['region'], default_limit => 25, max_limit => 100,
            engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => $adapter) },
            measures => [{id => 'count', label => 'Count', aggregate => 'count'},
                {id => 'amount', label => 'Amount', aggregate => 'sum', field => 'amount'}],
            canonical_api_path => '/api/orders', canonical_authorizer => sub { 1 },
            canonical_publication => sub { 'orders-reader-v1' },
            canonical_explorer => {clock => '2026-03-15T12:00:00Z'},
            api_console_resolver => sub { '/api/orders/console' },
            query_options => [{name => 'dataset', label => 'Dataset', default => 'current',
                choices => [[current => 'Current'], [sample => 'Sample']]}]);
        $app->plugin('Selecto::Components' => {websocket_mode => 'public', explorers => {orders => \%settings}});
        $app->routes->get('/token')->to(cb => sub { my $c = shift; $c->render(text => $c->csrf_token) });
        my $t = Test::Mojo->new($app);
        my $csrf = $t->get_ok('/token')->tx->res->text;
        $t->get_ok('/api/orders/explorer-features')->status_is(200);
        my $features = $t->tx->res->json;
        my $c = $app->build_controller;
        my $explorer = $c->selecto_components_explorer('orders');
        my %base = (q => 1, view => 'aggregate', field => 'id', group => [qw(region channel)],
            measure => [qw(count amount)], measure_alias => ['', 'total_amount'],
            filter_field => 'id', filter_op => 'gte', filter_value => '2', limit => 25, page => 1);
        my $link_request = sub {
            my ($input) = @_;
            $t->get_ok('/orders' => form => $input)->status_is(200);
            diag $t->tx->res->dom->find('.sc-error, [role=alert]')->map('all_text')->join('; ') if $t->tx->res->code != 200;
            my $link = $t->tx->res->dom->at('a[data-sc-api-console]');
            ok $link, 'aggregate renders an enabled API link' or do {
                diag $t->tx->res->dom->at('[data-sc-api-console]')->to_string;
                return undef;
            };
            my $url = Mojo::URL->new($link->{href});
            my ($encoded) = $url->fragment =~ /\Arequest=(.*)\z/;
            return decode_json(url_unescape($encoded));
        };
        my $round_trip = sub {
            my ($input, $payload) = @_;
            return unless $payload;
            $t->post_ok('/api/orders/explorer-query' => {'X-CSRF-Token' => $csrf} => json => $payload)->status_is(200);
            my $response = $t->tx->res->json;
            diag explain $response unless $response->{data};
            my $model = $explorer->model($c, $input);
            is $model->{runtime_error}, undef, 'native Explorer executes successfully';
            my @columns = @{$model->{result}{columns}};
            my @expected = map { my $row = $_; [map { $row->{$_->{key}} } @columns] }
                grep { !$_->{__selecto_rollup_continued} } @{$model->{result}{records}};
            # Subtotal ordering is fixed by the canonical route. Compare the
            # full set of visible groups/measures; paginated subtotal states
            # are disabled because their slices would differ.
            my $sort_rows = sub { [sort {
                join(qq(\x1f), map { defined($_) ? qq($_) : qq(\x00) } @$a) cmp
                join(qq(\x1f), map { defined($_) ? qq($_) : qq(\x00) } @$b)
            } @{$_[0]}] };
            is_deeply $sort_rows->($response->{data}{rows}), $sort_rows->(\@expected),
                'the exact linked envelope returns the Explorer groups and measures';
            is_deeply [map { $_->{id} } @{$response->{data}{columns} // []}],
                [@{$payload->{query}{group_by}}, 'count', 'total_amount'], 'column identities retain group order and measure aliases'
                unless grep { ref } @{$payload->{query}{group_by}};
            return $model;
        };
        my $payload = $link_request->(\%base);
        is_deeply $payload, {format => 'selecto.explorer-query', format_version => 1,
            domain => {fingerprint => $features->{domain}{fingerprint}}, features => {revision => $features->{revision}},
            query => {group_by => [qw(region channel)], select => ['region', 'channel', {aggregate => 'count', alias => 'count'},
                {aggregate => 'sum', field => 'amount', alias => 'total_amount', ignore_nulls => 'auto'}],
                filters => [{field => 'id', op => 'gte', value => 2}], row_format => 'arrays', limit => 25, offset => 0,
                ($adapter->supports('rollup') ? (rollup => Mojo::JSON::true) : ())}},
            'decoded link is the expected envelope using the route feature bindings';
        $round_trip->(\%base, $payload);
        for my $variant (
            {aggregate_grid => 1, pivot_column => 'channel'},
            {aggregate_grid => 1, pivot_column => 'channel', pivot_totals => 0},
            {filter_op => 'in', filter_values_json => '[2,3,4]'},
            {group => ['day'], group_format => ['month'], group_alias => ['period']},
            {measure => ['count'], measure_alias => [''], group => ['amount'], group_format => ['buckets'], group_bucket_ranges => ['0-20, 21+'], group_alias => ['band']},
            {measure => ['count'], measure_alias => [''], group => ['amount'], group_format => ['buckets'], group_bucket_ranges => ['*/20'], group_alias => ['band']},
            {group => ['day'], group_format => ['year_buckets'], group_bucket_ranges => ['2026'], group_alias => ['year_band']},
            {filter_field => [qw(id region)], filter_op => [qw(gte eq)], filter_value => ['2', 'East'], filter_clause => [1, 2]},
            {query_library_segment => 'at_least', query_library_param_name => 'minimum', query_library_param_value => '3'},
        ) {
            my %input = (%base, %$variant);
            my $request = $link_request->(\%input);
            $round_trip->(\%input, $request);
            if ($adapter->supports('cube') && $variant->{aggregate_grid} && !exists($variant->{pivot_totals})) {
                ok $request->{query}{cube}, 'grid hands over the actual cube';
            }
            if ($adapter->supports('grouping_sets') && exists($variant->{pivot_totals})) {
                is_deeply $request->{query}{grouping_sets}, [[0, 1], [1]], 'grid without total columns hands over the actual grouping sets';
            }
        }
        {
            $plain_groups = 1;
            my %input = (%base, limit => 2, page => 2, order => 'measure:amount', direction => 'desc');
            my $request = $link_request->(\%input);
            is $request->{query}{limit}, 2, 'plain aggregate keeps limit';
            is $request->{query}{offset}, 2, 'plain aggregate keeps page offset';
            is_deeply $request->{query}{order_by}, [{field => 'total_amount', direction => 'desc'}], 'measure ordering uses its API alias';
            $round_trip->(\%input, $request);
            $plain_groups = 0;
        }
        my %option_input = (%base, dataset => 'sample');
        $link_request->(\%option_input);
        like $t->tx->res->dom->at('a[data-sc-api-console]')->{href}, qr{\A/api/orders/console\?dataset=sample#request=},
            'query options stay on the Console URL before the request fragment';
        my $message_model = $explorer->model($c, \%base);
        my $message = Selecto::Components::Renderer->websocket_message($message_model);
        like $message->{selecto}{api_console_control}, qr{href="/api/orders/console#request=},
            'WebSocket updates carry the aggregate API link';
        for my $case (
            [{measure_alias => ['', 'Total amount']}, qr/aliases must be unique API identifiers/],
            [{group_alias => ['Area', '']}, qr/Aliases on unformatted groups/],
            [{group_format => ['text_prefix', '']}, qr/group format &#39;text_prefix&#39;/],
        ) {
            $t->get_ok('/orders' => form => {%base, %{$case->[0]}})->status_is(200)
                ->element_exists('button[data-sc-api-console][disabled]');
            like $t->tx->res->dom->at('[data-sc-api-console]')->to_string, $case->[1], 'disabled aggregate has a specific explanation';
        }
        my $config = $explorer->config;
        for my $setting ([canonical_explorer => 0], [canonical_api_path => undef]) {
            my $name = $setting->[0];
            my $old = $config->$name;
            $config->$name($setting->[1]);
            my $model = $explorer->model($c, \%base);
            like(Selecto::Components::Renderer->_api_console_control($model), qr/Canonical Explorer routes are not enabled/,
                'disabled canonical routes keep the aggregate button disabled');
            $config->$name($old);
        }
        for my $case (
            [{supports => {aggregate => 0}}, {}, qr/Aggregates are disabled/],
            [{supports => {rollup => 0}}, {}, qr/does not support rollup/],
            [{limits => {max_limit => 25}}, {limit => 30}, qr/page limit or offset exceeds/],
        ) {
            my $old = $config->canonical_explorer;
            $config->canonical_explorer({clock => '2026-03-15T12:00:00Z', %{$case->[0]}});
            my $model = $explorer->model($c, {%base, %{$case->[1]}});
            like(Selecto::Components::Renderer->_api_console_control($model), $case->[2],
                'host capabilities and limits produce an explanatory disabled button');
            $config->canonical_explorer($old);
        }
        {
            my $old = $config->canonical_authorizer;
            $config->canonical_authorizer(sub { 0 });
            my $model = $explorer->model($c, \%base);
            like(Selecto::Components::Renderer->_api_console_control($model), qr/not authorized/,
                'canonical authorization also gates the aggregate handoff');
            $config->canonical_authorizer(sub { die 'private host details' });
            $model = $explorer->model($c, \%base);
            is $model->{runtime_error}, undef, 'a failed handoff callback does not break Explorer results';
            unlike(Selecto::Components::Renderer->_api_console_control($model), qr/private host details/,
                'handoff failures do not expose host exception text');
            $config->canonical_authorizer($old);
        }
        # The optional read clock is now admitted by the canonical host.
        $t->post_ok('/api/orders/explorer-query' => {'X-CSRF-Token' => $csrf}
            => json => {%$payload, query => {%{$payload->{query}}, as_of => '2026-03-15'}})
            ->status_is(200)->json_is('/meta/as_of' => '2026-03-15');
        $dbh->disconnect;
    };
}
done_testing;

package AggregateLinkAdapter;
our ($supports, $plain);
sub supports {
    my ($self, $feature) = @_;
    return 0 if $$plain && $feature =~ /\A(?:rollup|cube|grouping_sets)\z/;
    return $supports->($self, $feature);
}
