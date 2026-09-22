package Selecto::Components::Templates::Transport;

use Mojo::Base -base, -signatures;
use Selecto::Components::AssetManifest qw(asset_revision);
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Util qw(html_escape);

has [qw(template_path instance_path event_id_generator)];

sub respond_snapshot ($self, $controller, %args) {
    my $rendered = eval { $self->_render_snapshot($controller, %args) };
    if ($@ || ref($rendered) ne 'HASH') {
        $controller->app->log->error('Selecto template render failed');
        return $self->respond_error($controller, {
            status => 'error', code => 'template_render_failed',
            message => 'Template could not be rendered.',
        });
    }
    _private_headers($controller);
    $controller->res->headers->header(
        'X-Selecto-Template-Instance' => $args{snapshot}{instance_id},
    );
    $controller->res->headers->header(
        'X-Selecto-State-Revision' => $args{snapshot}{state_revision},
    );
    $controller->res->headers->header(
        'X-Selecto-Store-Revision' => $args{store_revision},
    );
    my $html = _is_fragment($controller) ? $rendered->{root} : $rendered->{page};
    return $controller->render(data => $html, format => 'html', status => 200);
}

sub respond_error ($self, $controller, $result) {
    my $status = _status($result);
    my $code = ref($result) eq 'HASH' && defined($result->{code})
        ? $result->{code} : _default_code($result, $status);
    my $message = ref($result) eq 'HASH' && defined($result->{message})
        ? $result->{message} : _default_message($status);
    _private_headers($controller);
    my $error = '<section class="selecto-template-error" role="alert"' .
        ' data-selecto-template-error="' . html_escape($code) . '"><h1>' .
        html_escape(_title_for_status($status)) . '</h1><p>' .
        html_escape($message) . '</p></section>';
    my $html = _is_fragment($controller) ? $error : _page('Template error', $error);
    return $controller->render(data => $html, format => 'html', status => $status);
}

sub _render_snapshot ($self, $controller, %args) {
    my $template = $args{template};
    my $snapshot = $args{snapshot};
    my $csrf_token = $controller->csrf_token;
    my $root_id = _root_id($snapshot->{instance_id});
    my $registry = $self->_transport_registry(
        $template->{registry}, $snapshot, $csrf_token, $root_id,
    );
    my $content = Selecto::Components::Templates::Renderer->render(
        manifest => $template->{manifest}, snapshot => $snapshot,
        registry => $registry,
    );
    my $sources = $self->_source_controls($snapshot, $csrf_token, $root_id);
    my $root = '<main id="' . html_escape($root_id) . '"' .
        ' class="selecto-template-instance" hx-history="false"' .
        ' hx-status:4xx="swap: outerHTML" hx-status:5xx="swap: outerHTML"' .
        ' data-selecto-template-instance="' . html_escape($snapshot->{instance_id}) . '"' .
        ' data-selecto-template-release="' . html_escape($snapshot->{release_id}) . '"' .
        ' data-selecto-state-revision="' . html_escape($snapshot->{state_revision}) . '"' .
        ' data-selecto-store-revision="' . html_escape($args{store_revision}) . '">' .
        '<div data-selecto-template-content>' . $content . '</div>' . $sources . '</main>';
    return {root => $root, page => _page($template->{title}, $root)};
}

sub _transport_registry ($self, $registry, $snapshot, $csrf_token, $root_id) {
    my %decorated = %$registry;
    my %components;
    for my $name (keys %{ref($registry->{components}) eq 'HASH'
        ? $registry->{components} : {}}) {
        my $renderer = $registry->{components}{$name};
        $components{$name} = sub ($node) {
            my %events = map {
                $_ => $self->_event_descriptor(
                    $snapshot, $csrf_token, $root_id, $node->{events}{$_},
                )
            } keys %{$node->{events}};
            return $renderer->({%$node, transport => {events => \%events}});
        };
    }
    $decorated{components} = \%components;
    return \%decorated;
}

sub _event_descriptor ($self, $snapshot, $csrf_token, $root_id, $event) {
    my $event_id = $self->event_id_generator->();
    die "invalid_event_id: event ID generator returned an invalid value\n"
        unless defined($event_id) && !ref($event_id)
        && length("$event_id") && length("$event_id") <= 256;
    my $action = $self->instance_path . '/' . $snapshot->{instance_id} . '/events';
    return {
        action => $action, method => 'post', hx_post => $action,
        hx_target => "#$root_id", hx_swap => 'outerHTML',
        fields => {
            csrf_token => "$csrf_token", event => "$event",
            event_id => "$event_id",
            state_revision => 0 + $snapshot->{state_revision},
        },
    };
}

