use 5.034;
use strict;
use warnings;
use Test::More;
use Mojolicious;
use Mojo::Transaction::HTTP;
use Selecto::Components;

my $app = Mojolicious->new;
sub accepts_origin {
    my ($origin, $url, $host) = @_;
    my $tx = Mojo::Transaction::HTTP->new;
    $tx->req->url->parse($url // 'https://example.test/explore');
    $tx->req->headers->host($host // 'example.test');
    $tx->req->headers->origin($origin) if defined $origin;
    return Selecto::Components::_same_origin($app->build_controller($tx));
}

ok accepts_origin('https://example.test'), 'same HTTPS origin accepted';
ok accepts_origin('https://EXAMPLE.test:443'), 'default port and host case normalized';
ok accepts_origin(undef), 'non-browser clients without Origin remain supported';
for my $origin ('http://example.test', 'https://evil.test',
    'https://example.test:8443', 'null', 'ftp://example.test',
    'https://user@example.test', 'https://example.test/other',
    'https://example.test?other=1', 'https://example.test#fragment') {
    ok !accepts_origin($origin), "reject foreign or malformed origin $origin";
}
ok accepts_origin('http://example.test:80', 'http://example.test/explore'),
    'same HTTP origin accepted';
ok accepts_origin('https://example.test:8443',
    'https://example.test:8443/explore', 'example.test:8443'), 'matching custom port accepted';

{
    package SecurityTestConfig;
    sub path { '/explore/products' }
}
my $config = bless {}, 'SecurityTestConfig';
is Selecto::Components::_safe_return_to($config, '/explore/products?q=1'),
    '/explore/products?q=1', 'local query state preserved';
for my $url ('javascript:/explore/products', 'https:/explore/products',
    '//evil.test/explore/products', 'https://evil.test/explore/products',
    '/other', "/explore/products\n") {
    is Selecto::Components::_safe_return_to($config, $url), $config->path,
        "unsafe redirect falls back to explorer";
}
for my $prefix ('=', '+', '-', '@', "\t", "\r", "\n") {
    my $value = $prefix . '1+1';
    is Selecto::Components::Explorer::_delimited_cell($value),
        qq{"'$value"}, 'spreadsheet formula and control prefixes are neutralized';
}
for my $unsafe ("java\tscript:alert(1)", "java\nscript:alert(1)",
    "java\rscript:alert(1)", "/\\evil.test/path") {
    is(Selecto::Components::RowActions->safe_url($unsafe), undef,
        'browser-normalized unsafe row action URL rejected');
}
my $csrf_tx = Mojo::Transaction::HTTP->new;
my $csrf_controller = $app->build_controller($csrf_tx);
my $first_token = Selecto::Components::_csrf_token($csrf_controller);
my $second_token = Selecto::Components::_csrf_token($csrf_controller);
isnt $first_token, $second_token, 'CSRF responses use fresh masks';
my $session_secret = $csrf_controller->session('csrf_token');
for my $case ([$first_token, 1], [$second_token, 1], ['0' x 80, 0], ['', 0], [$session_secret, 0]) {
    my $tx = Mojo::Transaction::HTTP->new;
    $tx->req->params->param(csrf_token => $case->[0]);
    my $controller = $app->build_controller($tx);
    $controller->session(csrf_token => $session_secret);
    is !!Selecto::Components::_csrf_valid($controller), !!$case->[1],
        'CSRF validates masked tokens and rejects raw, missing, and forged tokens';
}
my $other_tx = Mojo::Transaction::HTTP->new;
my $other_session = $app->build_controller($other_tx);
Selecto::Components::_csrf_token($other_session);
$other_session->req->params->param(csrf_token => $first_token);
ok !Selecto::Components::_csrf_valid($other_session), 'CSRF token cannot cross sessions';

# show_sql renders bound parameters (tenant IDs included): warn in production.
{
    require lib;
    lib->import('t/lib');
    require TestSelectoComponents;
    my $show_sql_warnings = sub {
        my ($mode, $show_sql) = @_;
        my $show_app = Mojolicious->new(mode => $mode);
        $show_app->secrets(['show-sql-test']);
        my @messages;
        $show_app->log->level('trace');
        $show_app->log->unsubscribe('message');
        $show_app->log->on(message => sub {
            my ($log, $level, @lines) = @_;
            push @messages, [$level, join(' ', @lines)];
        });
        my $config = TestSelectoComponents::config();
        $config->{show_sql} = $show_sql;
        $show_app->plugin('Selecto::Components' => {explorers => {products => $config}});
        return [grep { $_->[0] eq 'warn' && $_->[1] =~ /show_sql/ } @messages];
    };
    my $production = $show_sql_warnings->('production', 1);
    is scalar(@$production), 1, 'show_sql in production logs one warning';
    like $production->[0][1], qr/bound parameters, including tenant and scope values/,
        'the warning explains that bound tenant values are disclosed';
    is scalar(@{$show_sql_warnings->('development', 1)}), 0,
        'show_sql in development does not warn';
    is scalar(@{$show_sql_warnings->('production', 0)}), 0,
        'production without show_sql does not warn';
}
done_testing;
