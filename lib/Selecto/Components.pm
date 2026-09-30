package Selecto::Components;

use Mojolicious 9.49 ();
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Encode qw(encode);
use Mojo::File qw(path);
use Mojo::IOLoop ();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::WebSocket qw(WS_PING);
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use Selecto::Components::Config ();
use Selecto::Components::CannedPage ();
use Selecto::Components::Controller::Actions ();
use Selecto::Components::Controller::Explorer ();
use Selecto::Components::Controller::Lookups ();
use Selecto::Components::Controller::RecordEditor ();
use Selecto::Components::Controller::SavedQueries ();
use Selecto::Components::Explorer ();
use Selecto::Components::ExplorerSession ();
use Selecto::Components::Renderer ();
use Selecto::Components::Util qw(humanize);
use Selecto::Components::WebSocketPolicy ();

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

sub register ($self, $app, $plugin_config) {
    $plugin_config //= {};
    die "Selecto::Components plugin configuration must be an object\n"
        unless ref($plugin_config) eq 'HASH';
    my $specs = $plugin_config->{explorers} // {};
    my $page_specs = $plugin_config->{pages} // {};
    die "Selecto::Components requires explorers or pages\n"
        unless ref($specs) eq 'HASH' && ref($page_specs) eq 'HASH'
            && (keys(%$specs) || keys(%$page_specs));
    my $origin_check = $plugin_config->{origin_check}
        // \&Selecto::Components::WebSocketPolicy::same_origin;
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
            websocket_context => $plugin_config->{websocket_context},
            websocket_session_options => $plugin_config->{websocket_session_options} // {},
            lazy_view_controls => $plugin_config->{lazy_view_controls} // 0,
            %{$specs->{$id}},
            id => $id,
            path => $specs->{$id}{path} // "/explore/$id",
            title => $specs->{$id}{title} // _humanize($id),
        );
        $app->log->warn(
            "Selecto explorer $id has show_sql enabled in production mode. "
            . 'The Query Debug panel renders SQL with bound parameters, '
            . 'including tenant and scope values; disable show_sql in production.'
        ) if $config->show_sql && $app->mode eq 'production';
        my $explorer = Selecto::Components::Explorer->new(config => $config);
        $explorers{$id} = $explorer;
        _routes(
            $routes, $route_prefix, $explorer, $origin_check,
            0 + $websocket_inactivity_timeout,
            0 + $websocket_heartbeat_interval,
        );
    }
    my %pages;
    my %registered_path = map { $_->config->path => 1 } values %explorers;
    for my $id (sort keys %$page_specs) {
        my $spec = $page_specs->{$id};
        die "canned page $id configuration must be an object\n" unless ref($spec) eq 'HASH';
        my $engine_factory = $spec->{engine_factory};
        my $scope_factory = $spec->{scope_factory};
        my $path = $spec->{path} // "/pages/$id";
        die "duplicate Selecto Components route $path\n" if $registered_path{$path}++;
        my %definition = %$spec;
        delete @definition{qw(engine_factory scope_factory path title record_link websocket_enabled column_layout)};
        my $page = Selecto::CannedPage->new(%definition, id => $id);
        my $component = Selecto::Components::CannedPage->new(
            page => $page, engine_factory => $engine_factory,
            scope_factory => $scope_factory,
            path => $path, title => $spec->{title} // _humanize($id),
            record_link => $spec->{record_link},
            column_layout => $spec->{column_layout},
            websocket_enabled => exists($spec->{websocket_enabled})
                ? ($spec->{websocket_enabled} ? 1 : 0) : 1,
        );
        my $route_path = _mounted_route_path($path, $route_prefix);
        $routes->get($route_path)->to(cb => sub ($controller) { $component->handle($controller) });
        $routes->post($route_path)->to(cb => sub ($controller) { $component->handle($controller) });
        if ($component->websocket_enabled) {
            $routes->websocket($route_path . '/ws')->to(cb => sub ($controller) {
                return $controller->finish(1008 => 'WebSocket origin is not allowed')
                    unless $origin_check->($controller);
                $controller->inactivity_timeout($websocket_inactivity_timeout);
                $component->handle_websocket($controller);
            });
        }
        $pages{$id} = $component;
    }
    $app->helper(selecto_components_explorer => sub ($controller, $id) {
        die "unknown Selecto Components explorer $id\n" unless $explorers{$id};
        return $explorers{$id};
    });
    $app->helper(selecto_components_page => sub ($controller, $id) {
        die "unknown Selecto Components page $id\n" unless $pages{$id};
        return $pages{$id};
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
        my $expanded = Selecto::Components::Controller::SavedQueries::_expand_saved_query(
            $controller, $explorer,
        );
        return $expanded if $expanded;
        my $format = normalize_export_format($controller->param('format'));
        return $controller->render(text => 'Export is not allowed.', status => 403)
            if length($format) && !$config->export_allowed($controller);
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

    $routes->post($route_path . '/controls')->to(cb => sub ($controller) {
        return $controller->render(text => 'Forbidden', status => 403)
            unless $origin_check->($controller) && _csrf_valid($controller);
        return Selecto::Components::Controller::Explorer::view_controls($controller, $explorer);
    });

    $routes->get($route_path . '/actions/:selecto_action_id/form')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::Actions::form($controller, $explorer);
    });
    $routes->post($route_path . '/actions/:selecto_action_id')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::Actions::_run_action($controller, $explorer);
    });

    $routes->get($route_path . '/records/:selecto_record_id/edit')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::RecordEditor->show($controller, $explorer);
    });

    $routes->post($route_path . '/records/:selecto_record_id/edit')->to(cb => sub ($controller) {
        return Selecto::Components::Controller::RecordEditor->save($controller, $explorer);
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
        my $session = Selecto::Components::ExplorerSession->new(%{$config->websocket_session_options});
        $controller->on(finish => sub { $session->clear_results; $session->input(undef) });
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
            my ($response, $processing_error, $denied);
            my $processed = eval {
                my %input = %$envelope;
                delete $input{headers};
                my $request_id = delete $input{selecto_request_id};
                $request_id = undef
                    unless defined($request_id) && !ref($request_id)
                        && $request_id =~ /\A[a-zA-Z0-9_.:-]{1,128}\z/;
                my $patch = delete $input{selecto_session};
                my $refresh = delete $input{selecto_refresh};
                my $context = $config->websocket_context;
                my $scope = $context ? $context->($socket, $config) : 'connection';
                if (!defined($scope)) {
                    $denied = 1;
                    $session->clear_results;
                } else {
                    $session->bind_scope($scope);
                    my $state_input = $session->prepare(\%input, $patch, $refresh);
                    if (!defined($state_input)) {
                        $response = {selecto => {
                            request_id => $request_id, session => {resync => 1},
                        }};
                    } else {
                        my $model = Selecto::Components::Controller::Explorer::_decorate_model(
                            $socket, $explorer->model($socket, $state_input, {result_cache => $session}),
                        );
                        $model->{selecto_request_id} = $request_id if defined $request_id;
                        $response = Selecto::Components::Renderer->websocket_message($model);
                        my $accepted = $model->{state} && $model->{state}->valid
                            && !$model->{runtime_error} && $model->{result};
                        $session->commit($state_input) if $accepted;
                        $response->{selecto}{session} = {
                            revision => $session->revision, accepted => $accepted ? 1 : 0,
                            cache_hit => $model->{result}{cache}{hit} ? 1 : 0,
                        };
                    }
                }
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
            return $socket->finish(1008 => 'Explorer access is no longer allowed') if $denied;
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
    return $controller->csrf_token;
}

sub _csrf_valid ($controller) {
    return !$controller->validation->csrf_protect->has_error('csrf_token');
}

sub _safe_return_to ($config, $value) {
    return $config->path unless defined($value) && !ref($value) && length($value);
    my $url = Mojo::URL->new("$value");
    return $config->path if $url->is_abs || defined($url->host)
        || defined($url->userinfo) || $value =~ /[\x00-\x1f\x7f]/
        || $url->path->to_string ne $config->path;
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
    return Selecto::Components::WebSocketPolicy::same_origin($controller);
}

sub _humanize ($value) { return humanize($value); }

1;

__END__

=encoding utf8

=head1 NAME

Selecto::Components - Browser exploration UI for Selecto domains, as a Mojolicious plugin

=head1 SYNOPSIS

    use Mojolicious::Lite -signatures;
    use Selecto;

    my $domain  = Selecto::Domain->parse($contract, strict => 1);
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));

    app->secrets(['a long random secret']);

    plugin 'Selecto::Components' => {
        explorers => {
            products => {
                title          => 'Products',
                engine_factory => sub ($c) {
                    Selecto::Engine->new(domain => $domain, adapter => $adapter);
                },
                default_fields => [qw(product_name category.category_name unit_price)],
                default_group  => ['category.category_name'],
            },
        },
    };

    app->start;    # then open /explore/products

