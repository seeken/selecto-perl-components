package Selecto::Components::WebSocketPolicy;

use 5.034;
use strict;
use warnings;

use Mojo::URL ();

sub same_origin {
    my ($controller) = @_;
    my $origin = $controller->req->headers->origin;
    return 1 unless defined($origin) && length($origin);
    my $origin_url = Mojo::URL->new($origin);
    my $scheme = lc($origin_url->scheme // '');
    return 0 unless $scheme eq 'http' || $scheme eq 'https';
    return 0 unless defined($origin_url->host) && length($origin_url->host);
    return 0 if defined($origin_url->userinfo) || defined($origin_url->fragment)
        || length($origin_url->query->to_string)
        || $origin_url->path->to_string !~ m{\A/?\z};
    my $request_scheme = lc($controller->req->url->to_abs->scheme // '');
    $request_scheme = 'http' if $request_scheme eq 'ws';
    $request_scheme = 'https' if $request_scheme eq 'wss';
    return 0 unless $scheme eq $request_scheme;
    my $request_url = Mojo::URL->new(
        $request_scheme . '://' . ($controller->req->headers->host // ''),
    );
    return 0 unless lc($origin_url->host) eq lc($request_url->host // '');
    my $default_port = $scheme eq 'https' ? 443 : 80;
    return ($origin_url->port // $default_port)
        eq ($request_url->port // $default_port) ? 1 : 0;
}

sub valid_csrf {
    my ($controller, $token) = @_;
    return 0 unless defined($token) && !ref($token);
    my $validation = $controller->app->validator->validation
        ->input({csrf_token => "$token"})
        ->csrf_token($controller->session->{csrf_token})
        ->csrf_protect;
    return $validation->has_error('csrf_token') ? 0 : 1;
}

1;

__END__

=head1 NAME

Selecto::Components::WebSocketPolicy - Same-origin and CSRF checks for Selecto::Components

=head1 SYNOPSIS

    use Selecto::Components::WebSocketPolicy;

    # The plugin's default origin_check:
    plugin 'Selecto::Components' => {
        origin_check => \&Selecto::Components::WebSocketPolicy::same_origin,
        explorers => {...},
    };

    # A host behind a proxy that serves an extra, trusted origin:
    origin_check => sub ($c) {
        return 1 if ($c->req->headers->origin // '') eq 'https://reports.example.com';
        return Selecto::Components::WebSocketPolicy::same_origin($c);
    },

=head1 DESCRIPTION

Browsers send cookies on cross-site WebSocket handshakes. The plugin
therefore checks the C<Origin> of every Explorer and canned-page WebSocket,
and of the lazy C<controls> POST, before doing any work. A refused handshake
is closed with code 1008.

=head1 FUNCTIONS

=head2 same_origin

    my $ok = Selecto::Components::WebSocketPolicy::same_origin($controller);

Returns true when the request has no C<Origin> header, so that native
clients work. Otherwise the origin must be a bare C<http> or C<https> origin
(no user info, path, query or fragment) with the same scheme (C<ws> maps to
C<http> and C<wss> to C<https>), the same host, and the same effective port
as the request's C<Host> header.

Behind a TLS-terminating proxy, make sure Mojolicious sees the original
scheme and host. Use C<MOJO_REVERSE_PROXY> or C<MOJO_TRUSTED_PROXIES>, or
hypnotoad's C<proxy> setting, so that C<X-Forwarded-Proto> is honoured.
Otherwise, supply your own C<origin_check>.

=head2 valid_csrf

    my $ok = Selecto::Components::WebSocketPolicy::valid_csrf($controller, $token);

Checks C<$token> against the session's Mojolicious CSRF token.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
