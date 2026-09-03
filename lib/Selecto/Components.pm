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
use Selecto::Components::State ();
use Selecto::Components::Util qw(humanize);
use Selecto::CoDomain ();

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
        my $format = normalize_export_format($controller->param('format'));
        my $model = _decorate_model($controller, $explorer->model(
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

    $routes->get(
        $config->path . '/actions/:selecto_action_id/lookups/:selecto_input_id'
    )->to(cb => sub ($controller) {
        return _run_action_lookup($controller, $explorer);
    });

    $routes->post($config->path . '/saved-queries')->to(cb => sub ($controller) {
        return _save_query($controller, $explorer);
    });

    $routes->post($config->path . '/saved-queries/delete')->to(cb => sub ($controller) {
        return _delete_saved_query($controller, $explorer);
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
                unless $ok && ref($envelope) eq 'HASH' && ref($envelope->{headers}) eq 'HASH';
            my %input = %$envelope;
            delete $input{headers};
            my $model = _decorate_model($socket, $explorer->model($socket, \%input));
            my $response = Selecto::Components::Renderer->websocket_message($model);
            return $socket->send({text => encode_json($response)});
        });
    });
}

sub _decorate_model ($controller, $model) {
    $model->{csrf_token} = _csrf_token($controller);
    $model->{action_notice} = $controller->flash('selecto_action_notice');
    $model->{action_error} = $controller->flash('selecto_action_error');
    $model->{saved_query_notice} = $controller->flash('selecto_saved_query_notice');
    $model->{saved_query_error} = $controller->flash('selecto_saved_query_error');
    $model->{saved_queries} = [];
    if ($model->{domain} && $model->{config}->saved_queries_enabled($model->{domain})) {
        my $ok = eval {
            my $queries = $model->{config}->saved_query_store->list(
                $controller, $model->{config},
            );
            die "saved query store returned an invalid list\n" unless ref($queries) eq 'ARRAY';
            $model->{saved_queries} = _normalize_saved_queries($model->{config}, $queries);
            1;
        };
        unless ($ok) {
            $controller->app->log->error("Selecto saved query listing failed: $@");
            $model->{saved_query_error} //= 'Saved queries could not be loaded.';
        }
    }
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
            _apply_action_row_eligibility($controller, $model);
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

sub _apply_action_row_eligibility ($controller, $model) {
    my $result = $model->{result};
    return unless ref($result) eq 'HASH' && ref($result->{records}) eq 'ARRAY';
    return if $result->{all_rows};
    my $target_key = $result->{action_key};
    return unless defined($target_key) && !ref($target_key) && length($target_key);

    for my $action (@{$model->{bulk_actions} // []}) {
        next unless ref($action) eq 'HASH' && ref($action->{selection}) eq 'HASH';
        my $field = $action->{selection}{eligibility_field};
        next unless defined($field) && !ref($field)
            && "$field" =~ /\A__[a-z][a-z0-9_]*\z/;

        $_->{$field} = 0 for @{$result->{records}};
        my $resolver = $model->{config}->action_eligibility_resolver($action->{id});
        unless ($resolver) {
            $controller->app->log->error(
                "Selecto action $action->{id} declares $field without an eligibility resolver",
            );
            next;
        }

        my (%seen, @row_ids);
        for my $record (@{$result->{records}}) {
            next unless ref($record) eq 'HASH';
            my $id = $record->{$target_key};
            next unless defined($id) && !ref($id) && "$id" ne '' && !$seen{"$id"}++;
            push @row_ids, "$id";
        }
        next unless @row_ids;

        my $eligible;
        my $ok = eval {
            $eligible = $resolver->($controller, {
                phase => 'display', action => $action, row_ids => \@row_ids,
            });
            die "eligibility resolver returned an invalid result\n"
                unless ref($eligible) eq 'HASH';
            1;
        };
        unless ($ok) {
            $controller->app->log->error(
                "Selecto action $action->{id} eligibility failed: $@",
            );
            next;
        }
        for my $record (@{$result->{records}}) {
            next unless ref($record) eq 'HASH';
            my $id = $record->{$target_key};
            $record->{$field} = defined($id) && !ref($id) && $eligible->{"$id"} ? 1 : 0;
        }
    }
}

sub _save_query ($controller, $explorer) {
    my $config = $explorer->config;
    my $return_to = _safe_return_to($config, scalar $controller->param('return_to'));
    my $unavailable = _saved_query_unavailable($controller, $config, $return_to);
    return $unavailable if $unavailable;
    my $csrf_error = _saved_query_csrf_error($controller, $return_to);
    return $csrf_error if $csrf_error;

    my ($name, $name_error) = _saved_query_name(scalar $controller->param('saved_query_name'));
    return _saved_query_response($controller, $return_to, {
        ok => 0, status => 422, message => $name_error,
    }) if $name_error;

    my $url;
    my $url_ok = eval {
        $url = _canonical_saved_query_url(
            $controller, $explorer, scalar $controller->param('saved_query_url'),
        );
        1;
    };
    unless ($url_ok) {
        $controller->app->log->warn("Selecto saved query URL rejected: $@");
        return _saved_query_response($controller, $return_to, {
            ok => 0, status => 422,
            message => 'The query could not be saved. Run it again and retry.',
        });
    }

    my $save_ok = eval {
        $config->saved_query_store->save($controller, $config, {
            name => $name,
            url => $url,
        });
        1;
    };
    unless ($save_ok) {
        $controller->app->log->error("Selecto saved query save failed: $@");
        return _saved_query_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The query could not be saved.',
        });
    }
    return _saved_query_response($controller, $url, {
        ok => 1, status => 200, name => $name, url => $url,
        message => qq{Saved query "$name".},
    });
}

