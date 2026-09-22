package Selecto::Components::Templates::WebSocket;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop ();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::WebSocket qw(WS_PING);
use Selecto::Components::Controller::Templates ();
use Selecto::Components::WebSocketPolicy ();

sub connect ($class, $controller, $runtime) {
    unless ($runtime->{origin_check}->($controller)) {
        return $controller->finish(1008 => 'WebSocket origin is not allowed');
    }
    my $instance_id = $controller->stash('selecto_template_instance_id');
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
            return _send_error($socket, $runtime, $instance_id, $params);
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
        return _send_error($socket, $runtime, $instance_id, $result)
            unless $result->{status} eq 'ok';

        my $response = $runtime->{transport}->websocket_snapshot(
            $socket,
            template => $result->{template},
            snapshot => $result->{snapshot},
            store_revision => $result->{store_revision},
        );
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
        qw(headers template_action csrf_token event event_id state_revision value);
    return _invalid_event() if grep { !$allowed{$_} } keys %$envelope;
    return _invalid_event()
        unless defined($envelope->{template_action})
        && !ref($envelope->{template_action})
        && $envelope->{template_action} eq 'event';
    for my $name (qw(csrf_token event event_id state_revision value)) {
        return _invalid_event()
            unless exists($envelope->{$name}) && !ref($envelope->{$name});
    }
    return _invalid_event()
        unless length($envelope->{event}) && length($envelope->{event}) <= 128
        && length($envelope->{event_id}) && length($envelope->{event_id}) <= 256
        && "$envelope->{state_revision}" =~ /\A[0-9]+\z/;
    return {
        status => 'ok',
        map { $_ => $envelope->{$_} }
            qw(csrf_token event event_id value),
        state_revision => 0 + $envelope->{state_revision},
    };
}

sub _invalid_event {
    return {
        status => 'error', code => 'invalid_event_params',
        message => 'Template event parameters are invalid.',
    };
}

sub _send_error ($socket, $runtime, $instance_id, $error) {
    my $response = $runtime->{transport}->websocket_error(
        instance_id => $instance_id, result => $error,
    );
    return $socket->send({text => encode_json($response)});
}

1;
