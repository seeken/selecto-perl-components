package Selecto::Components::Importer;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Selecto::Components::APIConsole ();
use Selecto::Components::Util qw(html_escape);
use Selecto::Components::ThemeStylesheet ();

my $ASSET_REVISION = '0.5.0-importer-17';

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
    my $theme_link = Selecto::Components::ThemeStylesheet->link_tag('console', $theme);
    my $html_attributes = ' data-sac-color-scheme="' . html_escape($theme->{scheme}) . '"';
    my $body_classes = join ' ', grep { length } 'sai-body', $shell->{body_class} // '';
    my $content_classes = join ' ', grep { length } 'sai-app', $shell->{content_class} // '';
    return '<!doctype html><html lang="en"' . $html_attributes . '><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . html_escape($title) . '</title>' .
        ($shell->{head_start_html} // '') .
        '<link rel="stylesheet" href="/selecto-api-console/selecto-importer.css?v=' . $ASSET_REVISION . '">' .
        $theme_link .
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

__END__

=head1 NAME

Selecto::Components::Importer - Serve the packaged Selecto Importer page

=head1 SYNOPSIS

    use Selecto::Components::Importer;

    Selecto::Components::Importer->install_assets(app);

    get '/api/orders/v1/import' => sub ($c) {
        $c->render(data => Selecto::Components::Importer->page(
            base_path  => '/api/orders/v1',
            title      => 'Import orders',
            csrf_token => $c->csrf_token,
        ), format => 'html');
    };

=head1 DESCRIPTION

The Importer is the API Console's companion page for importing CSV and TSV
files through a canonical Selecto HTTP API. Users inspect a file, map its
columns to fields, preview the rows and run the import. The API behind
C<base_path> must provide the HTTP import endpoints the page calls. The
parsing and preview logic is in L<Selecto::Importer>, but the routes belong
to the host API. Its browser code ships with this distribution under
C</selecto-api-console/selecto-importer.js>. This module renders the HTML
page that mounts it. The API must enforce authorization and validation for
every write.

=head1 METHODS

=head2 install_assets

    Selecto::Components::Importer->install_assets($app);

The same as L<Selecto::Components::APIConsole/install_assets>.

=head2 page

    my $html = Selecto::Components::Importer->page(%options);

Returns a complete HTML document. It accepts the same options as
L<Selecto::Components::APIConsole/page>: C<base_path> and C<csrf_token> are
required, and C<title> (default C<Importer>), C<curl_auth>, C<theme> and
C<page_shell> are optional.

=head1 SEE ALSO

L<Selecto::Components::APIConsole>, L<Selecto::Importer>, L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
