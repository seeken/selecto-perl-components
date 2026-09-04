package Selecto::Components::APIConsole;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::File qw(path);
use Selecto::Components::Util qw(html_escape);

my $ASSET_REVISION = '0.3.2';

sub install_assets ($class, $app) {
    die "install_assets requires a Mojolicious application\n"
        unless $app && $app->can('static');
    my $module_lib = path(__FILE__)->to_abs->dirname->dirname->dirname;
    my @candidates = (
        $module_lib->dirname->child('public'),
        $module_lib->child('auto', 'share', 'dist', 'Selecto-Components', 'public'),
    );
    my ($public_path) = grep { -d $_ } @candidates;
    die "Selecto API Console packaged browser assets were not found\n" unless $public_path;
    my $resolved = $public_path->to_string;
    unshift @{$app->static->paths}, $resolved
        unless grep { $_ eq $resolved } @{$app->static->paths};
    return $resolved;
}

sub page ($class, %options) {
    my $base_path = _base_path($options{base_path});
    my $title = _string($options{title} // 'Selecto API Console', 'title');
    my $theme = _theme($options{theme});
    my $shell = _page_shell($options{page_shell});
    my $style = _theme_style($theme);
    my $html_attributes = ' data-sac-color-scheme="' . html_escape($theme->{scheme}) . '"' .
        (length($style) ? ' style="' . html_escape($style) . '"' : '');
    my $body_classes = join ' ', grep { length } 'sac-body', $shell->{body_class} // '';
    my $content_classes = join ' ', grep { length } 'sac-app', $shell->{content_class} // '';
    return '<!doctype html><html lang="en"' . $html_attributes .
        '><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . html_escape($title) . '</title>' .
        ($shell->{head_start_html} // '') .
        '<link rel="stylesheet" href="/selecto-api-console/selecto-api-console.css?v=' .
        $ASSET_REVISION . '">' .
        '<script defer src="/selecto-api-console/selecto-api-console.js?v=' .
        $ASSET_REVISION . '"></script>' .
        ($shell->{head_html} // '') .
        '</head><body class="' . html_escape($body_classes) . '">' .
        ($shell->{body_start_html} // '') . '<main class="' .
        html_escape($content_classes) . '" ' .
        'data-selecto-api-console data-api-base="' . html_escape($base_path) .
        '" data-title="' . html_escape($title) . '">' .
        '<div class="sac-boot" role="status"><span class="sac-spinner" ' .
        'aria-hidden="true"></span><span>Reading the Selecto domain&hellip;</span></div>' .
        '<noscript><div class="sac-fatal">The Selecto API Console requires JavaScript.</div></noscript>' .
        '</main></body></html>';
}

sub _theme ($value) {
    $value //= {scheme => 'light'};
    die "theme must be an object\n" unless ref($value) eq 'HASH';
    my %theme = (scheme => $value->{scheme} // 'light');
    die "theme scheme must be light or dark\n"
        if ref($theme{scheme}) || "$theme{scheme}" !~ /\A(?:light|dark)\z/;
    for my $key (qw(primary secondary on_primary)) {
        next unless defined $value->{$key};
        die "theme $key must be a hexadecimal color\n"
            if ref($value->{$key}) || "$value->{$key}" !~ /\A#[0-9A-Fa-f]{6}\z/;
        $theme{$key} = uc "$value->{$key}";
    }
    return \%theme;
}

sub _theme_style ($theme) {
    my @properties;
    if (defined $theme->{primary}) {
        push @properties,
            '--sac-accent:' . $theme->{primary},
            '--cgt-brand:' . $theme->{primary};
    }
    my $secondary = $theme->{secondary} // $theme->{primary};
    if (defined $secondary) {
        push @properties,
            '--sac-teal:' . $secondary,
            '--cgt-accent:' . $secondary;
    }
    if (defined $theme->{on_primary}) {
        push @properties,
            '--sac-on-accent:' . $theme->{on_primary},
            '--cgt-on-brand:' . $theme->{on_primary};
    }
    return join ';', @properties;
}

sub _page_shell ($value) {
    return {} unless defined $value;
    die "page_shell must be an object\n" unless ref($value) eq 'HASH';
    my %known = map { $_ => 1 } qw(
        head_start_html head_html body_start_html body_class content_class
    );
    die "unknown page_shell setting\n" if grep { !$known{$_} } keys %$value;
    my %shell;
    for my $key (qw(head_start_html head_html body_start_html)) {
        next unless defined $value->{$key};
        die "page_shell $key must be a scalar\n" if ref($value->{$key});
        $shell{$key} = "$value->{$key}";
    }
    for my $key (qw(body_class content_class)) {
        next unless defined $value->{$key};
        die "page_shell $key must contain CSS class names\n"
            if ref($value->{$key})
                || "$value->{$key}" !~ /\A[A-Za-z0-9_-]+(?:\s+[A-Za-z0-9_-]+)*\z/;
        $shell{$key} = "$value->{$key}";
    }
    return \%shell;
}

sub _base_path ($value) {
    my $path = _string($value, 'base_path');
    $path =~ s{/+\z}{};
    die "base_path must be an absolute URL path\n"
        unless $path =~ m{\A/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]+\z}
            && index($path, '//') < 0
            && !grep { $_ eq '.' || $_ eq '..' } split m{/}, $path;
    return $path;
}

sub _string ($value, $label) {
    die "$label must be a non-empty string\n"
        if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

1;