=head1 DESCRIPTION

Selecto::Components is a L<Mojolicious> plugin that adds a browser UI for
exploring data to your application. It is built on L<Selecto>. The
L<Selecto::Domain> you configure decides which tables, columns, relationships
and operations a user can reach. The browser sends only validated
query-builder state, never SQL, and Selecto compiles every query with bound
parameters.

The plugin registers two kinds of surface:

=over 4

=item Explorers

A query builder with Detail, Aggregate (optionally a two-axis grid) and Graph
views. Users choose columns, filters, groupings, measures, sorting and
pagination, and can drill down from aggregates to rows. Explorers also
provide exports, row-click actions, selected-row actions, a record editor,
saved queries and an optional Query Debug panel.

=item Canned pages

Author-defined views with promoted facet, range and text controls, built from
L<Selecto::CannedPage>. See L<Selecto::Components::CannedPage>.

=back

Pages are rendered on the server. In the default shareable mode the normalized
URL query string is the canonical state. An htmx 4 WebSocket
(C<hx-ws:connect>) is a faster transport for that same state, and ordinary GET
forms (or POST forms in private URL mode) work without JavaScript. The plugin
serves its own CSS, JavaScript, htmx 4.0.0 and Chart.js from the
distribution's share directory.

The README covers installation and integration with complete, runnable
examples. This document is the reference for the plugin's options.