sub _delete_saved_query ($controller, $explorer) {
    my $config = $explorer->config;
    my $return_to = _safe_return_to($config, scalar $controller->param('return_to'));
    my $unavailable = _saved_query_unavailable($controller, $config, $return_to);
    return $unavailable if $unavailable;
    my $csrf_error = _saved_query_csrf_error($controller, $return_to);
    return $csrf_error if $csrf_error;

    my ($name, $name_error) = _saved_query_name(scalar $controller->param('saved_query_name'));
    return _saved_query_response($controller, $return_to, {
        ok => 0, status => 422, message => $name_error,
    }) if $name_error;
    my $delete_ok = eval {
        $config->saved_query_store->delete($controller, $config, {name => $name});
        1;
    };
    unless ($delete_ok) {
        $controller->app->log->error("Selecto saved query delete failed: $@");
        return _saved_query_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The saved query could not be deleted.',
        });
    }
    return _saved_query_response($controller, $return_to, {
        ok => 1, status => 200, name => $name,
        message => qq{Deleted saved query "$name".},
    });
}

sub _saved_query_unavailable ($controller, $config, $return_to) {
    return undef if $config->saved_query_store;
    return _saved_query_response($controller, $return_to, {
        ok => 0, status => 404, message => 'Saved queries are not available.',
    });
}

sub _saved_query_csrf_error ($controller, $return_to) {
    my $submitted = $controller->param('csrf_token') // '';
    my $expected = $controller->session('selecto_components_csrf') // '';
    return undef if length($submitted) && length($expected)
        && secure_compare("$submitted", "$expected");
    return _saved_query_response($controller, $return_to, {
        ok => 0, status => 403,
        message => 'The saved query form expired. Reload the explorer and try again.',
    });
}

sub _saved_query_name ($value) {
    $value = '' unless defined($value) && !ref($value);
    $value = "$value";
    $value =~ s/\A\s+|\s+\z//g;
    return (undef, 'Enter a name for the saved query.') unless length($value);
    return (undef, 'Saved query names must be 30 characters or fewer.')
        if length($value) > 30;
    return (undef, 'The saved query name contains unsupported characters.')
        if $value =~ /[\x00-\x1f\x7f]/;
    return ($value, undef);
}

