package Selecto::Components::Templates::WebSocket;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop ();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::WebSocket qw(WS_PING);
use Selecto::Components::Controller::Templates ();
use Selecto::Components::WebSocketPolicy ();

sub connect ($class, $controller, $runtime, %options) {
    my $snapshot_response = $options{snapshot_response};
    my $error_response = $options{error_response};
    die "snapshot_response must be a coderef\n"
        if defined($snapshot_response) && ref($snapshot_response) ne 'CODE';
    die "error_response must be a coderef\n"
        if defined($error_response) && ref($error_response) ne 'CODE';
    unless ($runtime->{origin_check}->($controller)) {
        return $controller->finish(1008 => 'WebSocket origin is not allowed');
    }
    my $instance_id = $options{instance_id}
        // $controller->stash('selecto_template_instance_id');
    my $context = Selecto::Components::Controller::Templates->instance_context(
        $controller, $runtime, $instance_id,
    );
    return $controller->finish(1008 => 'Template connection is not authorized')
        unless $context->{status} eq 'ok';

    $controller->inactivity_timeout($runtime->{websocket_inactivity_timeout});
    _heartbeat($controller, $runtime->{websocket_heartbeat_interval});
    $controller->on(message => sub ($socket, $message) {
        return $socket->finish(1009 => 'WebSocket message is too large')
            if !defined($message) || length($message) > 131_072;
        my $envelope;
        my $decoded = eval { $envelope = decode_json($message); 1 };
        return $socket->finish(1003 => 'Expected a template event message')
            unless $decoded && ref($envelope) eq 'HASH'
            && ref($envelope->{headers}) eq 'HASH';

        my $params = _event_params($envelope);
        unless ($params->{status} eq 'ok') {
            return _send_error(
                $socket, $runtime, $instance_id, $params, $error_response,
            );
        }
        return $socket->finish(1008 => 'Template request token is invalid')
            unless Selecto::Components::WebSocketPolicy::valid_csrf(
                $socket, $params->{csrf_token},
            );

        my $result = Selecto::Components::Controller::Templates->dispatch_event(
            $socket, $runtime,
            instance_id => $instance_id,
            params => $params,
        );
        return $socket->finish(1008 => 'Template connection is not authorized')
            if ($result->{status} // '') eq 'unauthenticated'
            || ($result->{status} // '') eq 'forbidden'
            || ($result->{status} // '') eq 'not_found';
        return _send_error(
            $socket, $runtime, $instance_id, $result, $error_response,
        )
            unless $result->{status} eq 'ok';

        my $response = eval {
            $snapshot_response
                ? $snapshot_response->($socket, $result)
                : $runtime->{transport}->websocket_snapshot(
                    $socket,
                    template => $result->{template},
                    snapshot => $result->{snapshot},
                    store_revision => $result->{store_revision},
                    event_id => $result->{event_id},
                    component_id => $result->{component_id},
                    component_lifetime => $result->{component_lifetime},
                    form_revision => $result->{form_revision},
                    region_node_ids => $result->{region_node_ids},
                );
        };
        return $socket->finish(1011 => 'Template response could not be rendered')
            unless ref($response) eq 'HASH';
        return $socket->send({text => encode_json($response)});
    });
    return undef;
}

sub _heartbeat ($controller, $interval) {
    return unless $interval;
    my $heartbeat_id;
    $heartbeat_id = Mojo::IOLoop->recurring($interval => sub {
        my $tx = $controller->tx;
        return Mojo::IOLoop->remove($heartbeat_id)
            unless $tx && $tx->is_websocket && $tx->established;
        $controller->send([1, 0, 0, 0, WS_PING, '']);
    });
    $controller->on(finish => sub {
        Mojo::IOLoop->remove($heartbeat_id) if defined($heartbeat_id);
    });
}

sub _event_params ($envelope) {
    my %allowed = map { $_ => 1 }
        qw(headers template_action csrf_token event event_id state_revision value
            component_id component_lifetime form_revision);
    return _invalid_event() if grep { !$allowed{$_} } keys %$envelope;
    return _invalid_event()
        unless defined($envelope->{template_action})
        && !ref($envelope->{template_action})
        && $envelope->{template_action} eq 'event';
    for my $name (qw(csrf_token event event_id state_revision value component_id
        component_lifetime form_revision)) {
        return _invalid_event()
            unless exists($envelope->{$name}) && !ref($envelope->{$name});
    }
    return _invalid_event()
        unless length($envelope->{event}) && length($envelope->{event}) <= 128
        && "$envelope->{event_id}" =~ /\A[\x21-\x7e]{1,256}\z/
        && "$envelope->{state_revision}" =~ /\A[0-9]+\z/
        && "$envelope->{component_id}" =~ /\A[A-Za-z0-9_.:-]{1,512}\z/
        && "$envelope->{component_lifetime}" =~ /\A[0-9a-f]{64}\z/
        && "$envelope->{form_revision}" =~ /\A[0-9]+\z/;
    return {
        status => 'ok',
        map { $_ => $envelope->{$_} }
            qw(csrf_token event event_id value component_id component_lifetime
                form_revision),
        state_revision => 0 + $envelope->{state_revision},
    };
}

sub _invalid_event {
    return {
        status => 'error', code => 'invalid_event_params',
        message => 'Template event parameters are invalid.',
    };
}

sub _send_error ($socket, $runtime, $instance_id, $error, $error_response = undef) {
    my $response = eval {
        $error_response
            ? $error_response->($socket, $error)
            : $runtime->{transport}->websocket_error(
                instance_id => $instance_id, result => $error,
            );
    };
    return $socket->finish(1011 => 'Template response could not be rendered')
        unless ref($response) eq 'HASH';
    return $socket->send({text => encode_json($response)});
}

1;