=head1 PLUGIN OPTIONS

    plugin 'Selecto::Components' => {
        explorers => {...},
        pages     => {...},
        route_bridge => {routes => $under_route, prefix => '/reports'},
        origin_check => sub ($c) { ... },
        websocket_inactivity_timeout => 3600,
        websocket_heartbeat_interval => 30,
        websocket_context => sub ($c, $config) { ... },
        websocket_session_options => {ttl => 30, max_bytes => 2_097_152, max_entries => 8},
        lazy_view_controls => 0,
    };

At least one explorer or page is required. Invalid configuration dies when the
plugin is registered.

=over 4

=item explorers

A hash of explorer ID to explorer options (see L</EXPLORER OPTIONS>). IDs must
match C</\A[a-z][a-z0-9_-]*\z/>.

=item pages

A hash of page ID to canned page options (see L</CANNED PAGE OPTIONS>).

=item route_bridge

    route_bridge => {routes => $app->routes->under('/reports')->to(cb => \&auth),
                     prefix => '/reports'}

Registers every route as a child of C<routes>, which is usually an C<under>
route that authenticates the request. C<prefix> must be the bridge's path. It
must be absolute and have no trailing slash, and every explorer and page
C<path> must start with it. Paths keep their full public form in forms,
WebSocket URLs, exports and saved queries.

=item origin_check

A coderef C<($controller)> that returns true when a WebSocket handshake (and
the C<controls> POST) may proceed. The default is
L<Selecto::Components::WebSocketPolicy/same_origin>. It allows requests with no
C<Origin> header, and otherwise requires the same scheme, host and port as
the request.

