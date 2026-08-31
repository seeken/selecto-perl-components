package Selecto::Components::APIConsole;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::File qw(path);
use Selecto::Components::Util qw(html_escape);

my $ASSET_REVISION = '20260831-1';

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
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . html_escape($title) . '</title>' .
        '<link rel="stylesheet" href="/selecto-components/api-console.css?v=' .
        $ASSET_REVISION . '">' .
        '<script defer src="/selecto-components/api-console.js?v=' .
        $ASSET_REVISION . '"></script>' .
        '</head><body class="sac-body"><main class="sac-app" ' .
        'data-selecto-api-console data-api-base="' . html_escape($base_path) .
        '" data-title="' . html_escape($title) . '">' .
        '<div class="sac-boot" role="status"><span class="sac-spinner" ' .
        'aria-hidden="true"></span><span>Reading the Selecto domain&hellip;</span></div>' .
        '<noscript><div class="sac-fatal">The Selecto API Console requires JavaScript.</div></noscript>' .
        '</main></body></html>';
}

sub _base_path ($value) {
    my $path = _string($value, 'base_path');
    $path =~ s{/+\z}{};
    die "base_path must be an absolute URL path\n"
        unless $path =~ m{\A/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]+\z}
            && index($path, '//') < 0;
    return $path;
}

sub _string ($value, $label) {
    die "$label must be a non-empty string\n"
        if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

1;
