package Selecto::Components::Controller::SavedQueries;

use Mojo::Base -base, -signatures;
use Mojo::URL ();
use Mojo::Util qw(secure_compare);
use Selecto::Components::State ();

sub _save_query ($controller, $explorer) {
    my $config = $explorer->config;
    my $return_to = Selecto::Components::_safe_return_to($config, scalar $controller->param('return_to'));
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
    my $return_to = Selecto::Components::_safe_return_to($config, scalar $controller->param('return_to'));
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

1;