=item websocket_inactivity_timeout

Seconds before an idle WebSocket closes. Default 3600, range 30 to 86400.
Choose it together with your reverse proxy's idle timeout.

=item websocket_heartbeat_interval

Seconds between protocol-level ping frames that keep idle connections visible
to proxies. Default 30. It is either 0 (disabled) or 15 to 300, and must be
less than C<websocket_inactivity_timeout>.

=item websocket_context, websocket_session_options, lazy_view_controls

Defaults for every explorer. An explorer can override each of them; see
L</EXPLORER OPTIONS>.

=back

=head1 EXPLORER OPTIONS

Each entry under C<explorers> is validated by L<Selecto::Components::Config>.

=head2 Essentials

=over 4

=item engine_factory

Required. A coderef C<($controller)> that returns a L<Selecto::Engine>. It is
called for every request, WebSocket message, export, action and lookup. This
is where the host decides the domain, database handle and trusted scope, for
example by returning an engine over
C<< $domain->with_required_predicate(...) >> for the current tenant.

=item path

The public path. Default C</explore/E<lt>idE<gt>>. It must match
C<m{\A/[A-Za-z0-9/_-]*\z}>.

=item title

The page heading. Default: the humanized ID. It can be localized through the
C<domain.title> term.

=back

=head2 Query defaults and limits

=over 4

=item views, default_view

The enabled result views, from C<detail>, C<aggregate> and C<graph>. The
default is all three, with C<detail> as the default view.

=item default_fields

The initial Detail columns, as domain field paths (or C<action:E<lt>idE<gt>>
action columns). A path outside the domain makes every request fail with a
configuration error. Default: the first six visible fields in label order.

=item default_group

The initial Aggregate and Graph groups. Default: the first visible
non-numeric field.

=item measures

Optional curated measure presets, shown next to the columns the domain
provides:

    measures => [
        {id => 'product_count', label => 'Product count', aggregate => 'count'},
        {id => 'total_price', label => 'Total price', aggregate => 'sum', field => 'unit_price'},
    ],

C<aggregate> is one of C<count count_distinct avg sum min max true_count
false_count true_percentage buckets age_buckets>. Every aggregate except
C<count> needs a C<field>. You do not have to configure measures: every
governed column can be aggregated with the functions its type allows, and a
row count is always available.

=item default_limit, max_limit

The page size (default 25) and the largest page size a user may request
(default 100, and at least C<default_limit>).

=item max_filters

1 to 20, default 20.

=item max_orders

1 to 20, default 10.

=item max_measures

1 to 20, default 10.

=item max_grid_cells

1 to 100, default 50. This bounds the row, column and cell alternatives that
one Aggregate Grid selection may submit.

=item max_grid_result_cells

100 to 100000, default 10000. A larger grid is refused with advice to add
filters or pick lower-cardinality groups.

=item max_action_rows

1 to 1000, default 1000. This is the most rows a selected-row action may
target, unless the action declares its own C<max_rows>.

=item filter_fields

Extra domain paths, typically internal keys, that may be used as filters
without becoming selectable columns.

=item default_row_click_action

The ID of a domain C<detail_actions> entry to enable on the initial view.
Users may pick another one, or none.

=item lazy_view_controls

When true, the inactive view's controls are left out of the first page and
fetched from C<POST E<lt>pathE<gt>/controls> when the user switches view. The
fetch runs no data or count query. It requires the session CSRF token and
passes C<origin_check>. Default false.

=back

=head2 Exports

Every explorer serves C<GET E<lt>pathE<gt>?E<lt>stateE<gt>&format=csv|tsv|json|xlsx>
(C<excel> is an alias for C<xlsx>). An export contains every row the current
query matches, not just the current page. CSV, TSV and JSON are streamed when
the adapter supports streaming. Excel is written to a temporary file first.
Delimited formats neutralize spreadsheet formulas. Exports are not offered in
private URL mode.

=over 4

=item export_authorizer

