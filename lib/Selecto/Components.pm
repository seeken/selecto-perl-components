package Selecto::Components;

use Digest::SHA qw(sha256_hex);
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Encode qw(encode);
use Mojo::File qw(path);
use Mojo::IOLoop ();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL ();
use Mojo::WebSocket qw(WS_PING);
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use Selecto::Components::Config ();
use Selecto::Components::Controller::Actions ();
use Selecto::Components::Controller::Explorer ();
use Selecto::Components::Controller::Lookups ();
use Selecto::Components::Controller::SavedQueries ();
use Selecto::Components::Explorer ();
use Selecto::Components::Renderer ();
use Selecto::Components::Util qw(humanize);

our $VERSION = '0.1.0';

my %EXPORT_FORMATS = (
    csv => {
        extension => 'csv',
        content_type => 'text/csv; charset=UTF-8',
        utf8 => 1,
    },
    tsv => {
        extension => 'tsv',
        content_type => 'text/tab-separated-values; charset=UTF-8',
        utf8 => 1,
    },
    json => {
        extension => 'json',
        content_type => 'application/json; charset=UTF-8',
        utf8 => 1,
    },
    xlsx => {
        extension => 'xlsx',
        content_type => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        utf8 => 0,
    },
);

sub normalize_export_format ($value) {
    return '' if !defined($value) || ref($value);
    my $format = lc "$value";
    $format = 'xlsx' if $format eq 'excel';
    return exists($EXPORT_FORMATS{$format}) ? $format : '';
}

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
    my ($routes, $route_prefix) = _route_bridge($app, $plugin_config->{route_bridge});
    my $websocket_inactivity_timeout
        = $plugin_config->{websocket_inactivity_timeout} // 3600;
    die "websocket_inactivity_timeout must be an integer between 30 and 86400 seconds\n"
        unless defined($websocket_inactivity_timeout)
            && !ref($websocket_inactivity_timeout)
            && "$websocket_inactivity_timeout" =~ /\A\d+\z/
            && $websocket_inactivity_timeout >= 30
            && $websocket_inactivity_timeout <= 86_400;
    my $websocket_heartbeat_interval
        = $plugin_config->{websocket_heartbeat_interval} // 30;
    die "websocket_heartbeat_interval must be 0 or an integer between 15 and 300 seconds\n"
        unless defined($websocket_heartbeat_interval)
            && !ref($websocket_heartbeat_interval)
            && "$websocket_heartbeat_interval" =~ /\A\d+\z/
            && ($websocket_heartbeat_interval == 0
                || $websocket_heartbeat_interval >= 15
                    && $websocket_heartbeat_interval <= 300);
    die "websocket_heartbeat_interval must be less than websocket_inactivity_timeout\n"
        if $websocket_heartbeat_interval
            && $websocket_heartbeat_interval >= $websocket_inactivity_timeout;

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
        _routes(
            $routes, $route_prefix, $explorer, $origin_check,
            0 + $websocket_inactivity_timeout,
            0 + $websocket_heartbeat_interval,
        );
    }
    $app->helper(selecto_components_explorer => sub ($controller, $id) {
        die "unknown Selecto Components explorer $id\n" unless $explorers{$id};
        return $explorers{$id};
    });
    return $self;
}

