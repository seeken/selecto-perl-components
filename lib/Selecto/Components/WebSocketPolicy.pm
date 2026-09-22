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