A coderef C<($controller, $config)>. When it returns false, the export
controls are hidden and export requests get a 403 response. Without an
authorizer, exports are allowed.

=item max_export_rows

An optional positive integer, up to 10000000, that caps every all-rows export
query. The download controls show the cap.

=back

=head2 Presentation

=over 4

=item theme_resolver

A coderef C<($controller, $config)> that returns
C<< {scheme => 'light'|'dark', primary => '#RRGGBB', secondary => '#RRGGBB', on_primary => '#RRGGBB'} >>.
Every key is optional. An empty hash keeps the stylesheet's dark palette.
The values are validated and become scoped CSS custom properties.

=item page_shell_resolver

A coderef C<($controller, $config, $model)> that returns any of:

=over 4

=item * C<head_start_html>: trusted markup placed before the component assets

=item * C<head_html>: trusted markup placed after them, for small overrides

=item * C<body_start_html>: trusted markup placed first inside C<body>

=item * C<body_class> and C<content_class>: space-separated CSS class names,
which are validated

=back

The shell applies only to full pages, not to incremental fragments. Never put
request or user input in these strings.

=item localizer

A coderef C<($key, $default, $context)> that returns the translated string.
C<$key> is a dictionary key under the domain's C<extensions.i18n.namespace>.
C<$context> includes the C<controller> and the semantic path. A return value
that is an error, a reference, an empty string or contains control characters
falls back to C<$default>. See L<Selecto::Components::I18N>.

=item api_console_resolver

A coderef C<($controller, $config, $model)> that returns a same-origin path
to an API Console, or an empty string. It adds an B<API> control that hands
the current Detail query to the console in the URL fragment. See
L<Selecto::Components::APIConsole>.

=item show_sql

Default false. When true, the Query Debug panel shows the generated data and
count SQL B<with bound parameters>, which include tenant IDs and other scope
values. B<Never enable it in production.> The plugin logs a warning at
registration if it is enabled while the application runs in C<production>
mode.

=back

=head2 Actions and editing

The domain contract declares these features. The explorer supplies the
host-owned callbacks. See L<Selecto::Components::Actions>,
L<Selecto::Components::RowActions> and L<Selecto::Components::RecordEditor>
for their contracts.

=over 4

=item action_handlers

A hash of action ID to C<sub ($controller, $request)>. An action from the
domain's C<actions> is offered only when it is bulk-enabled and has a
handler. C<$request> contains C<selected_ids>, C<inputs>, C<groups> and
(for conditional forms) C<variant>. The handler returns a hash such as
C<< {ok => 1, message => '...'} >>.

=item action_authorizer

A coderef C<($controller, {phase, action, capability, target})> that returns
C<enabled>, C<disabled> or C<hidden>, or C<< {status, reason} >>. It is
called for preview, display, execute and lookup phases. An action that
declares a C<capability> stays hidden unless an authorizer is configured.

=item choice_sources

A hash of source ID to C<sub ($controller, $action, $input)>. The callback
returns C<< [{value, label}, ...] >> for C<select> inputs that name a
C<choice_source>. Choices are resolved again when a submission arrives.

=item lookup_sources

A hash of source ID to C<sub ($controller, $request)>. The callback returns
C<< [{value, label, description}, ...] >> for C<lookup> inputs. C<$request>
holds C<query>, C<limit>, C<action>, C<input> and C<selected_ids>.

=item co_domain_engines, co_domain_scopes

For C<lookup> inputs that name a domain C<co_domains> entry.
C<co_domain_engines> maps a target domain ID to C<sub ($controller)>, which
returns that domain's L<Selecto::Engine>. C<co_domain_scopes> maps a co-domain
ID to C<sub ($controller, $request, $engine)>, which returns a narrowing
predicate (or C<< {predicate, parameters} >>).

=item action_eligibility_resolvers

A hash of action ID to C<sub ($controller, {phase, action, row_ids})>, which
returns C<< {$row_id => 0|1} >>. Use this only for rules that cannot be
expressed as a domain C<eligibility_field>.

