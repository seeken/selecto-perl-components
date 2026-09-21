package Selecto::Components::Importer;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Selecto::Components::APIConsole ();
use Selecto::Components::Util qw(html_escape);

my $ASSET_REVISION = '0.5.0-importer-16';

sub install_assets ($class, $app) {
    return Selecto::Components::APIConsole->install_assets($app);
}

sub page ($class, %options) {
    my $base_path = $options{base_path};
    die "base_path must be an absolute URL path\n"
        unless defined($base_path) && !ref($base_path)
            && $base_path =~ m{\A/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]+\z}
            && index($base_path, '//') < 0;
    $base_path =~ s{/+\z}{};
    my $title = $options{title} // 'Importer';
    die "title must be a scalar\n" if ref($title);
    my $curl_auth = $options{curl_auth} // 'cookie';
    die "curl_auth must be basic, cookie, or none\n"
        unless $curl_auth =~ /\A(?:basic|cookie|none)\z/;
    my $csrf_token = $options{csrf_token};
    die "csrf_token must be a non-empty scalar\n"
        unless defined($csrf_token) && !ref($csrf_token) && length("$csrf_token");
    my $presentation = Selecto::Components::APIConsole->page_presentation(%options);
    my $theme = $presentation->{theme};
    my $shell = $presentation->{page_shell};
    my $style = $presentation->{theme_style};
    my $html_attributes = ' data-sac-color-scheme="' . html_escape($theme->{scheme}) . '"' .
        (length($style) ? ' style="' . html_escape($style) . '"' : '');
    my $body_classes = join ' ', grep { length } 'sai-body', $shell->{body_class} // '';
    my $content_classes = join ' ', grep { length } 'sai-app', $shell->{content_class} // '';
    return '<!doctype html><html lang="en"' . $html_attributes . '><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . html_escape($title) . '</title>' .
        ($shell->{head_start_html} // '') .
        '<link rel="stylesheet" href="/selecto-api-console/selecto-importer.css?v=' . $ASSET_REVISION . '">' .
        '<script defer src="/selecto-api-console/selecto-importer.js?v=' . $ASSET_REVISION . '"></script>' .
        ($shell->{head_html} // '') .
        '</head><body class="' . html_escape($body_classes) . '">' .
        ($shell->{body_start_html} // '') . '<main class="' . html_escape($content_classes) .
        '" data-selecto-importer data-api-base="' .
        html_escape($base_path) . '" data-title="' . html_escape($title) . '" data-curl-auth="' .
        html_escape($curl_auth) . '" data-csrf-token="' . html_escape($csrf_token) .
        '"><div role="status">Loading importer&hellip;</div></main></body></html>';
}

1;
