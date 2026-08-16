package Selecto::Components;

use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Encode qw(encode);
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL ();
use Selecto::Components::Config ();
use Selecto::Components::Explorer ();
use Selecto::Components::Renderer ();

our $VERSION = '0.1.0';

=head1 NAME

Selecto::Components - htmx WebSocket exploration UI for Selecto Perl

=head1 DESCRIPTION

This Mojolicious plugin provides server-rendered Detail, Aggregate, and Graph
exploration surfaces. The normalized URL query string is canonical state;
htmx 4 WebSockets are an incremental transport for the same governed query.

=cut

sub register ($self, $app, $plugin_config) {
    $plugin_config //= {};
    die "Selecto::Components plugin configuration must be an object\n"
        unless ref($plugin_config) eq 'HASH';
    my $specs = $plugin_config->{explorers};
    die "Selecto::Components requires an explorers object\n"
        unless ref($specs) eq 'HASH' && keys %$specs;
    my $origin_check = $plugin_config->{origin_check} // \&_same_origin;
    die "origin_check must be a coderef\n" unless ref($origin_check) eq 'CODE';

    my $module_lib = path(__FILE__)->to_abs->dirname->dirname;
    my @public_candidates = (
        $module_lib->dirname->child('public'),
        $module_lib->child('auto', 'share', 'dist', 'Selecto-Components', 'public'),
    );
    my ($public_path) = grep { -d $_ } @public_candidates;
    die "Selecto::Components packaged browser assets were not found\n" unless $public_path;
    unshift @{$app->static->paths}, $public_path->to_string;

    my %explorers;
    for my $id (sort keys %$specs) {
        die "explorer $id configuration must be an object\n" unless ref($specs->{$id}) eq 'HASH';
        my $config = Selecto::Components::Config->new(
            %{$specs->{$id}},
            id => $id,
            path => $specs->{$id}{path} // "/explore/$id",
            title => $specs->{$id}{title} // _humanize($id),
        );
        my $explorer = Selecto::Components::Explorer->new(config => $config);
        $explorers{$id} = $explorer;
        _routes($app, $explorer, $origin_check);
    }
    $app->helper(selecto_components_explorer => sub ($controller, $id) {
        die "unknown Selecto Components explorer $id\n" unless $explorers{$id};
        return $explorers{$id};
    });
    return $self;
}

sub _routes ($app, $explorer, $origin_check) {
    my $config = $explorer->config;
    my $routes = $app->routes;
    $routes->get($config->path)->to(cb => sub ($controller) {
        my $model = $explorer->model($controller);
        if (($controller->param('format') // '') eq 'csv') {
            return _render_csv($controller, $explorer, $model);
        }
        my $status = $model->{runtime_error} || !$model->{state} || !$model->{state}->valid ? 422 : 200;
        return $controller->render(
            data => encode('UTF-8', Selecto::Components::Renderer->page($model)),
            format => 'html',
            status => $status,
        );
    });

    $routes->websocket($config->path . '/ws')->to(cb => sub ($controller) {
        unless ($origin_check->($controller)) {
            return $controller->finish(1008 => 'WebSocket origin is not allowed');
        }
        $controller->inactivity_timeout(300);
        $controller->on(message => sub ($socket, $message) {
            return $socket->finish(1009 => 'WebSocket message is too large')
                if !defined($message) || length($message) > 131_072;
            my $envelope;
            my $ok = eval { $envelope = decode_json($message); 1 };
            return $socket->finish(1003 => 'Expected a JSON message')
                unless $ok && ref($envelope) eq 'HASH' && ref($envelope->{body}) eq 'HASH';
            my $headers = ref($envelope->{headers}) eq 'HASH' ? $envelope->{headers} : {};
            my $request_id = $headers->{'HX-Request-ID'};
            $request_id = undef unless defined($request_id) && !ref($request_id)
                && "$request_id" =~ /\A[A-Za-z0-9-]{1,100}\z/;
            my $model = $explorer->model($socket, $envelope->{body});
            my $response = Selecto::Components::Renderer->websocket_message($model, $request_id);
            return $socket->send({text => encode_json($response)});
        });
    });
}

sub _render_csv ($controller, $explorer, $model) {
    if ($model->{runtime_error} || !$model->{state} || !$model->{state}->valid || !$model->{result}) {
        return $controller->render(
            data => encode('UTF-8', Selecto::Components::Renderer->page($model)),
            format => 'html',
            status => 422,
        );
    }
    my $filename = $model->{config}->id . '-page-' . $model->{state}->page . '.csv';
    $controller->res->headers->content_disposition(qq{attachment; filename="$filename"});
    $controller->res->headers->content_type('text/csv; charset=UTF-8');
    return $controller->render(
        data => encode('UTF-8', $explorer->csv($model)),
        status => 200,
    );
}

sub _same_origin ($controller) {
    my $origin = $controller->req->headers->origin;
    return 1 unless defined($origin) && length($origin);
    my $origin_url = Mojo::URL->new($origin);
    return 0 unless defined($origin_url->host) && length($origin_url->host);
    my $origin_host = lc($origin_url->host_port // '');
    my $request_host = lc($controller->req->headers->host // '');
    return $origin_host eq $request_host ? 1 : 0;
}

sub _humanize ($value) {
    my $text = "$value";
    $text =~ s/[_-]+/ /g;
    $text =~ s/\b([a-z])/uc($1)/eg;
    return $text;
}

1;