sub _canonical_saved_query_url ($controller, $explorer, $value) {
    die "saved query URL is required\n"
        unless defined($value) && !ref($value) && length($value);
    my $config = $explorer->config;
    my $url = Mojo::URL->new("$value");
    die "saved query URL must be local\n"
        if $url->is_abs || defined($url->host) || defined($url->userinfo);
    die "saved query URL has an invalid path\n"
        unless $url->path->to_string eq $config->path;
    die "saved query URL cannot contain a fragment\n"
        if defined($url->fragment) && length($url->fragment);

    my %input;
    for my $name (@{Selecto::Components::State->parameter_names}) {
        my $values = $url->query->every_param($name);
        next unless ref($values) eq 'ARRAY' && @$values;
        $input{$name} = @$values == 1 ? $values->[0] : [@$values];
    }
    my $engine = $config->engine($controller);
    die "saved queries require URL query state\n"
        unless $config->query_params_enabled($engine->domain);
    my $state = Selecto::Components::State->from_input($config, $engine->domain, \%input);
    die join(' ', @{$state->errors}) . "\n" unless $state->valid;
    return $explorer->canonical_url($state->with_page(1), $engine->domain);
}

sub _normalize_saved_queries ($config, $queries) {
    my @normalized;
    my %seen;
    for my $query (@$queries) {
        next unless ref($query) eq 'HASH';
        my ($name, $name_error) = _saved_query_name($query->{name});
        next if $name_error || $seen{$name}++;
        my $url = $query->{url} // $query->{query};
        next unless defined($url) && !ref($url) && length($url);
        my $parsed = Mojo::URL->new("$url");
        next if $parsed->is_abs || defined($parsed->host) || defined($parsed->userinfo);
        next unless $parsed->path->to_string eq $config->path;
        next if defined($parsed->fragment) && length($parsed->fragment);
        push @normalized, {name => $name, url => $parsed->to_string};
    }
    return [sort { lc($a->{name}) cmp lc($b->{name}) || $a->{name} cmp $b->{name} } @normalized];
}