sub _source_controls ($self, $snapshot, $csrf_token, $root_id) {
    my $html = '';
    for my $source_id (sort keys %{$snapshot->{sources}}) {
        my $source = $snapshot->{sources}{$source_id};
        next unless ref($source) eq 'HASH';
        if (($source->{status} // '') eq 'loading') {
            my $action = $self->instance_path . '/' . $snapshot->{instance_id} .
                '/sources/' . $source_id;
            $html .= '<form class="selecto-template-source" method="post" action="' .
                html_escape($action) . '" hx-post="' . html_escape($action) .
                '" hx-trigger="load" hx-target="#' . html_escape($root_id) .
                '" hx-swap="outerHTML" data-selecto-template-source="' .
                html_escape($source_id) . '"><input type="hidden" name="csrf_token" value="' .
                html_escape($csrf_token) . '"><noscript><button type="submit">Load ' .
                html_escape($source_id) . '</button></noscript></form>';
        }
        elsif (($source->{status} // '') eq 'error') {
            my $code = ref($source->{error}) eq 'HASH'
                ? $source->{error}{code} // 'source_failed' : 'source_failed';
            $html .= '<p class="selecto-template-source-error" role="alert"' .
                ' data-selecto-template-source="' . html_escape($source_id) . '">' .
                html_escape("Source $source_id failed: $code") . '</p>';
        }
    }
    return $html;
}

sub _root_id ($instance_id) {
    my $encoded = join '', map {
        ($_ >= 48 && $_ <= 57) || ($_ >= 65 && $_ <= 90)
            || ($_ >= 97 && $_ <= 122) || $_ == 95
            ? chr($_) : sprintf('-%02X', $_)
    } unpack 'C*', "$instance_id";
    return "selecto-template-instance-$encoded";
}

sub _page ($title, $content) {
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width, initial-scale=1">' .
        '<title>' . html_escape($title) . '</title>' .
        '<link rel="stylesheet" href="/selecto-components/selecto-components.css?v=' .
        asset_revision() . '">' .
        '<script src="/selecto-components/htmx.min.js?v=' . asset_revision() .
        '" defer></script>' .
        '</head><body>' . $content . '</body></html>';
}

sub _private_headers ($controller) {
    $controller->res->headers->cache_control('no-store, private');
    $controller->res->headers->header('Pragma' => 'no-cache');
    $controller->res->headers->header('X-Content-Type-Options' => 'nosniff');
}

sub _is_fragment ($controller) {
    return lc($controller->req->headers->header('HX-Request') // '') eq 'true';
}

sub _status ($result) {
    my $status = ref($result) eq 'HASH' ? $result->{status} // '' : '';
    my $code = ref($result) eq 'HASH' ? $result->{code} // '' : '';
    return 401 if $status eq 'unauthenticated';
    return 403 if $status eq 'forbidden' || $code eq 'invalid_csrf';
    return 404 if $status eq 'not_found';
    return 410 if $status eq 'expired';
    return 409 if $status eq 'conflict' || $status eq 'busy'
        || $status eq 'claim_lost' || $status eq 'stale'
        || $code eq 'stale_revision' || $code eq 'duplicate_event';
    return 503 if $code eq 'instance_store_unavailable'
        || $code eq 'template_host_unavailable';
    return 422;
}

sub _title_for_status ($status) {
    return 'Authentication required' if $status == 401;
    return 'Access denied' if $status == 403;
    return 'Template not found' if $status == 404;
    return 'Template expired' if $status == 410;
    return 'Template changed' if $status == 409;
    return 'Template unavailable' if $status == 503;
    return 'Template request invalid';
}

sub _default_code ($result, $http_status) {
    my $status = ref($result) eq 'HASH' ? $result->{status} // '' : '';
    return 'authentication_required' if $status eq 'unauthenticated';
    return 'template_forbidden' if $status eq 'forbidden';
    return 'template_not_found' if $status eq 'not_found';
    return 'template_expired' if $status eq 'expired';
    return 'source_effect_busy' if $status eq 'busy';
    return 'source_claim_lost' if $status eq 'claim_lost';
    return 'source_effect_stale' if $status eq 'stale';
    return 'template_conflict' if $status eq 'conflict';
    return 'template_host_unavailable' if $http_status == 503;
    return 'template_request_failed';
}

sub _default_message ($status) {
    return 'Authentication is required.' if $status == 401;
    return 'Template access is forbidden.' if $status == 403;
    return 'Template was not found.' if $status == 404;
    return 'Template expired. Reload it to start again.' if $status == 410;
    return 'Template changed. Reload and try again.' if $status == 409;
    return 'Template host is unavailable.' if $status == 503;
    return 'Template request is invalid.';
}

1;
