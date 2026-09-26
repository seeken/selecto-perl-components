package Selecto::Components::Templates::AuthoringPreviewHost;

use 5.034;
use strict;
use warnings;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Util qw(secure_compare);
use Selecto::Components::Templates::AuthoringPreview ();

has preview_token => sub { $ENV{SELECTO_TEMPLATE_PREVIEW_TOKEN} // '' };
has preview => sub { Selecto::Components::Templates::AuthoringPreview->new };

sub startup ($self) {
    die "A private SELECTO_TEMPLATE_PREVIEW_TOKEN of at least 32 characters is required\n"
        unless length($self->preview_token) >= 32;
    $self->max_request_size(1_048_576);
    $self->log->level('warn');
    $self->hook(after_dispatch => sub ($c) {
        $c->res->headers->header('Cache-Control' => 'no-store');
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('Content-Security-Policy' => "default-src 'none'; frame-ancestors 'none'");
    });
    $self->routes->get('/health')->to(cb => sub ($c) {
        $c->render(json => {runtime => 'perl', service => 'selecto-template-authoring'});
    });
    $self->routes->post('/observe')->to(cb => sub ($c) {
        return $c->render(status => 403, json => {error => 'preview_access_denied'})
            if $c->req->headers->origin
            || !secure_compare($c->req->headers->header('X-Selecto-Preview-Token') // '', $self->preview_token)
            || ($c->tx->remote_address // '') !~ /\A(?:127\.0\.0\.1|::1)\z/;
        return $c->render(status => 415, json => {error => 'json_required'})
            unless ($c->req->headers->content_type // '') =~ m{\Aapplication/json(?:;|\z)}i;
        $c->render(json => $self->preview->observe($c->req->json));
    });
}

1;
