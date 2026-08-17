package Selecto::Components;

use Digest::SHA qw(sha256_hex);
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Encode qw(encode);
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL ();
use Mojo::Util qw(secure_compare);
use Selecto::Components::Actions ();
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
Domains may disable query-parameter state for sensitive explorers.

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
        my $model = _decorate_model($controller, $explorer->model($controller));
        if (!$config->query_params_enabled($model->{domain})
            && length($controller->req->url->query->to_string)) {
            return $controller->redirect_to($config->path);
        }
        if ($config->query_params_enabled($model->{domain})
            && ($controller->param('format') // '') eq 'csv') {
            return _render_csv($controller, $explorer, $model);
        }
        return _render_page($controller, $model);
    });

    $routes->post($config->path)->to(cb => sub ($controller) {
        my $model = _decorate_model(
            $controller,
            $explorer->model($controller, $explorer->input_from_controller($controller)),
        );
        return _render_page($controller, $model);
    });

    $routes->post($config->path . '/actions/:selecto_action_id')->to(cb => sub ($controller) {
        return _run_action($controller, $explorer);
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
            my $model = _decorate_model($socket, $explorer->model($socket, $envelope->{body}));
            my $response = Selecto::Components::Renderer->websocket_message($model, $request_id);
            return $socket->send({text => encode_json($response)});
        });
    });
}

sub _decorate_model ($controller, $model) {
    $model->{csrf_token} = _csrf_token($controller);
    $model->{action_notice} = $controller->flash('selecto_action_notice');
    $model->{action_error} = $controller->flash('selecto_action_error');
    $model->{available_actions} = [];
    $model->{bulk_actions} = [];
    if ($model->{domain} && $model->{state} && $model->{state}->valid
        && $model->{state}->view eq 'detail') {
        my $ok = eval {
            $model->{available_actions} = Selecto::Components::Actions->available(
                $model->{config}, $model->{domain}, $controller,
            );
            my %selected = map {
                my $id = $model->{config}->action_id_from_column($_);
                defined($id) ? ($id => 1) : ()
            } @{$model->{state}->fields};
            $model->{bulk_actions} = [grep {
                $selected{$_->{id}}
            } @{$model->{available_actions}}];
            1;
        };
        unless ($ok) {
            $controller->app->log->error("Selecto action discovery failed: $@");
            $model->{available_actions} = [];
            $model->{bulk_actions} = [];
        }
    }
    return $model;
}

sub _run_action ($controller, $explorer) {
    my $config = $explorer->config;
    my $return_to = _safe_return_to($config, scalar $controller->param('return_to'));
    my $submitted_token = $controller->param('csrf_token') // '';
    my $expected_token = $controller->session('selecto_components_csrf') // '';
    return _action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => 'The action form expired. Reload the explorer and try again.',
    }) unless length($submitted_token) && length($expected_token)
        && secure_compare("$submitted_token", "$expected_token");

    my $selected_values = $controller->every_param('selected_id');
    my @selected_ids = ref($selected_values) eq 'ARRAY' ? @$selected_values : ();
    my $action_id = $controller->stash('selecto_action_id') // '';
    my ($domain, $resolved);
    my $discovery_ok = eval {
        $domain = $config->engine($controller)->domain;
        $resolved = Selecto::Components::Actions->find(
            $config, $domain, $controller, $action_id, 'preview', {ids => \@selected_ids},
        );
        1;
    };
    unless ($discovery_ok) {
        $controller->app->log->error("Selecto action lookup failed: $@");
        return _action_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The action could not be prepared.',
        });
    }
    return _action_response($controller, $return_to, {
        ok => 0, status => 404, message => 'That action is not available.',
    }) unless $resolved;
    return _action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => $resolved->{decision}{reason} || 'That action is not permitted.',
    }) unless $resolved->{decision}{status} eq 'enabled';

    my %raw_inputs = map {
        $_->{id} => scalar $controller->param('action_input_' . $_->{id})
    } @{$resolved->{action}{inputs}};
    my $request = Selecto::Components::Actions->request(
        $config, $resolved->{action}, \@selected_ids, \%raw_inputs,
    );
    return _action_response($controller, $return_to, {
        ok => 0, status => 422, message => join(' ', @{$request->{errors}}),
        errors => $request->{errors},
    }) unless $request->{valid};

    my $execute_decision = Selecto::Components::Actions->authorize(
        $config, $controller, $resolved->{action}, 'execute', {
            ids => $request->{selected_ids}, inputs => $request->{inputs},
        },
    );
    return _action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => $execute_decision->{reason} || 'That action is not permitted.',
    }) unless $execute_decision->{status} eq 'enabled';

    my $handler = $config->action_handler($action_id);
    my $result;
    my $execute_ok = eval { $result = $handler->($controller, $request); 1 };
    unless ($execute_ok) {
        $controller->app->log->error("Selecto action $action_id failed: $@");
        return _action_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The action could not be completed.',
        });
    }
    unless (ref($result) eq 'HASH') {
        $controller->app->log->error("Selecto action $action_id returned an invalid result");
        return _action_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The action returned an invalid result.',
        });
    }
    $result->{ok} = 1 unless exists $result->{ok};
    $result->{status} = $result->{ok} ? 200 : 422 unless defined $result->{status};
    $result->{message} //= $result->{ok}
        ? 'The action was completed.' : 'The action was not completed.';
    return _action_response($controller, $return_to, $result);
}

sub _action_response ($controller, $return_to, $result) {
    my $status = $result->{status} // ($result->{ok} ? 200 : 422);
    if (($controller->req->headers->accept // '') =~ m{application/json}i
        || ($controller->req->headers->header('X-Requested-With') // '') eq 'XMLHttpRequest') {
        return $controller->render(json => $result, status => $status);
    }
    $controller->flash(
        $result->{ok} ? 'selecto_action_notice' : 'selecto_action_error',
        $result->{message},
    );
    return $controller->redirect_to($return_to);
}

sub _csrf_token ($controller) {
    my $token = $controller->session('selecto_components_csrf');
    return $token if defined($token) && !ref($token) && "$token" =~ /\A[0-9a-f]{64}\z/;
    my $secret = $controller->app->secrets->[0] // 'selecto-components';
    $token = sha256_hex(join(':', $secret, $$, time, rand(), $controller->stash('request_id') // ''));
    $controller->session(selecto_components_csrf => $token);
    return $token;
}

sub _safe_return_to ($config, $value) {
    return $config->path unless defined($value) && !ref($value) && length($value);
    my $url = Mojo::URL->new("$value");
    return $config->path if defined($url->host) || $url->path->to_string ne $config->path;
    return $url->to_string;
}

sub _render_page ($controller, $model) {
    if ($model->{domain} && !$model->{config}->query_params_enabled($model->{domain})) {
        $controller->res->headers->cache_control('no-store');
    }
    my $status = $model->{runtime_error} || !$model->{state} || !$model->{state}->valid ? 422 : 200;
    return $controller->render(
        data => encode('UTF-8', Selecto::Components::Renderer->page($model)),
        format => 'html',
        status => $status,
    );
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
