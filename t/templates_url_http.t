use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Mojolicious;
use Test::More;
use Test::Mojo;
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Templates ();

my $fixtures = "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates";
my %manifest;
my %registry;
my %callback_calls;

for my $kind (qw(element component)) {
    my $source = $kind eq 'element'
        ? 'render-safe-link.valid.selecto'
        : 'render-link-component.valid.selecto';
    my $caps = _json("$fixtures/capabilities.json");
    if ($kind eq 'element') {
        $caps->{renderer}{elements}{a} = {
            attributes => {href => 'string'}, children => JSON::PP::true,
        };
        $registry{$kind} = {elements => {a => sub {
            my ($node) = @_;
            ++$callback_calls{$kind};
            return Selecto::Components::Templates::Renderer->safe_html(
                '<a href="' . html_escape($node->{attributes}{href}) . '">' .
                $node->{children} . '</a>',
            );
        }}};
    }
    else {
        $caps->{renderer}{components}{Link} = {
            props => {destination => 'string'},
            required_props => ['destination'],
            events => {}, children => JSON::PP::true,
        };
        $registry{$kind} = {
            components => {Link => sub {
                my ($node) = @_;
                ++$callback_calls{$kind};
                return Selecto::Components::Templates::Renderer->safe_html(
                    '<a href="' . html_escape($node->{props}{destination}) . '">' .
                    $node->{children} . '</a>',
                );
            }},
            url_props => {Link => {destination => 'href'}},
        };
    }
    $manifest{$kind} = Selecto::Templates->compile(
        Selecto::Templates->parse(_read("$fixtures/$source")),
        domains => {}, capabilities => $caps,
    );
}

my $app = Mojolicious->new;
$app->routes->get('/url-template/:kind')->to(cb => sub {
    my ($controller) = @_;
    my $kind = $controller->stash('kind');
    return $controller->render(status => 404, text => 'Not found')
        unless exists $manifest{$kind};
    $controller->res->headers->cache_control('no-store, private');
    my $mounted = Selecto::Templates->mount_runtime(
        $manifest{$kind},
        instance_id => "url-http-$kind", release_id => 'url-http-v1',
        inputs => {target => $controller->param('target') // ''},
    );
    my $html;
    my $ok = eval {
        $html = Selecto::Components::Templates::Renderer->render(
            manifest => $manifest{$kind},
            snapshot => $mounted->{snapshot},
            registry => $registry{$kind},
        );
        1;
    };
    return $controller->render(
        status => 422,
        text => '<main data-selecto-template-error="invalid_url_attribute">Template unavailable.</main>',
        format => 'html',
    ) if !$ok && $@ =~ /\Ainvalid_url_attribute:/;
    die $@ unless $ok;
    return $controller->render(
        text => '<main id="url-template-host">' . $html . '</main>',
        format => 'html',
    );
});

my $t = Test::Mojo->new($app);
for my $kind (qw(element component)) {
    my $safe = '/url-template/' . $kind .
        '?target=%2Forders%2F42%3Ftab%3Da%26next%3Db';
    $t->get_ok($safe)
        ->status_is(200)
        ->header_is('Cache-Control' => 'no-store, private')
        ->element_exists('#url-template-host a[href="/orders/42?tab=a&next=b"]');
    like $t->tx->res->body, qr/href="\/orders\/42\?tab=a&amp;next=b"/,
        "$kind URL is HTML-escaped in the connected response";
    is $callback_calls{$kind}, 1, "$kind safe link invokes its host callback";

    $t->get_ok('/url-template/' . $kind . '?target=javascript%3Aalert%281%29')
        ->status_is(422)
        ->header_is('Cache-Control' => 'no-store, private')
        ->element_exists('[data-selecto-template-error="invalid_url_attribute"]')
        ->element_exists_not('a');
    is $callback_calls{$kind}, 1,
        "$kind unsafe link is rejected before its host callback";
}

done_testing;

sub _read {
    my ($path) = @_;
    open my $handle, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$handle>;
}

sub _json {
    return JSON::PP->new->utf8->decode(_read($_[0]));
}