sub _saved_query_response ($controller, $return_to, $result) {
    my $status = $result->{status} // ($result->{ok} ? 200 : 422);
    if (($controller->req->headers->accept // '') =~ m{application/json}i
        || ($controller->req->headers->header('X-Requested-With') // '') eq 'XMLHttpRequest') {
        return $controller->render(json => $result, status => $status);
    }
    $controller->flash(
        $result->{ok} ? 'selecto_saved_query_notice' : 'selecto_saved_query_error',
        $result->{message},
    );
    return $controller->redirect_to($return_to);
}

sub _run_action ($controller, $explorer) {
    my $config = $explorer->config->for_request($controller);
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
        {group_payload => scalar $controller->param('action_groups')},
    );
    return _action_response($controller, $return_to, {
        ok => 0, status => 422, message => join(' ', @{$request->{errors}}),
        errors => $request->{errors},
    }) unless $request->{valid};

    my $execute_decision = Selecto::Components::Actions->authorize(
        $config, $controller, $resolved->{action}, 'execute', {
            ids => $request->{selected_ids}, inputs => $request->{inputs},
            groups => $request->{groups},
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

sub _run_action_lookup ($controller, $explorer) {
    my $config = $explorer->config->for_request($controller);
    my $query = $controller->param('q');
    $query = '' unless defined($query) && !ref($query);
    $query = "$query";
    $query =~ s/\A\s+|\s+\z//g;
    return _lookup_response($controller, 422, {
        error => 'The lookup query is too long.', results => [],
    }) if length($query) > 100 || $query =~ /\0/;

    my $selected_values = $controller->every_param('selected_id');
    my @selected_ids = ref($selected_values) eq 'ARRAY' ? @$selected_values : ();
    my %seen;
    @selected_ids = grep {
        defined($_) && !ref($_) && length("$_") <= 200 && "$_" !~ /\0/
            && !$seen{"$_"}++
    } @selected_ids;
    return _lookup_response($controller, 422, {
        error => 'Too many rows were selected for this lookup.', results => [],
    }) if @selected_ids > $config->max_action_rows;

    my $action_id = $controller->stash('selecto_action_id') // '';
    my $input_id = $controller->stash('selecto_input_id') // '';
    my ($domain, $resolved);
    my $discovery_ok = eval {
        $domain = $config->engine($controller)->domain;
        $resolved = Selecto::Components::Actions->find(
            $config, $domain, $controller, $action_id, 'preview',
            @selected_ids ? {ids => \@selected_ids} : undef,
        );
        1;
    };
    unless ($discovery_ok) {
        $controller->app->log->error("Selecto action lookup discovery failed: $@");
        return _lookup_response($controller, 500, {
            error => 'The lookup could not be prepared.', results => [],
        });
    }
    return _lookup_response($controller, 404, {
        error => 'That lookup is not available.', results => [],
    }) unless $resolved && ($resolved->{decision}{status} // '') eq 'enabled';

    my @inputs = (
        @{$resolved->{action}{inputs} // []},
        @{$resolved->{action}{selection}{group_inputs} // []},
    );
    my ($input) = grep {
        ($_->{id} // '') eq $input_id && ($_->{type} // '') eq 'lookup'
    } @inputs;
    return _lookup_response($controller, 404, {
        error => 'That lookup is not available.', results => [],
    }) unless $input;
    return _lookup_response($controller, 200, {results => []})
        if length($query) < ($input->{minimum_query_length} // 2);

    my $lookup_request = {
        query => $query,
        limit => $input->{result_limit} // 20,
        action => $resolved->{action},
        input => $input,
        selected_ids => \@selected_ids,
    };
    my $raw;
    my $lookup_ok = eval {
        my $co_domain_id = $input->{co_domain};
        my $lookup_source = $input->{lookup_source};
        die "lookup input must declare exactly one lookup source\n"
            if (defined($co_domain_id) ? 1 : 0) + (defined($lookup_source) ? 1 : 0) != 1;
        if (defined $co_domain_id) {
            my $definition = Selecto::CoDomain->definition($domain, $co_domain_id);
            my $co_engine = $config->co_domain_engine(
                $definition->{domain}, $controller, $lookup_request,
            ) or die "co-domain engine $definition->{domain} is not configured\n";
            my %lookup_args = (
                source_domain => $domain,
                co_domain => $co_domain_id,
                engine => $co_engine,
                query => $query,
                limit => $lookup_request->{limit},
            );
            if (my $scope_resolver = $config->co_domain_scope($co_domain_id)) {
                my $scope = $scope_resolver->($controller, $lookup_request, $co_engine);
                if (ref($scope) eq 'HASH') {
                    $lookup_args{predicate} = $scope->{predicate}
                        if exists $scope->{predicate};
                    $lookup_args{parameters} = $scope->{parameters}
                        if exists $scope->{parameters};
                } elsif (defined $scope) {
                    $lookup_args{predicate} = $scope;
                }
            }
            $raw = Selecto::CoDomain->lookup(%lookup_args);
        } else {
            my $resolver = $config->lookup_source($lookup_source)
                or die "lookup source $lookup_source is not configured\n";
            $raw = $resolver->($controller, $lookup_request);
        }
        1;
    };
    unless ($lookup_ok) {
        my $lookup_id = $input->{co_domain} // $input->{lookup_source} // 'unknown';
        $controller->app->log->error("Selecto action lookup $lookup_id failed: $@");
        return _lookup_response($controller, 500, {
            error => 'The lookup could not be completed.', results => [],
        });
    }
    $raw = $raw->{results} if ref($raw) eq 'HASH';
    unless (ref($raw) eq 'ARRAY') {
        $controller->app->log->error(
            'Selecto action lookup returned an invalid result',
        );
        return _lookup_response($controller, 500, {
            error => 'The lookup returned an invalid result.', results => [],
        });
    }

    my (@results, %seen_value);
    for my $item (@$raw) {
        next unless ref($item) eq 'HASH';
        my $value = $item->{value} // $item->{id};
        my $label = $item->{label} // $item->{name};
        next unless defined($value) && !ref($value) && defined($label) && !ref($label);
        $value = "$value";
        $label = "$label";
        next if $value eq '' || $label eq '' || length($value) > 200
            || length($label) > 200 || $value =~ /\0/ || $label =~ /\0/
            || $seen_value{$value}++;
        my %normalized = (value => $value, label => $label);
        my $description = $item->{description};
        $normalized{description} = "$description"
            if defined($description) && !ref($description)
                && length("$description") <= 400 && "$description" !~ /\0/;
        push @results, \%normalized;
        last if @results >= ($input->{result_limit} // 20);
    }
    return _lookup_response($controller, 200, {results => \@results});
}

sub _lookup_response ($controller, $status, $payload) {
    $controller->res->headers->cache_control('no-store');
    return $controller->render(json => $payload, status => $status);
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
