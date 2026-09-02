package Selecto::Components::Renderer;

use Mojo::Base -base, -signatures;
use Selecto::Components::Util qw(humanize html_escape);
use Selecto::Components::Renderer::Markup qw(_format_url _html_display);
use Selecto::Components::Renderer::Builder ();
use Selecto::Components::Renderer::Results ();
use Selecto::Components::Renderer::Debug ();

my $ASSET_REVISION = '20260901-5';

sub page ($class, $model) {
    my $config = $model->{config};
    my $localized_title = $config->localize(
        $model->{domain}, 'domain.title', $config->title,
        {kind => 'domain', id => $config->id, attribute => 'title'},
    );
    my $title = _h($localized_title);
    my $surface = $class->surface($model);
    my $ws_path = _h($config->path . '/ws');
    my $theme_style = $config->theme_style;
    my $theme_scheme = $config->theme_scheme;
    my $page_shell = $config->page_shell($model);
    my $theme_attribute = length($theme_style)
        ? ' style="' . _h($theme_style) . '"' : '';
    my $scheme_attribute = length($theme_scheme)
        ? ' data-sc-color-scheme="' . _h($theme_scheme) . '"' : '';
    my $body_class = length($page_shell->{body_class} // '')
        ? ' class="' . _h($page_shell->{body_class}) . '"' : '';
    my $main_class = 'sc-page';
    $main_class .= ' ' . $page_shell->{content_class}
        if length($page_shell->{content_class} // '');
    return '<!doctype html><html lang="en"' . $scheme_attribute . $theme_attribute .
        '><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . $title . '</title>' .
        ($page_shell->{head_start_html} // '') .
        '<link rel="stylesheet" href="/selecto-components/selecto-components.css?v=' . $ASSET_REVISION . '">' .
        '<script defer src="/selecto-components/htmx.min.js?v=' . $ASSET_REVISION . '"></script>' .
        '<script defer src="/selecto-components/hx-ws.min.js?v=' . $ASSET_REVISION . '"></script>' .
        '<script defer src="/selecto-components/chart.umd.min.js?v=' . $ASSET_REVISION . '"></script>' .
        '<script defer src="/selecto-components/selecto-components.js?v=' . $ASSET_REVISION . '"></script>' .
        ($page_shell->{head_html} // '') .
        '</head><body' . $body_class . '>' . ($page_shell->{body_start_html} // '') .
        '<main class="' . _h($main_class) . '"><div class="sc-shell">' .
        '<section id="selecto-channel-' . _h($config->id) . '" hx-ws:connect="' . $ws_path . '" hx-swap="none">' .
        $surface . '</section></div></main></body></html>';
}

sub surface ($class, $model) {
    my $config = $model->{config};
    my $state = $model->{state};
    return '<section id="selecto-surface-' . _h($config->id) . '" class="sc-surface">' .
        '<div class="sc-alert" role="alert">Explorer configuration is unavailable.</div></section>'
        unless $state && $model->{domain};
    my $field_catalog = $config->field_catalog($model->{domain});
    my $detail_catalog = $config->detail_column_catalog(
        $model->{domain}, $model->{available_actions} // [],
    );
    my $errors = join '', map { '<li>' . _h($_) . '</li>' } @{$state->errors};
    $errors .= '<li>' . _h($model->{runtime_error}) . '</li>' if $model->{runtime_error};
    my $alert = length($errors)
        ? '<div class="sc-alert" role="alert"><strong>Query stopped</strong><ul>' . $errors . '</ul></div>'
        : '';
    $alert .= '<div class="sc-action-notice" role="status">' . _h($model->{action_notice}) . '</div>'
        if defined($model->{action_notice}) && length($model->{action_notice});
    $alert .= '<div class="sc-alert" role="alert">' . _h($model->{action_error}) . '</div>'
        if defined($model->{action_error}) && length($model->{action_error});
    $alert .= '<div class="sc-action-notice" role="status">' . _h($model->{saved_query_notice}) . '</div>'
        if defined($model->{saved_query_notice}) && length($model->{saved_query_notice});
    $alert .= '<div class="sc-alert" role="alert">' . _h($model->{saved_query_error}) . '</div>'
        if defined($model->{saved_query_error}) && length($model->{saved_query_error});
    my $query_params = $config->query_params_enabled($model->{domain});
    my $export_links = join '', map {
        my ($format, $label) = @$_;
        '<a class="sc-button sc-secondary" data-sc-export-format="' . _h($format) .
            '" href="' . _h(_format_url($model->{canonical_url}, $format)) . '">' .
            _h($label) . '</a>'
    } ([xlsx => 'Excel'], [csv => 'CSV'], [tsv => 'TSV'], [json => 'JSON']);
    my $hero_actions = $query_params
        ? '<div class="sc-hero-actions"><a class="sc-button sc-secondary" href="' .
          _h($model->{canonical_url}) . '">Permalink</a><div class="sc-export-options" role="group" ' .
          'aria-label="Export all matched rows"><span>Export all</span>' . $export_links . '</div></div>'
        : '<div class="sc-hero-actions"><span class="sc-private-mode">Private URL mode</span></div>';
    my $builder_collapsed = _builder_collapsed($model);
    my $localized_title = $config->localize(
        $model->{domain}, 'domain.title', $config->title,
        {kind => 'domain', id => $config->id, attribute => 'title'},
    );
    my $builder_id = _h($config->id);
    my $tray_content_id = 'selecto-builder-tray-content-' . $builder_id;
    my $builder_toggle = '<button class="sc-builder-toggle" type="button" data-sc-builder-toggle ' .
        'data-sc-builder-id="' . $builder_id . '" aria-controls="' . $tray_content_id .
        '" aria-expanded="' . ($builder_collapsed ? 'false' : 'true') .
        '" aria-label="' . ($builder_collapsed ? 'Expand view menu' : 'Collapse view menu') . '">' .
        '<span data-sc-builder-chevron aria-hidden="true">' .
        ($builder_collapsed ? '&#8250;' : '&#8249;') . '</span></button>';
    my $connection = '<span class="sc-connection" data-selecto-connection role="status" ' .
        'aria-live="polite" aria-atomic="true">Connecting</span>';
    return '<section id="selecto-surface-' . _h($config->id) . '" class="sc-surface" data-selecto-url="' .
        _h($model->{canonical_url}) . '" data-sc-query-params="' .
        ($query_params ? 'enabled' : 'disabled') . '">' .
        '<header class="sc-hero"><div class="sc-hero-heading">' . $builder_toggle .
        '<h1>' . _h($localized_title) . '</h1>' . $connection . '</div>' .
        $hero_actions . '</header>' .
        $alert . '<div class="sc-workspace' . ($builder_collapsed ? ' is-builder-collapsed' : '') .
        '" data-sc-workspace>' .
        $class->_form($model, $field_catalog, $detail_catalog) .
        '<section class="sc-results" aria-live="polite">' .
        $class->_promoted_filter_header($model, $field_catalog) . $class->_results($model) . '</section>' .
        '</div></section>';
}

sub _builder_collapsed ($model) {
    my $input = $model->{input};
    return 0 unless ref($input) eq 'HASH' && exists($input->{q});
    my $value = $input->{q};
    $value = $value->[0] if ref($value) eq 'ARRAY';
    return defined($value) && !ref($value) && length("$value") && "$value" ne '0' ? 1 : 0;
}

sub websocket_message ($class, $model) {
    return {
        content => $class->surface($model),
        target => '#selecto-surface-' . $model->{config}->id,
        swap => 'outerHTML',
        selecto => { url => $model->{canonical_url} },
    };
}

sub _form ($class, @args) { return Selecto::Components::Renderer::Builder->_form(@args); }
sub _promoted_filter_header ($class, @args) { return Selecto::Components::Renderer::Builder->_promoted_filter_header(@args); }
sub _results ($class, @args) { return Selecto::Components::Renderer::Results->_results(@args); }
sub _table ($class, @args) { return Selecto::Components::Renderer::Results->_table(@args); }
sub _nested_table { return Selecto::Components::Renderer::Results::_nested_table(@_); }
sub _debug_panel ($class, @args) { return Selecto::Components::Renderer::Debug->_debug_panel(@args); }
sub _format_sql { return Selecto::Components::Renderer::Debug::_format_sql(@_); }

sub _humanize ($value) { return humanize($value); }
sub _h ($value) { return html_escape($value); }

1;