=item action_form_resolvers

A hash of action ID to C<sub ($controller, {action, ids})>, which returns
C<< {fixed_inputs => {$input_id => $value}} >>. It narrows a declared
C<select> input to one existing choice for a single authorized row.

=item record_editor_handler

A coderef C<($controller, {engine, domain, editor, target_id, original, assignments, default_save})>
that replaces the default record-editor save. For example, it can wrap the
save in an audit or a transaction. Call C<< $request->{default_save}->() >>
to perform the governed update. It returns a hash, and
C<< close_dialog => 1 >> closes the dialog.

=back

=head2 Saved queries

=over 4

=item saved_query_store

An application object that enables the B<Saved queries> tab. This is only
possible in shareable URL mode. The minimal interface is:

    list($controller, $config)             # [{name, url}, ...]
    save($controller, $config, {name, url})
    delete($controller, $config, {name})

Stores that support several destinations and guarded edits can also
implement the following:

=over 4

=item * C<targets($controller, $config)>: returns C<< [{id, label}, ...] >>
for the destinations the user may write to.

=item * C<save_new($controller, $config, {name, url, target})>: used instead
of C<save>. It must refuse an existing name in that destination.

=item * C<update($controller, $config, {id, name, url, revision})>: must
reauthorize the item and reject a stale revision.

=item * C<list>: may return
C<< {id, name, url, scope, folder, readonly, revision} >> items.

=item * C<delete>: receives C<id> and C<revision>, and should reject a stale
delete.

=back

To reject a request with a message the user sees, die with
C<"SAVED_QUERY_CONFLICT: ...">, C<"SAVED_QUERY_STALE: ..."> (both HTTP 409),
C<"SAVED_QUERY_FORBIDDEN: ..."> or C<"SAVED_QUERY_UNSUPPORTED: ..."> (both
403). Saved URLs are validated, canonicalized and reset to page 1 before they
reach the store. New names are limited to 30 characters. The store owns user,
tenant and sharing policy. Recheck permissions in the write methods, because
destination options in HTML are not an authorization boundary.

=back

=head2 WebSocket sessions

=over 4

=item websocket_context

A coderef C<($controller, $config)> that is called for every WebSocket
message. Return C<undef> to close the socket with code 1008. Otherwise return
a string that identifies the security context, such as tenant, principal and
policy revision. A changed string discards the connection's saved form and
cached results. Without a callback, the session is scoped to the connection.
See F<docs/explorer-sessions.md> in the distribution.

=item websocket_session_options

    {ttl => 30, max_bytes => 2_097_152, max_entries => 8}

These settings bound the per-connection result cache: C<ttl> 0 to 300
seconds (0 disables caching), C<max_bytes> up to 8 MiB, and C<max_entries>
1 to 32. See L<Selecto::Components::ExplorerSession>.

=item websocket_message_cleanup

A coderef C<($controller, $config)> that runs after every WebSocket message,
including failures. Release request-scoped resources, such as leased database
handles, here. If it dies, the socket closes.

=back

=head1 CANNED PAGE OPTIONS

Each entry under C<pages> becomes a L<Selecto::Components::CannedPage> wrapping
a L<Selecto::CannedPage>. These keys belong to the plugin:

=over 4

=item engine_factory

Required. C<($controller)> returns the authorized L<Selecto::Engine>.

=item scope_factory

Optional. C<($controller, $engine)> returns a predicate that stays in every
result and facet query, including drilldowns.

=item path, title

Default C</pages/E<lt>idE<gt>> and the humanized ID.

=item record_link

C<< {field, url_prefix, target, modal_title} >>. This makes a selected detail
field link to a local record URL.

=item column_layout

Fixed detail headings, joined fields, row numbers and nested related
collections. See L<Selecto::Components::CannedPage/column_layout>.

=item websocket_enabled

Default true. Set it to 0 for a GET-only page with no WebSocket route.

=back

Every other key (C<domain>, C<dataset>, C<views>, C<controls>,
C<initial_state>, C<version>) is passed to L<Selecto::CannedPage/new>, which
rejects keys it does not know.

