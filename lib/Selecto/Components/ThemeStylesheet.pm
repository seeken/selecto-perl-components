package Selecto::Components::ThemeStylesheet;

use 5.034;
use strict;
use warnings;

use Mojo::Base -strict, -signatures;
use Selecto::Components::AssetManifest qw(asset_revision);
use Selecto::Components::Util qw(html_escape);

# Host theme colours reach the page as a same-origin stylesheet, never as an
# inline style attribute, so a strict `style-src 'self'` policy applies them.
# The stylesheet is stateless: its query string carries the validated colours
# and the route only echoes six-digit hexadecimal values back as CSS.

my %PATH = (
    explorer => '/selecto-components/theme.css',
    console  => '/selecto-api-console/theme.css',
);
my @KEYS = qw(primary secondary on_primary);
my $COLOR = qr/\A#[0-9A-Fa-f]{6}\z/;
my $QUERY_COLOR = qr/\A[0-9A-Fa-f]{6}\z/;

sub path ($class, $kind) {
    return $PATH{$kind} // die "unknown theme stylesheet kind $kind\n";
}

# Custom properties for a validated theme, in the order the inline style used.
sub declarations ($class, $kind, $theme) {
    $class->path($kind);
    $theme //= {};
    my %color = map {
        my $value = $theme->{$_};
        die "theme $_ must be a hexadecimal color\n"
            if defined($value) && (ref($value) || "$value" !~ $COLOR);
        defined($value) ? ($_ => uc "$value") : ();
    } @KEYS;
    if ($kind eq 'console') {
        my $secondary = $color{secondary} // $color{primary};
        return [
            ($color{primary} ? (['--sac-accent', $color{primary}], ['--cgt-brand', $color{primary}]) : ()),
            ($secondary ? (['--sac-teal', $secondary], ['--cgt-accent', $secondary]) : ()),
            ($color{on_primary}
                ? (['--sac-on-accent', $color{on_primary}], ['--cgt-on-brand', $color{on_primary}]) : ()),
        ];
    }
    return [
        ($color{primary} ? (['--sc-brand', $color{primary}]) : ()),
        ($color{secondary} ? (['--sc-accent', $color{secondary}]) : ()),
        ($color{on_primary} ? (['--sc-on-brand', $color{on_primary}]) : ()),
    ];
}

# One :root rule. !important keeps the host colours ahead of the palette's
# scheme rules, as the inline style attribute did.
sub css ($class, $kind, $theme) {
    my $declarations = $class->declarations($kind, $theme);
    return '' unless @$declarations;
    return ':root{' . join(';', map { "$_->[0]:$_->[1] !important" } @$declarations) . "}\n";
}

sub href ($class, $kind, $theme) {
    return '' unless @{$class->declarations($kind, $theme)};
    my @query = map {
        defined($theme->{$_}) ? ($_ . '=' . uc(substr("$theme->{$_}", 1))) : ()
    } @KEYS;
    return $class->path($kind) . '?' . join('&', @query, 'v=' . asset_revision());
}

sub link_tag ($class, $kind, $theme) {
    my $href = $class->href($kind, $theme);
    return length($href) ? '<link rel="stylesheet" href="' . html_escape($href) . '">' : '';
}

# Registers GET <path> on the application's own routes (not a route bridge):
# the colours are public presentation and the response depends only on the
# query string.
sub install_route ($class, $app, $kind) {
    my $name = "selecto_components_theme_$kind";
    return if $app->routes->lookup($name);
    $app->routes->get($class->path($kind))->to(cb => sub ($controller) {
        my %theme;
        for my $key (@KEYS) {
            my $value = $controller->req->query_params->param($key);
            next unless defined $value;
            return $controller->render(text => "Invalid theme colour\n", status => 400)
                unless $value =~ $QUERY_COLOR;
            $theme{$key} = "#$value";
        }
        my $headers = $controller->res->headers;
        $headers->cache_control('public, max-age=31536000, immutable');
        $headers->content_type('text/css; charset=utf-8');
        return $controller->render(data => $class->css($kind, \%theme));
    })->name($name);
    return;
}

1;

__END__

=head1 NAME

Selecto::Components::ThemeStylesheet - CSP-compatible host theme colours

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

Explorer, canned page, API Console and Importer pages link host theme colours
as a same-origin stylesheet (C</selecto-components/theme.css> or
C</selecto-api-console/theme.css>) instead of an inline C<style> attribute, so
a strict C<style-src 'self'> Content-Security-Policy applies them. The query
string carries the validated C<#RRGGBB> colours and the route only renders
six-digit hexadecimal values back as CSS custom properties.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