sub _routes (
    $routes, $route_prefix, $explorer, $origin_check,
    $websocket_inactivity_timeout, $websocket_heartbeat_interval,
) {
    my $config = $explorer->config;
    my $route_path = _mounted_route_path($config->path, $route_prefix);
    $routes->get($route_path)->to(cb => sub ($controller) {
        my $format = normalize_export_format($controller->param('format'));
        if ($format eq 'xlsx') {
            my ($file_export, $error);
            eval { $file_export = $explorer->xlsx_file_export($controller); 1 }
                or $error = $@ || 'Excel export preparation failed';
            return _render_export_preparation_error($controller, $error) if $error;
            return _render_file_export($controller, $file_export, $format)
                if $file_export;
        }
        if ($EXPORT_FORMATS{$format} && $format ne 'xlsx') {
            my ($stream_export, $error);
            eval { $stream_export = $explorer->stream_export($controller, $format); 1 }
                or $error = $@ || 'streaming export preparation failed';
            return _render_export_preparation_error($controller, $error) if $error;
            return _render_stream_export($controller, $stream_export, $format)
                if $stream_export;
        }
        my $model = Selecto::Components::Controller::Explorer::_decorate_model($controller, $explorer->model(
            $controller, undef, {all_rows => $EXPORT_FORMATS{$format} ? 1 : 0},
        ));
        if (!$config->query_params_enabled($model->{domain})
            && length($controller->req->url->query->to_string)) {
            return $controller->redirect_to($config->path);
        }
        if ($config->query_params_enabled($model->{domain}) && $EXPORT_FORMATS{$format}) {
            return _render_export($controller, $explorer, $model, $format);
        }
        return _render_page($controller, $model);
    });

    $routes->post($route_path)->to(cb => sub ($controller) {
        my $model = Selecto::Components::Controller::Explorer::_decorate_model(
            $controller,
            $explorer->model($controller, $explorer->input_from_controller($controller)),
        );
        return _render_page($controller, $model);
    });

    $routes->post($route_path . '/actions/:selecto_action_id')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::Actions::_run_action($controller, $explorer);
    });

    $routes->get(
        $route_path . '/actions/:selecto_action_id/lookups/:selecto_input_id'
    )->to(cb => sub ($controller) {
        return Selecto::Components::Controller::Lookups::_run_action_lookup($controller, $explorer);
    });

    $routes->post($route_path . '/saved-queries')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::SavedQueries::_save_query($controller, $explorer);
    });

    $routes->post($route_path . '/saved-queries/delete')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::SavedQueries::_delete_saved_query($controller, $explorer);
    });

    $routes->websocket($route_path . '/ws')->to(cb => sub ($controller) {
        unless ($origin_check->($controller)) {
            return $controller->finish(1008 => 'WebSocket origin is not allowed');
        }
        $controller->inactivity_timeout($websocket_inactivity_timeout);
        if ($websocket_heartbeat_interval) {
            my $heartbeat_id;
            $heartbeat_id = Mojo::IOLoop->recurring(
                $websocket_heartbeat_interval => sub {
                    my $tx = $controller->tx;
                    return Mojo::IOLoop->remove($heartbeat_id)
                        unless $tx && $tx->is_websocket && $tx->established;
                    $controller->send([1, 0, 0, 0, WS_PING, '']);
                },
            );
            $controller->on(finish => sub {
                Mojo::IOLoop->remove($heartbeat_id) if defined $heartbeat_id;
            });
        }
        $controller->on(message => sub ($socket, $message) {
            return $socket->finish(1009 => 'WebSocket message is too large')
                if !defined($message) || length($message) > 131_072;
            my $envelope;
            my $ok = eval { $envelope = decode_json($message); 1 };
            return $socket->finish(1003 => 'Expected a JSON message')
                unless $ok && ref($envelope) eq 'HASH' && ref($envelope->{headers}) eq 'HASH';
            my ($response, $processing_error);
            my $processed = eval {
                my %input = %$envelope;
                delete $input{headers};
                my $model = Selecto::Components::Controller::Explorer::_decorate_model($socket, $explorer->model($socket, \%input));
                $response = Selecto::Components::Renderer->websocket_message($model);
                1;
            };
            $processing_error = $@ unless $processed;

            my $cleanup_error;
            if (my $cleanup = $config->websocket_message_cleanup) {
                my $cleaned = eval { $cleanup->($socket, $config); 1 };
                $cleanup_error = $@ unless $cleaned;
            }

            if (!$processed || $cleanup_error) {
                my $error = $processing_error || $cleanup_error || 'unknown WebSocket error';
                $error =~ s/\s+\z//;
                $socket->app->log->error("Selecto WebSocket message failed: $error");
                return $socket->finish(1011 => 'Explorer request could not be completed');
            }
            return $socket->send({text => encode_json($response)});
        });
    });
}

sub _route_bridge ($app, $bridge) {
    return ($app->routes, '') unless defined $bridge;
    die "route_bridge must be an object with routes and prefix\n"
        unless ref($bridge) eq 'HASH';
    my $routes = $bridge->{routes};
    die "route_bridge routes must be a Mojolicious route object\n"
        unless blessed($routes)
            && $routes->can('get') && $routes->can('post') && $routes->can('websocket');
    my $prefix = $bridge->{prefix} // '';
    die "route_bridge prefix must be an absolute path without a trailing slash\n"
        unless !ref($prefix) && "$prefix" =~ m{\A(?:|/[A-Za-z0-9/_-]*[A-Za-z0-9_-])\z};
    return ($routes, "$prefix");
}