=head1 ROUTES

For an explorer at C<path>, the plugin registers:

    GET  path                                           page, GET fallback, exports
    POST path                                           private URL mode fallback
    WS   path/ws                                        htmx 4 incremental updates
    POST path/controls                                  lazy view controls
    GET  path/actions/:selecto_action_id/form           row-dependent action form
    POST path/actions/:selecto_action_id                run a selected-row action
    GET  path/actions/:selecto_action_id/lookups/:selecto_input_id
    GET  path/records/:selecto_record_id/edit           record editor
    POST path/records/:selecto_record_id/edit
    POST path/saved-queries
    POST path/saved-queries/delete

A canned page registers C<GET path>, C<POST path>, and C<WS path/ws> unless
C<websocket_enabled> is 0. The action, record-editor, saved-query and
C<controls> POSTs require the session's Mojolicious CSRF token, which the
rendered forms carry, so set C<< $app->secrets >>.

=head1 HELPERS

=head2 selecto_components_explorer

    my $explorer = $c->selecto_components_explorer('products');

Returns the L<Selecto::Components::Explorer> registered under that ID, for
example to build dashboard tiles with L<Selecto::Components::Dashboard>. Dies
for an unknown ID.

=head2 selecto_components_page

    my $page = $c->selecto_components_page('product_search');

Returns the L<Selecto::Components::CannedPage> registered under that ID.

=head1 FUNCTIONS

=head2 normalize_export_format

    my $format = Selecto::Components::normalize_export_format('Excel');   # 'xlsx'

Returns C<csv>, C<tsv>, C<json> or C<xlsx> for a supported format name
(case-insensitive, with C<excel> as an alias). Returns an empty string for
anything else.

=head1 URL STATE

In shareable mode the canonical query string holds the complete explorer
state. The main parameters are:

=over 4

=item * C<q=1>, which distinguishes an authored selection from the defaults,
and C<view> (C<detail>, C<aggregate> or C<graph>)

=item * repeated C<field> (in column order) with aligned C<field_alias> and
C<field_format>

=item * repeated C<group> with C<group_alias>, C<group_format>,
C<group_bucket_ranges> and C<group_prefix_length>

=item * repeated C<measure> with C<measure_function>, C<measure_alias>,
bucket and NULL-handling values

=item * aligned C<filter_field>, C<filter_op>, C<filter_value> and
C<filter_value_end>. C<filter_clause> markers group conditions: conditions in
one numbered clause are ANDed, and clauses are ORed.

=item * C<order> and C<direction>, C<limit> and C<page>

=item * C<aggregate_grid>, C<aggregate_grid_colorize>,
C<aggregate_grid_color_scale> and C<row_click_action>

=item * for domains with a query library: C<query_library_view>, repeated
C<query_library_segment>, and C<query_library_param_name> /
C<query_library_param_value> pairs

=back

The server parses every request, whether GET, POST or WebSocket, with the same
validator (L<Selecto::Components::State>). A value outside the domain or the
allowlists makes the state invalid (HTTP 422) rather than being silently
dropped. The server keeps no hidden query-builder state.

=head2 Private URL mode

Set C<< components => {query_params => 0} >> in the domain contract for
domains whose filter values are sensitive. Generated URLs then stay at the
bare path, inbound query strings redirect to it, and permalinks, export links
and saved queries are not offered. Responses are marked
C<Cache-Control: no-store>, and the no-JavaScript fallback form uses POST.
State travels only in WebSocket and POST bodies. Hosts should still use TLS
and avoid logging request bodies.

=head1 DOMAIN METADATA USED BY THE UI

Beyond fields and relationships, the UI reads these parts of the canonical
domain contract (see L<Selecto::Domain>):

=over 4

=item C<components>

C<query_params> (see above); C<filter_choices> (named single or multi-select
options for a filter path, including C<conditional> virtual filters);
C<filter_picker_hidden_paths> (paths or dotted prefixes hidden from the
filter picker but still valid in saved URLs); C<picker_visible_id_paths>
(numeric ID columns to show, which pickers otherwise hide).

