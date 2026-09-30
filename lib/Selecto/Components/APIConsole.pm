package Selecto::Components::APIConsole;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::File qw(path);
use Selecto::Components::Util qw(html_escape);

my $ASSET_REVISION = '0.5.4';

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
    my $title = _string($options{title} // 'API Console', 'title');
    my $curl_auth = _curl_auth($options{curl_auth});
    my $csrf_token = _string($options{csrf_token}, 'csrf_token');
    my $presentation = $class->page_presentation(%options);
    my $theme = $presentation->{theme};
    my $shell = $presentation->{page_shell};
    my $style = $presentation->{theme_style};
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
        '" data-title="' . html_escape($title) .
        '" data-curl-auth="' . html_escape($curl_auth) .
        '" data-csrf-token="' . html_escape($csrf_token) . '">' .
        '<div class="sac-boot" role="status"><span class="sac-spinner" ' .
        'aria-hidden="true"></span><span>Reading the Selecto domain&hellip;</span></div>' .
        '<noscript><div class="sac-fatal">The Selecto API Console requires JavaScript.</div></noscript>' .
        '</main></body></html>';
}

sub page_presentation ($class, %options) {
    my $theme = _theme($options{theme});
    return {
        theme => $theme,
        page_shell => _page_shell($options{page_shell}),
        theme_style => _theme_style($theme),
    };
}

sub _curl_auth ($value) {
    $value //= 'cookie';
    die "curl_auth must be basic, cookie, or none\n"
        if ref($value) || "$value" !~ /\A(?:basic|cookie|none)\z/;
    return "$value";
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

__END__

=head1 NAME

Selecto::Components::APIConsole - Serve the packaged Selecto API Console page

=head1 SYNOPSIS

    use Selecto::Components::APIConsole;

    Selecto::Components::APIConsole->install_assets(app);

    get '/api/orders/v1/console' => sub ($c) {
        $c->render(data => Selecto::Components::APIConsole->page(
            base_path  => '/api/orders/v1',
            title      => 'Orders API Console',
            csrf_token => $c->csrf_token,
            curl_auth  => 'cookie',
            theme      => {scheme => 'light', primary => '#0B5FFF'},
        ), format => 'html');
    };

=head1 DESCRIPTION

The Selecto API Console is a JavaScript application that works with any
canonical Selecto HTTP API. At startup it reads the API's base manifest,
C<domain> and C<openapi.json> resources, using same-origin credentials. From
these it builds controls for the public fields, types, named views,
projections, segments, parameters and orderings. It runs bounded queries
through the advertised versioned C<query> route and shows the results. No
domain-specific JavaScript is involved, and the UI cannot select an adapter,
a table, raw SQL or an unpublished identifier.

This distribution ships the generated console assets (built from the
C<selecto-api-console> project) under C</selecto-api-console/>. This module
renders the HTML page that mounts them. Hosts that are not built on
Mojolicious can serve the same files with this markup:

    <link rel="stylesheet" href="/selecto-api-console/selecto-api-console.css">
    <script defer src="/selecto-api-console/selecto-api-console.js"></script>
    <main data-selecto-api-console data-api-base="/api/orders/v1"
          data-curl-auth="basic" data-title="Orders API Console"></main>

A standalone page is also served at
C</selecto-api-console/index.html?api=/api/orders/v1>.

Explorers can link to a console with an C<api_console_resolver>
(L<Selecto::Components/api_console_resolver>). A Detail query is handed over
in the URL fragment, so it never reaches server logs. Aggregate and grid
drilldown queries cannot be expressed in the canonical API, so their API
button is disabled.

=head1 METHODS

=head2 install_assets

    my $public_dir = Selecto::Components::APIConsole->install_assets($app);

Adds the packaged C<public/> directory to C<< $app->static->paths >>, unless
it is already present, and returns the directory. The L<Selecto::Components>
plugin does this for you. Call it when you use the console without the
plugin.

=head2 page

    my $html = Selecto::Components::APIConsole->page(%options);

Returns a complete HTML document as a character string. The options are:

=over 4

=item base_path

Required. The absolute path of the canonical API, such as C</api/orders/v1>.
Trailing slashes are removed.

=item csrf_token

Required. It is passed to the console for state-changing requests.

=item title

The page title. Default C<API Console>.

=item curl_auth

How generated cURL commands authenticate: C<cookie> (the default, with a
session cookie placeholder), C<basic> (with username and password
placeholders) or C<none>.

=item theme

C<< {scheme => 'light'|'dark', primary, secondary, on_primary} >> with
C<#RRGGBB> colours. The default scheme is C<light>.

=item page_shell

C<< {head_start_html, head_html, body_start_html, body_class, content_class} >>.
This is trusted host markup and class names, with the same meaning as an
Explorer page shell (L<Selecto::Components/page_shell_resolver>). Unknown
keys die.

=back

=head2 page_presentation

    my $p = Selecto::Components::APIConsole->page_presentation(theme => ..., page_shell => ...);

Returns C<< {theme, page_shell, theme_style} >>, the validated theme, the
validated shell and the CSS custom properties. L<Selecto::Components::Importer>
uses it.

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::Components::Importer>, L<Selecto::API>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