sub _mounted_route_path ($path, $prefix) {
    return $path unless length $prefix;
    die "explorer path $path is outside route_bridge prefix $prefix\n"
        unless $path eq $prefix || index($path, "$prefix/") == 0;
    my $relative = substr($path, length($prefix));
    return length($relative) ? $relative : '/';
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
    my $render_started = time;
    my $html = encode('UTF-8', Selecto::Components::Renderer->page($model));
    my $render_ms = int((time - $render_started) * 1000 + 0.5);
    my $stats = ref($model->{result}) eq 'HASH'
        && ref($model->{result}{debug}) eq 'HASH'
        ? $model->{result}{debug}{stats} : {};
    my @timings = ('selecto_render;dur=' . $render_ms);
    push @timings, 'selecto_model;dur=' . (0 + $stats->{model_ms})
        if defined($stats->{model_ms});
    push @timings, 'selecto_data;dur=' . (0 + $stats->{data_query_ms})
        if defined($stats->{data_query_ms});
    push @timings, 'selecto_count;dur=' . (0 + $stats->{count_query_ms})
        if defined($stats->{count_query_ms});
    $controller->res->headers->header('Server-Timing' => join(', ', @timings));
    return $controller->render(
        data => $html,
        format => 'html',
        status => $status,
    );
}

sub _render_export ($controller, $explorer, $model, $format) {
    if ($model->{runtime_error} || !$model->{state} || !$model->{state}->valid || !$model->{result}) {
        return $controller->render(
            data => encode('UTF-8', Selecto::Components::Renderer->page($model)),
            format => 'html',
            status => 422,
        );
    }
    my $export = $EXPORT_FORMATS{$format};
    my $filename = $model->{config}->id . '-export.' . $export->{extension};
    $controller->res->headers->cache_control('no-store');
    $controller->res->headers->content_disposition(qq{attachment; filename="$filename"});
    $controller->res->headers->content_type($export->{content_type});
    my $data = $explorer->export($model, $format);
    return $controller->render(
        data => $export->{utf8} ? encode('UTF-8', $data) : $data,
        status => 200,
    );
}

sub _render_stream_export ($controller, $export, $format) {
    my $metadata = $EXPORT_FORMATS{$format};
    my $filename = $export->{config}->id . '-export.' . $metadata->{extension};
    $controller->res->headers->cache_control('no-store');
    $controller->res->headers->content_disposition(qq{attachment; filename="$filename"});
    $controller->res->headers->content_type($metadata->{content_type});
    $controller->on(finish => sub {
        eval { $export->{close}->() } if $export->{close};
    });
    $controller->render_later;
    my $write_next;
    $write_next = sub {
        my $chunk;
        my $ok = eval { $chunk = $export->{next_chunk}->(); 1 };
        unless ($ok) {
            my $error = $@ || 'streaming export failed';
            $error =~ s/\s+\z//;
            $controller->app->log->error("Selecto streaming export failed: $error");
            eval { $export->{close}->() } if $export->{close};
            return $controller->write('');
        }
        unless (defined $chunk) {
            eval { $export->{close}->() } if $export->{close};
            return $controller->write('');
        }
        $chunk = encode('UTF-8', $chunk) if $metadata->{utf8};
        return $controller->write($chunk => sub { $write_next->() });
    };
    $write_next->();
    return undef;
}

sub _render_file_export ($controller, $export, $format) {
    my $metadata = $EXPORT_FORMATS{$format};
    my $filename = $export->{config}->id . '-export.' . $metadata->{extension};
    $controller->res->headers->cache_control('no-store');
    $controller->res->headers->content_disposition(qq{attachment; filename="$filename"});
    $controller->res->headers->content_type($metadata->{content_type});
    my $path = $export->{path};
    $controller->on(finish => sub { unlink $path if defined($path) && -f $path });
    return $controller->reply->file($path);
}

sub _render_export_preparation_error ($controller, $error) {
    $error //= 'export preparation failed';
    $error =~ s/\s+\z//;
    $controller->app->log->error("Selecto export failed: $error");
    return $controller->render(
        text => "The export could not be prepared. Please review the query and try again.\n",
        status => 422,
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

sub _humanize ($value) { return humanize($value); }

1;