=item column C<label>, C<unit>, C<behavior>

Picker labels and unit-aware aggregates.

=item column C<link>

    co_name => {type => 'string',
        link => {url_template => '/clients/view?id={{id}}', id_field => 'id'}},

This renders the Detail cell as a link. The ID field is selected as a hidden
column and left out of exports. Templates must be same-application paths
containing C<{{id}}>, and the ID is URL-encoded.

=item column C<< html_format => 'vin_last_six' >>

This bolds the last six characters of a 17-character VIN in HTML results only.

=item C<detail_actions>, C<actions>, C<editors>, C<co_domains>

Row-click actions, selected-row actions, record editors and lookup
co-domains. See L<Selecto::Components::RowActions>,
L<Selecto::Components::Actions> and L<Selecto::Components::RecordEditor>.

=item C<query_library>

Named views, segments (including C<segment_picker_groups> and
C<picker_hidden>), projections, orderings and typed parameters. They appear
in the View and Filters tabs. See L<Selecto::Components::QueryLibrary>.

=item C<joins> with C<< type => 'star_dimension' >>

Groups on the dimension key while displaying its name. Drilldowns use the
key.

=item C<extensions.i18n>

The localization namespace and terms. See L<Selecto::Components::I18N>.

=back

Filter operators depend on the field type. Text fields add
C<text_contains>, C<starts_with> and C<ends_with>, plus C<_ci>
(case-insensitive) variants; C<%> and C<_> are matched literally. Date fields
add allowlisted shortcuts such as C<today>, C<this_month>, C<qtd> and
C<last_30_days>, which resolve to bound, half-open ranges. Subtotals and
grand totals need the adapter's C<GROUP BY ROLLUP>. On adapters without it,
such as SQLite, MySQL and SQL Server, Aggregate views group plainly.

=head1 SECURITY

=over 4

=item * Every field and relationship path must resolve through the configured
domain. View names, operators, aggregate functions, formats, sort directions
and limits come from closed allowlists. Values are bound parameters. Browser
input can never select an adapter or submit SQL.

=item * Tenant and row scope come only from the host: C<engine_factory>,
C<scope_factory>, C<co_domain_engines> and C<co_domain_scopes>. Authorization
comes from the route bridge and the authorizer callbacks.

=item * Actions must be declared by the domain and registered by the host.
Targets are deduplicated and bounded. Inputs and choices are revalidated,
execution is authorized again, and POSTs require the session CSRF token.
Handlers must still check each target against the current tenant.

=item * WebSocket handshakes are subject to C<origin_check>. Frames are capped
at 128 KiB, and invalid envelopes close the socket.

=item * Raw database errors are logged but not rendered. Known
L<Selecto::Error> messages are shown. C<show_sql> discloses bound parameters
and must stay off in production.

=back

A strict Content Security Policy works unchanged:

    default-src 'self'; script-src 'self'; style-src 'self';
    connect-src 'self' ws: wss:; img-src 'self'; base-uri 'none'; frame-ancestors 'none'

=head1 OPTIONAL ADD-ONS

Native-template pages live in the separate C<Selecto-Components-Templates>
distribution, L<https://github.com/seeken/selecto-perl-components-templates>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain>, L<Selecto::CannedPage>, L<Mojolicious>,
L<Selecto::Components::Config>, L<Selecto::Components::CannedPage>,
L<Selecto::Components::Actions>, L<Selecto::Components::RowActions>,
L<Selecto::Components::RecordEditor>, L<Selecto::Components::Dashboard>,
L<Selecto::Components::APIConsole>, L<Selecto::Components::Importer>,
L<Selecto::Components::I18N>, L<Selecto::Components::ExplorerSession>,
L<Selecto::Components::WebSocketPolicy>

The vendored browser assets and their licenses are listed in
F<THIRD_PARTY_NOTICES.md>.

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
