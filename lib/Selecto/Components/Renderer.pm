package Selecto::Components::Renderer;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(url_escape xml_escape);
use Selecto::QueryLibrary ();

my $ASSET_REVISION = '20260818-10';

sub page ($class, $model) {
    my $config = $model->{config};
    my $title = _h($config->title);
    my $surface = $class->surface($model);
    my $ws_path = _h($config->path . '/ws');
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . $title . '</title>' .
        '<link rel="stylesheet" href="/selecto-components/selecto-components.css?v=' . $ASSET_REVISION . '">' .
        '<script defer src="/selecto-components/htmx.min.js"></script>' .
        '<script defer src="/selecto-components/hx-ws.min.js"></script>' .
        '<script defer src="/selecto-components/chart.umd.min.js?v=' . $ASSET_REVISION . '"></script>' .
        '<script defer src="/selecto-components/selecto-components.js?v=' . $ASSET_REVISION . '"></script>' .
        '</head><body><main class="sc-page"><div class="sc-shell">' .
        '<header class="sc-masthead">' .
        '<span class="sc-connection" data-selecto-connection>Connecting</span></header>' .
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
          'aria-label="Export current page"><span>Export</span>' . $export_links . '</div></div>'
        : '<div class="sc-hero-actions"><span class="sc-private-mode">Private URL mode</span></div>';
    return '<section id="selecto-surface-' . _h($config->id) . '" class="sc-surface" data-selecto-url="' .
        _h($model->{canonical_url}) . '" data-sc-query-params="' .
        ($query_params ? 'enabled' : 'disabled') . '">' .
        '<header class="sc-hero"><div><h1>' . _h($config->title) . '</h1></div>' .
        $hero_actions . '</header>' .
        $alert . '<div class="sc-workspace">' .
        $class->_form($model, $field_catalog, $detail_catalog) .
        '<section class="sc-results" aria-live="polite">' . $class->_results($model) . '</section>' .
        '</div></section>';
}

sub _format_url ($canonical_url, $format) {
    my $separator = $canonical_url =~ /\?/ ? '&' : '?';
    return $canonical_url . $separator . 'format=' . $format;
}

sub websocket_message ($class, $model, $request_id = undef) {
    my $message = {
        content => $class->surface($model),
        target => '#selecto-surface-' . $model->{config}->id,
        swap => 'outerHTML',
        selecto => { url => $model->{canonical_url} },
    };
    $message->{'HX-Request-ID'} = "$request_id" if defined($request_id) && !ref($request_id);
    return $message;
}

sub _form ($class, $model, $catalog, $detail_catalog = undef) {
    my $config = $model->{config};
    my $state = $model->{state};
    my $method = $config->query_params_enabled($model->{domain}) ? 'get' : 'post';
    my $detail_active = $state->view eq 'detail';
    my $views = join '', map {
        '<label class="sc-view-tab"><input type="radio" name="view" value="' . _h($_) . '"' .
        ($_ eq $state->view ? ' checked' : '') . '><span>' . _h(_humanize($_)) . '</span></label>'
    } @{$config->views};
    my $measure_catalog = $config->measure_catalog($model->{domain});
    my $filter_picker = $class->_filter_picker($state, $catalog, $config);
    my $query_library_picker = $class->_query_library_picker($state, $model->{domain});
    my $detail_controls = $class->_field_picker($state, $detail_catalog // $catalog, $config) .
        $class->_order_picker($state, $catalog, $config->max_orders) .
        _measure_selection_hidden($state) .
        _selection_hidden('group', $state->groups, $state->group_configs);
    my $summary_controls = $class->_chart_type_picker($state) .
        $class->_group_picker($state, $catalog, $config) .
        $class->_measure_picker($state, $measure_catalog, $config) .
        _selection_hidden('field', $state->fields, $state->field_configs) .
        join('', map {
            _hidden('order', $_->{field}) . _hidden('direction', $_->{direction})
        } @{$state->orders});
    my $view_controls = '<fieldset class="sc-result-view-controls" data-sc-result-view-panel="detail"' .
        ($detail_active ? '' : ' hidden disabled') . '>' . $detail_controls . '</fieldset>' .
        '<fieldset class="sc-result-view-controls" data-sc-result-view-panel="summary"' .
        ($detail_active ? ' hidden disabled' : '') . '>' . $summary_controls . '</fieldset>';
    my $builder_id = _h($config->id);
    my $view_tab_id = 'selecto-builder-view-tab-' . $builder_id;
    my $filter_tab_id = 'selecto-builder-filters-tab-' . $builder_id;
    my $view_panel_id = 'selecto-builder-view-panel-' . $builder_id;
    my $filter_panel_id = 'selecto-builder-filters-panel-' . $builder_id;
    my $builder_tabs = '<div class="sc-builder-tabs" role="tablist" aria-label="Explorer sections">' .
        '<button class="sc-builder-tab" type="button" role="tab" id="' . $view_tab_id .
        '" aria-controls="' . $view_panel_id . '" aria-selected="true" data-sc-builder-tab="view">View</button>' .
        '<button class="sc-builder-tab" type="button" role="tab" id="' . $filter_tab_id .
        '" aria-controls="' . $filter_panel_id . '" aria-selected="false" data-sc-builder-tab="filters">' .
        'Filters <span>' . scalar(@{$state->filters}) . '</span></button>' .
        (length($query_library_picker)
            ? '<button class="sc-builder-tab" type="button" role="tab" id="selecto-builder-library-tab-' .
              $builder_id . '" aria-controls="selecto-builder-library-panel-' . $builder_id .
              '" aria-selected="false" data-sc-builder-tab="library">Query Library</button>'
            : '') . '</div>';
    my $view_panel = '<section class="sc-builder-panel" role="tabpanel" id="' . $view_panel_id .
        '" aria-labelledby="' . $view_tab_id . '" data-sc-builder-panel="view">' .
        '<div class="sc-view-tabs" role="radiogroup" aria-label="Result view">' . $views . '</div>' .
        $view_controls . '</section>';
    my $filter_panel = '<section class="sc-builder-panel" role="tabpanel" id="' . $filter_panel_id .
        '" aria-labelledby="' . $filter_tab_id . '" data-sc-builder-panel="filters" hidden>' .
        $filter_picker . '</section>';
    my $library_panel = length($query_library_picker)
        ? '<section class="sc-builder-panel" role="tabpanel" id="selecto-builder-library-panel-' .
          $builder_id . '" aria-labelledby="selecto-builder-library-tab-' . $builder_id .
          '" data-sc-builder-panel="library" hidden>' . $query_library_picker . '</section>'
        : '';
    return '<aside class="sc-builder"><form id="selecto-query-' . _h($config->id) . '" action="' .
        _h($config->path) . '" method="' . $method . '" hx-ws:send hx-trigger="submit" data-sc-builder="' .
        $builder_id . '">' . _hidden('q', 1) . _hidden('query_signature', $state->query_signature) .
        $builder_tabs . $view_panel . $filter_panel . $library_panel .
        '<div class="sc-builder-apply-note"><span>Changes apply only when you run the query.</span>' .
        '<strong data-sc-builder-pending hidden>Pending changes</strong></div>' .
        '<div class="sc-control-row"><label>Rows<select name="limit">' . _limit_options($state, $config) . '</select></label>' .
        '<label>Page<input name="page" inputmode="numeric" value="' . _h($state->page) . '"></label></div>' .
        '<button class="sc-button sc-primary" type="submit">Run query</button>' .
        '<noscript><p class="sc-note">JavaScript is off; this form still runs as a normal GET.</p></noscript></form></aside>';
}

sub _query_library_picker ($class, $state, $domain) {
    my $library = Selecto::QueryLibrary->library($domain);
    my @views = sort keys %{$library->{views}};
    my @segments = sort keys %{$library->{segments}};
    return '' unless @views || @segments;

    my $selected_view = $state->query_library_view // '';
    my %selected_segment = map { $_ => 1 } @{$state->query_library_segments // []};
    my $view_options = '<option value=""' . ($selected_view eq '' ? ' selected' : '') .
        '>No named view</option>' . join('', map {
            my $spec = $library->{views}{$_};
            '<option value="' . _h($_) . '"' . ($selected_view eq $_ ? ' selected' : '') . '>' .
                _h(_definition_label($_, $spec)) . '</option>'
        } @views);
    my $view_description = '';
    if (length($selected_view) && ref($library->{views}{$selected_view}) eq 'HASH') {
        my $spec = $library->{views}{$selected_view};
        my $description = _definition_text($spec->{description});
        my $capability = _definition_text($spec->{capability});
        $view_description = '<div class="sc-query-library-summary"><strong>' .
            _h(_definition_label($selected_view, $spec)) . '</strong>' .
            (length($description) ? '<p>' . _h($description) . '</p>' : '') .
            (length($capability) ? '<small>Capability metadata: ' . _h($capability) . '</small>' : '') .
            '</div>';
    }

    my $segment_choices = join('', map {
        my $id = $_;
        my $spec = $library->{segments}{$id};
        my $description = _definition_text($spec->{description});
        my $capability = _definition_text($spec->{capability});
        '<label class="sc-query-library-choice"><input type="checkbox" name="query_library_segment" value="' .
            _h($id) . '"' . ($selected_segment{$id} ? ' checked' : '') . '><span><strong>' .
            _h(_definition_label($id, $spec)) . '</strong>' .
            (length($description) ? '<small>' . _h($description) . '</small>' : '') .
            (length($capability) ? '<small>Capability metadata: ' . _h($capability) . '</small>' : '') .
            '</span></label>'
    } @segments);

    my $parameters = '';
    my $parameter_specs = {};
    my $spec_ok = eval {
        $parameter_specs = Selecto::QueryLibrary->parameter_specs(
            $domain,
            (length($selected_view) ? (view => $selected_view) : ()),
            segments => [keys %selected_segment],
        );
        1;
    };
    if ($spec_ok) {
        $parameters = join('', map {
            my $id = $_;
            my $spec = $parameter_specs->{$id};
            my $type = lc(_definition_text($spec->{type}) || 'string');
            my $input_type = $type =~ /\A(?:integer|float|decimal)\z/ ? 'number'
                : $type eq 'date' ? 'date'
                : $type =~ /datetime/ ? 'datetime-local' : 'text';
            my $value = exists($state->query_library_parameters->{$id})
                ? $state->query_library_parameters->{$id}
                : defined($spec->{default}) && !ref($spec->{default}) ? $spec->{default} : '';
            my $required = ($spec->{required} // !exists($spec->{default})) ? ' required' : '';
            my $control = $type eq 'boolean'
                ? '<select name="query_library_param_value"' . $required . '><option value="false"' .
                  ("$value" =~ /\A(?:0|false|off|no)\z/i ? ' selected' : '') . '>False</option>' .
                  '<option value="true"' . ("$value" =~ /\A(?:1|true|on|yes)\z/i ? ' selected' : '') .
                  '>True</option></select>'
                : '<input type="' . $input_type . '" name="query_library_param_value" value="' .
                  _h($value) . '"' . ($type =~ /\A(?:float|decimal)\z/ ? ' step="any"' : '') . $required . '>';
            '<label><span>' . _h(_definition_label($id, $spec)) .
                (($spec->{required} // !exists($spec->{default})) ? ' *' : '') . '</span>' .
                _hidden('query_library_param_name', $id) . $control . '</label>'
        } sort keys %$parameter_specs);
    }

    return '<div class="sc-query-library"><p class="sc-picker-hint">Named views seed editable Detail columns and ordering. Named segments remain active alongside visual filters.</p>' .
        (@views ? '<label>Named view<select name="query_library_view">' . $view_options . '</select></label>' .
          (length($selected_view) ? _hidden('query_library_materialized_view', $selected_view) : '') : '') .
        $view_description .
        (@segments ? '<fieldset><legend>Additional named segments</legend><div class="sc-query-library-choices">' .
            $segment_choices . '</div></fieldset>' : '') .
        (length($parameters) ? '<fieldset><legend>Parameters</legend><div class="sc-query-library-parameters">' .
            $parameters . '</div></fieldset>' : '') . '</div>';
}

sub _definition_label ($id, $spec) {
    return _definition_text($spec->{label}) || _humanize($id);
}

sub _definition_text ($value) {
    return '' unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

sub _chart_type_picker ($class, $state) {
    my @types = (
        [bar => 'Bar'],
        [horizontal_bar => 'Horizontal bar'],
        [stacked_bar => 'Stacked bar'],
        [line => 'Line'],
        [area => 'Area'],
        [pie => 'Pie'],
        [doughnut => 'Doughnut'],
        [scatter => 'Scatter'],
    );
    my $options = join '', map {
        '<option value="' . _h($_->[0]) . '"' .
            ($state->chart_type eq $_->[0] ? ' selected' : '') . '>' .
            _h($_->[1]) . '</option>'
    } @types;
    my $inactive = $state->view eq 'graph' ? '' : ' hidden disabled';
    return '<fieldset class="sc-chart-type-picker" data-sc-graph-options' . $inactive . '>' .
        '<legend>Chart</legend><label>Chart type<select name="chart_type" ' .
        'data-sc-chart-type-picker>' . $options . '</select></label>' .
        '<p>Choose a dashboard visualization for the selected groups and measures.</p></fieldset>';
}

sub _field_picker ($class, $state, $catalog, $config) {
    return $class->_selection_picker(
        $state,
        $catalog,
        kind => 'field',
        legend => 'Columns',
        selected => $state->fields,
        configs => $state->field_configs,
        maximum => scalar(@$catalog),
        search_label => 'Filter available fields',
        hint => 'Drag or use arrows to reorder columns. Configure labels and date formats per column.',
        set_label => 'Set columns',
        date_formats => $config->date_formats,
    );
}

sub _group_picker ($class, $state, $catalog, $config) {
    return $class->_selection_picker(
        $state,
        $catalog,
        kind => 'group',
        legend => 'Group by',
        selected => $state->groups,
        configs => $state->group_configs,
        maximum => 3,
        search_label => 'Filter available group fields',
        hint => 'Choose up to three groups. Configure numeric, date, year, age, or text-prefix buckets.',
        set_label => 'Set group columns',
        date_formats => $config->date_formats,
        config => $config,
    );
}

sub _measure_picker ($class, $state, $catalog, $config) {
    return $class->_selection_picker(
        $state,
        $catalog,
        kind => 'measure',
        legend => 'Measures',
        selected => $state->measures,
        configs => $state->measure_configs,
        maximum => $config->max_measures,
        search_label => 'Filter available aggregate columns',
        hint => 'Choose domain columns or curated presets, then configure functions, aliases, and buckets.',
        set_label => 'Set measures',
        config => $config,
    );
}

sub _order_picker ($class, $state, $catalog, $maximum) {
    my @selected = map { $_->{field} } @{$state->orders};
    my %configs = map { $_->{field} => { direction => $_->{direction} } } @{$state->orders};
    return $class->_selection_picker(
        $state,
        $catalog,
        kind => 'order',
        legend => 'Order by',
        selected => \@selected,
        configs => \%configs,
        maximum => $maximum,
        search_label => 'Filter available sort fields',
        hint => 'Earlier fields have higher sort priority.',
        set_label => 'Set sort fields',
    );
}

sub _selection_picker ($class, $state, $catalog, %options) {
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my $kind = $options{kind};
    my $selected_values = $options{selected};
    my $configs = $options{configs};
    my %selected = map { $_ => 1 } @$selected_values;
    my @available = grep { !$selected{$_->{path}} } @$catalog;
    my $at_limit = @$selected_values >= $options{maximum};
    my $available_items = join '', map {
        '<button class="sc-picker-choice" type="button" data-sc-picker-action="add"' .
        ($at_limit ? ' disabled' : '') . ' ' .
        'data-sc-picker-available-item data-field="' . _h($_->{path}) . '" data-label="' .
        _h($_->{label}) . '" data-type="' . _h($_->{type}) . '" data-search="' .
        _h(lc($_->{label} . ' ' . $_->{type})) . '" data-default-function="' .
        _h($_->{default_function} // '') . '" data-measure-field="' .
        _h($_->{field} // '') . '"><span><strong>' . _h($_->{label}) .
        '</strong><small>' . _h($_->{type}) . '</small></span><span aria-hidden="true">+</span></button>'
    } @available;
    $available_items ||= '<p class="sc-picker-empty">Every available field is set.</p>';

    my $selected_count = scalar @$selected_values;
    my $set_items = join '', map {
        my $index = $_;
        my $path = $selected_values->[$index];
        my $field = $by_path{$path} // {
            path => $path,
            label => 'Unavailable action',
            type => 'action',
        };
        my $item_config = $configs->{$path} // {};
        my $up_disabled = $index == 0 ? ' disabled' : '';
        my $down_disabled = $index == $selected_count - 1 ? ' disabled' : '';
        my $remove_disabled = $selected_count == 1 ? ' disabled' : '';
        my $config_controls;
        if ($kind eq 'order') {
            my $direction = $item_config->{direction} // 'asc';
            $config_controls = '<label class="sc-order-direction">Direction<select name="direction" ' .
                'aria-label="Direction for ' . _h($field->{label}) . '"><option value="asc"' .
                ($direction eq 'asc' ? ' selected' : '') . '>Ascending</option><option value="desc"' .
                ($direction eq 'desc' ? ' selected' : '') . '>Descending</option></select></label>';
        } else {
            $config_controls = _picker_config_controls(
                $options{config}, $kind, $field, $item_config, $options{date_formats}
            );
        }
        '<article class="sc-picker-set-item" draggable="true" data-sc-picker-set-item data-field="' .
        _h($path) . '" data-label="' . _h($field->{label}) . '" data-type="' . _h($field->{type}) .
        '" data-default-function="' . _h($field->{default_function} // '') .
        '" data-measure-field="' . _h($field->{field} // '') .
        '"><input type="hidden" name="' . _h($kind) . '" value="' . _h($path) . '">' .
        '<button class="sc-picker-grip" type="button" title="Drag to reorder" aria-label="Drag ' .
        _h($field->{label}) . ' to reorder">⠿</button><span class="sc-picker-set-label"><strong>' .
        _h($field->{label}) . '</strong><small>' . _h($field->{type}) . '</small></span>' .
        '<span class="sc-picker-controls">' .
        '<button type="button" data-sc-picker-action="up" aria-label="Move ' . _h($field->{label}) .
        ' up" title="Move up"' . $up_disabled . '>↑</button>' .
        '<button type="button" data-sc-picker-action="down" aria-label="Move ' . _h($field->{label}) .
        ' down" title="Move down"' . $down_disabled . '>↓</button>' .
        '<button type="button" data-sc-picker-action="remove" aria-label="Remove ' . _h($field->{label}) .
        '" title="Remove"' . $remove_disabled . '>×</button></span>' . $config_controls . '</article>'
    } 0 .. $selected_count - 1;
    $set_items ||= '<p class="sc-picker-empty">Choose fields from Available.</p>';

    return '<fieldset class="sc-picker-fieldset"><legend>' . _h($options{legend}) .
        ' <small>up to ' . _h($options{maximum}) . '</small></legend>' .
        '<div class="sc-list-picker" data-sc-picker-root data-sc-picker-kind="' . _h($kind) .
        '" data-sc-picker-max="' . _h($options{maximum}) . '">' .
        '<section class="sc-picker-pane"><div class="sc-picker-heading"><span>Available</span>' .
        '<span data-sc-picker-available-count>' . scalar(@available) . '</span></div>' .
        '<input class="sc-picker-filter" type="search" ' .
        'data-sc-picker-filter placeholder="' . _h($options{search_label}) . '" aria-label="' .
        _h($options{search_label}) . '">' .
        '<div class="sc-picker-list" data-sc-picker-available>' . $available_items . '</div></section>' .
        '<section class="sc-picker-pane sc-picker-set-pane"><div class="sc-picker-heading"><span>Set</span>' .
        '<span data-sc-picker-set-count>' . $selected_count . '</span></div>' .
        '<p class="sc-picker-hint">' . _h($options{hint}) . '</p>' .
        '<div class="sc-picker-list sc-picker-set" data-sc-picker-set aria-label="' .
        _h($options{set_label}) . '">' .
        $set_items . '</div></section></div></fieldset>';
}

sub _picker_config_controls ($config, $kind, $field, $item_config, $date_formats) {
    return _hidden('field_alias', '') . _hidden('field_format', '')
        if $kind eq 'field' && $field->{type} eq 'action';
    my $alias = $item_config->{alias} // '';
    my $label_text = $kind eq 'measure' ? 'Measure label' : 'Column label';
    my $controls = '<label>' . $label_text . '<input name="' . _h($kind . '_alias') .
        '" value="' . _h($alias) . '" maxlength="80" aria-label="' . $label_text .
        ' for ' . _h($field->{label}) . '"></label>';

    if ($kind eq 'field') {
        my $format = $item_config->{format} // '';
        if ($field->{type} =~ /(?:date|time)/i) {
            my $options = '<option value=""' . ($format eq '' ? ' selected' : '') . '>Default</option>' .
                join('', map {
                    '<option value="' . _h($_->{id}) . '"' .
                    ($_->{id} eq $format ? ' selected' : '') . '>' . _h($_->{label}) . '</option>'
                } @{$date_formats // []});
            $controls .= '<label>Date format<select name="field_format" aria-label="Date format for ' .
                _h($field->{label}) . '">' . $options . '</select></label>';
        } else {
            $controls .= _hidden('field_format', '');
        }
    } elsif ($kind eq 'group') {
        my $format = $item_config->{format} // '';
        my $format_options = join '', map {
            my ($value, $text) = @$_;
            $value = '' if $value eq 'default';
            '<option value="' . _h($value) . '"' . ($value eq $format ? ' selected' : '') . '>' .
                _h($text) . '</option>'
        } @{$config->group_formats($field->{type})};
        my $bucket_visible = $format =~ /\A(?:buckets|age_buckets|custom_buckets|year_buckets)\z/;
        my $prefix_visible = $format eq 'text_prefix';
        $controls .= '<label>Format<select name="group_format" data-sc-group-format aria-label="Group format for ' .
            _h($field->{label}) . '">' . $format_options . '</select></label>' .
            '<label data-sc-group-buckets' . ($bucket_visible ? '' : ' hidden') . '>Bucket ranges' .
            '<input name="group_bucket_ranges" value="' . _h($item_config->{bucket_ranges} // '') .
            '" placeholder="1, 2-5, 6-14, 15+ or */10" aria-label="Bucket ranges for ' .
            _h($field->{label}) . '"></label>' .
            '<label data-sc-group-prefix' . ($prefix_visible ? '' : ' hidden') . '>Prefix length' .
            '<input type="number" min="1" max="10" name="group_prefix_length" value="' .
            _h($item_config->{prefix_length} // 2) . '" aria-label="Prefix length for ' .
            _h($field->{label}) . '"></label>' .
            '<label data-sc-group-prefix' . ($prefix_visible ? '' : ' hidden') . '>Leading articles' .
            '<select name="group_exclude_articles" aria-label="Leading articles for ' .
            _h($field->{label}) . '"><option value="1"' .
            ($item_config->{exclude_articles} ? ' selected' : '') . '>Exclude a, an, the</option>' .
            '<option value="0"' . ($item_config->{exclude_articles} ? '' : ' selected') .
            '>Keep articles</option></select></label>';
    } elsif ($kind eq 'measure') {
        my $function = $item_config->{function} // $field->{default_function} // 'count';
        my $functions = join '', map {
            '<option value="' . _h($_->[0]) . '"' .
            ($_->[0] eq $function ? ' selected' : '') . '>' . _h($_->[1]) . '</option>'
        } @{$config->measure_functions($field->{type}, $field->{type} eq 'rows')};
        my $bucket_visible = $function eq 'buckets' || $function eq 'age_buckets';
        my $sum_visible = $function eq 'sum';
        $controls .= '<label>Function<select name="measure_function" data-sc-measure-function ' .
            'aria-label="Measure function for ' . _h($field->{label}) . '">' . $functions .
            '</select></label><label data-sc-measure-buckets' . ($bucket_visible ? '' : ' hidden') .
            '>Bucket ranges<input name="measure_bucket_ranges" value="' .
            _h($item_config->{bucket_ranges} // '') .
            '" placeholder="0-10, 11-50, 51+" aria-label="Measure bucket ranges for ' .
            _h($field->{label}) . '"></label><label data-sc-measure-sum' .
            ($sum_visible ? '' : ' hidden') . '>NULL handling<select name="measure_ignore_nulls" ' .
            'aria-label="NULL handling for ' . _h($field->{label}) . '"><option value="0"' .
            ($item_config->{ignore_nulls} ? '' : ' selected') . '>Keep SQL SUM behavior</option>' .
            '<option value="1"' . ($item_config->{ignore_nulls} ? ' selected' : '') .
            '>Treat NULL as 0</option></select></label>';
    }

    return '<details class="sc-column-config"><summary>Configure</summary>' .
        '<div class="sc-column-config-grid">' . $controls . '</div></details>';
}

sub _filter_picker ($class, $state, $catalog, $config) {
    my $max_filters = $config->max_filters;
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my %selected = map { $_->{field} => 1 } @{$state->filters};
    my @available = grep { !$selected{$_->{path}} } @$catalog;
    my $at_limit = @{$state->filters} >= $max_filters;
    my $available_items = $at_limit ? '' : join '', map {
        '<button class="sc-picker-choice" type="button" data-sc-filter-action="add" ' .
        'data-sc-filter-available-item data-field="' . _h($_->{path}) . '" data-label="' .
        _h($_->{label}) . '" data-type="' . _h($_->{type}) . '" data-search="' .
        _h(lc($_->{label} . ' ' . $_->{type})) . '"><span><strong>' . _h($_->{label}) .
        '</strong><small>' . _h($_->{type}) . '</small></span><span aria-hidden="true">+</span></button>'
    } @available;
    $available_items ||= '<p class="sc-picker-empty">' .
        ($at_limit ? 'Maximum of ' . _h($max_filters) . ' filters set.' : 'Every available filter is set.') .
        '</p>';

    my $set_items = join '', map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        my $ops = join '', map {
            '<option value="' . $_->[0] . '"' . ($_->[0] eq $filter->{op} ? ' selected' : '') . '>' .
            _h($_->[1]) . '</option>'
        } @{$filter->{grouped} ? [[eq => 'is grouped as']] : $config->filter_operators($field->{type})};
        my $filter_controls = $filter->{grouped}
            ? _hidden('filter_op', $filter->{op}) . _hidden('filter_value', $filter->{value}) .
              _hidden('filter_value_end', '') . '<p class="sc-filter-value-note">Aggregate value: <strong>' .
              _h(defined($filter->{value}) && length($filter->{value}) ? $filter->{value} : '(empty)') .
              '</strong></p>'
            : '<label>Operator<select name="filter_op" aria-label="Operator for ' .
              _h($field->{label}) . '">' . $ops . '</select></label>' .
              $class->_filter_value_controls($config, $field, $filter);
        '<article class="sc-filter-set-item' . ($filter->{draft} ? ' is-draft' : '') .
        '" data-sc-filter-set-item' . ($filter->{grouped} ? ' data-sc-grouped-filter' : '') .
        ' data-field="' . _h($filter->{field}) . '" data-label="' .
        _h($field->{label}) . '" data-type="' . _h($field->{type}) . '">' .
        '<input type="hidden" name="filter_field" value="' . _h($filter->{field}) . '">' .
        _hidden('filter_group', $filter->{grouped} ? 1 : 0) .
        '<div class="sc-filter-set-heading"><span><strong>' . _h($field->{label}) . '</strong><small>' .
        _h($field->{type}) . '</small></span><button type="button" data-sc-filter-action="remove" ' .
        'aria-label="Remove ' . _h($field->{label}) . ' filter" title="Remove filter">×</button></div>' .
        '<div class="sc-filter-editor">' . $filter_controls . '</div>' .
        ($filter->{draft} ? '<p class="sc-filter-draft-note">' .
            _h($filter->{op} eq 'between' ? 'Enter both values to apply this filter.'
                : 'Enter a value to apply this filter.') . '</p>' : '') .
        '</article>'
    } @{$state->filters};
    $set_items ||= '<p class="sc-picker-empty">Choose fields from Available to build filters.</p>';

    return '<fieldset class="sc-picker-fieldset"><legend>Filters <small>up to ' . _h($max_filters) .
        '</small></legend><div class="sc-list-picker sc-filter-picker" data-sc-filter-root data-sc-filter-max="' .
        _h($max_filters) . '"><section class="sc-picker-pane"><div class="sc-picker-heading">' .
        '<span>Available</span><span data-sc-filter-available-count>' .
        ($at_limit ? 0 : scalar(@available)) . '</span></div><input class="sc-picker-filter" type="search" ' .
        'data-sc-filter-search placeholder="Filter available filters" aria-label="Filter available filters">' .
        '<div class="sc-picker-list" data-sc-filter-available>' . $available_items . '</div></section>' .
        '<section class="sc-picker-pane sc-picker-set-pane"><div class="sc-picker-heading"><span>Set</span>' .
        '<span data-sc-filter-set-count>' . scalar(@{$state->filters}) . '</span></div>' .
        '<p class="sc-picker-hint">Set filters are combined with AND.</p>' .
        '<div class="sc-picker-list sc-filter-set" data-sc-filter-set aria-label="Set filters">' .
        $set_items . '</div></section></div></fieldset>';
}

sub _filter_value_controls ($class, $config, $field, $filter) {
    my $operator = $filter->{op};
    my $value = $filter->{value} // '';
    my $value_end = $filter->{value_end} // '';
    my $label = $field->{label};
    my $type = $field->{type};
    my $input_type = $config->filter_input_type($type);
    my $step = $input_type eq 'number' ? ' step="any"' : '';
    my $controls = '<div class="sc-filter-values" data-sc-filter-values>';

    if ($operator =~ /_null\z/) {
        return $controls . _hidden('filter_value', '') . _hidden('filter_value_end', '') .
            '<p class="sc-filter-value-note">No value needed.</p></div>';
    }
    if ($operator eq 'date_shortcut') {
        my $options = '';
        my $group = '';
        for my $shortcut (@{$config->date_shortcuts}) {
            if ($shortcut->{group} ne $group) {
                $options .= '</optgroup>' if length($group);
                $group = $shortcut->{group};
                $options .= '<optgroup label="' . _h($group) . '">';
            }
            $options .= '<option value="' . _h($shortcut->{id}) . '"' .
                ($shortcut->{id} eq $value ? ' selected' : '') . '>' .
                _h($shortcut->{label}) . '</option>';
        }
        $options .= '</optgroup>' if length($group);
        return $controls . '<label class="sc-filter-value-wide">Period<select name="filter_value" ' .
            'aria-label="Period for ' . _h($label) . '">' . $options . '</select></label>' .
            _hidden('filter_value_end', '') . '</div>';
    }
    if ($operator eq 'between') {
        return $controls . '<label>Start<input type="' . $input_type . '" name="filter_value" ' .
            'aria-label="Start value for ' . _h($label) . '" value="' . _h($value) . '"' . $step .
            '></label><label>End<input type="' . $input_type . '" name="filter_value_end" ' .
            'aria-label="End value for ' . _h($label) . '" value="' . _h($value_end) . '"' . $step .
            '></label></div>';
    }
    if ($config->boolean_type($type)) {
        return $controls . '<label class="sc-filter-value-wide">Value<select name="filter_value" ' .
            'aria-label="Value for ' . _h($label) . '"><option value=""' .
            (!length($value) ? ' selected' : '') . '>Choose true or false</option><option value="true"' .
            (lc($value) eq 'true' || $value eq '1' ? ' selected' : '') . '>True</option>' .
            '<option value="false"' . (lc($value) eq 'false' || $value eq '0' ? ' selected' : '') .
            '>False</option></select></label>' . _hidden('filter_value_end', '') . '</div>';
    }
    my $placeholder = $operator eq 'in' ? 'Comma-separated values'
        : $config->temporal_type($type) ? 'Choose a date' : 'Enter a value';
    my $effective_type = $operator eq 'in' ? 'text' : $input_type;
    my $effective_step = $effective_type eq 'number' ? ' step="any"' : '';
    return $controls . '<label class="sc-filter-value-wide">Value<input type="' . $effective_type .
        '" name="filter_value" aria-label="Value for ' . _h($label) . '" value="' . _h($value) .
        '" placeholder="' . _h($placeholder) . '"' . $effective_step . '></label>' .
        _hidden('filter_value_end', '') . '</div>';
}

sub _results ($class, $model) {
    return '<div class="sc-empty"><h2>Query unavailable</h2><p>Correct the controls and try again.</p></div>'
        unless $model->{state}->valid && $model->{result};
    my $result = $model->{result};
    my $heading = $model->{state}->view eq 'detail' ? 'Detail results'
        : $model->{state}->view eq 'aggregate' ? 'Aggregate results' : 'Graph results';
    my $row_label = $result->{total_count} == 1 ? 'row matched' : 'rows matched';
    my $page_label = $result->{total_pages} == 1 ? 'page' : 'pages';
    my $meta = '<div class="sc-result-meta"><div><h2>' . _h($heading) .
        '</h2></div><div><strong>' . _h($result->{total_count}) . '</strong> ' . $row_label .
        ' · <strong>' . _h($result->{total_pages}) . '</strong> ' . $page_label .
        ' · <strong>' . _h($result->{elapsed_ms}) . ' ms</strong> query time</div></div>';
    my $actions = $model->{state}->view eq 'detail'
        ? $class->_bulk_actions($model) : '';
    my $body = $result->{graph} ? $class->_graph($result, $model) : $class->_table($result, $model);
    my $pagination = $class->_pagination($model);
    my $debug = '';
    if ($model->{config}->show_sql && defined $result->{sql}) {
        $debug = '<details class="sc-debug"><summary>Compiled SQL and bound parameters</summary><pre>' .
            _h($result->{sql}) . "\n\n" . _h(join("\n", map { defined($_) ? "$_" : 'NULL' } @{$result->{params}})) .
            '</pre></details>';
    }
    return $meta . $actions . $body . $pagination . $debug;
}

sub _bulk_actions ($class, $model) {
    my $actions = $model->{bulk_actions} // [];
    return '' unless @$actions && $model->{result} && defined($model->{result}{action_key});
    my $config = $model->{config};
    my $panels = '';
    for my $action (@$actions) {
        my $id = $action->{id};
        my $dialog_id = 'selecto-action-' . $config->id . '-' . $id;
        my $enabled = ($action->{status} // 'enabled') eq 'enabled';
        my $button = '<button type="button" class="sc-button sc-secondary" data-sc-action-open="' .
            _h($dialog_id) . '" data-sc-action-disabled="' . ($enabled ? '0' : '1') . '" disabled' .
            ($enabled ? '' : ' title="' . _h($action->{status_reason} // 'Action unavailable') . '"') .
            '>' . _h($action->{label}) . '</button>';
        my $inputs = join '', map { _action_input($_) } @{$action->{inputs}};
        my $description = length($action->{description} // '')
            ? '<p class="sc-action-description">' . _h($action->{description}) . '</p>' : '';
        my $dialog = '<dialog class="sc-action-dialog" id="' . _h($dialog_id) . '" data-sc-action-dialog>' .
            '<form method="post" action="' . _h($config->path . '/actions/' . $id) .
            '" data-sc-action-form><header><div><p class="sc-eyebrow">Selected-row action</p><h3>' .
            _h($action->{label}) . '</h3></div><button type="button" class="sc-action-close" ' .
            'data-sc-action-close aria-label="Close action form">×</button></header>' . $description .
            '<p class="sc-action-target-summary">Apply to <strong data-sc-action-selection-count>0</strong> ' .
            'selected rows.</p><input type="hidden" name="csrf_token" value="' .
            _h($model->{csrf_token} // '') . '"><input type="hidden" name="return_to" value="' .
            _h($model->{canonical_url}) . '"><div data-sc-action-targets></div>' .
            '<div class="sc-action-inputs">' . $inputs . '</div>' .
            '<div class="sc-action-result" data-sc-action-result role="status" hidden></div>' .
            '<footer><button type="button" class="sc-button sc-secondary" data-sc-action-close>Cancel</button>' .
            '<button type="submit" class="sc-button sc-primary">Apply to selected rows</button></footer>' .
            '</form></dialog>';
        $panels .= '<section class="sc-bulk-action" data-sc-bulk-action data-sc-action-id="' .
            _h($id) . '"><div><strong data-sc-selection-count>0</strong> ' .
            '<span data-sc-selection-label>rows selected</span></div>' . $button . $dialog . '</section>';
    }
    return '<div class="sc-bulk-actions" data-sc-bulk-actions>' . $panels . '</div>';
}

sub _action_input ($input) {
    my $name = 'action_input_' . $input->{id};
    my $required = $input->{required} ? ' required aria-required="true"' : '';
    my $marker = $input->{required} ? ' <span aria-hidden="true">*</span>' : '';
    my $control;
    if ($input->{type} eq 'select') {
        my $options = '<option value="">Choose ' . _h(lc($input->{label})) . '</option>' .
            join('', map {
                '<option value="' . _h($_->{value}) . '">' . _h($_->{label}) . '</option>'
            } @{$input->{options} // []});
        $control = '<select name="' . _h($name) . '"' . $required . '>' . $options . '</select>';
    } elsif ($input->{type} eq 'textarea') {
        my $rows = $input->{rows} // 4;
        my $maxlength = defined($input->{max_length})
            ? ' maxlength="' . _h($input->{max_length}) . '"' : '';
        my $minlength = defined($input->{min_length})
            ? ' minlength="' . _h($input->{min_length}) . '"' : '';
        $control = '<textarea name="' . _h($name) . '" rows="' . _h($rows) . '"' .
            $maxlength . $minlength . $required . '></textarea>';
    } else {
        my $type = $input->{type} eq 'string' ? 'text' : $input->{type};
        my $maxlength = defined($input->{max_length})
            ? ' maxlength="' . _h($input->{max_length}) . '"' : '';
        my $minlength = defined($input->{min_length})
            ? ' minlength="' . _h($input->{min_length}) . '"' : '';
        $control = '<input type="' . _h($type) . '" name="' . _h($name) . '"' .
            $maxlength . $minlength . $required . '>';
    }
    return '<label class="sc-action-input"><span>' . _h($input->{label}) . $marker . '</span>' .
        $control . '</label>';
}

sub _table ($class, $result, $model) {
    my %actions = map { $_->{id} => $_ } @{$model->{bulk_actions} // []};
    my @columns = grep { !$_->{action_id} || $actions{$_->{action_id}} } @{$result->{columns}};
    my $head = join '', map {
        my $column = $_;
        if ($column->{action_id}) {
            '<th scope="col" class="sc-select-column" data-sc-action-column="' .
                _h($column->{action_id}) . '"><label><input type="checkbox" data-sc-select-page ' .
                'data-sc-action-id="' . _h($column->{action_id}) . '" aria-label="Select every row for ' .
                _h($column->{label}) . '"><span>' . _h($column->{label}) . '</span></label></th>';
        } else {
            '<th scope="col">' . _h($column->{label}) . '</th>';
        }
    } @columns;
    my @group_indexes = grep { !$columns[$_]{measure} && !$columns[$_]{action_id} } 0 .. $#columns;
    my %group_position = map { $group_indexes[$_] => $_ } 0 .. $#group_indexes;
    my $rows = '';
    for my $index (0 .. $#{$result->{records}}) {
        my $record = $result->{records}[$index];
        my $level = $result->{rollup}
            ? $record->{__selecto_rollup_level} : scalar(@group_indexes);
        my $row_class = !$result->{rollup} ? ''
            : $level == 0 ? ' class="sc-rollup-row sc-rollup-total" data-rollup-level="0"'
            : $level < @group_indexes
                ? ' class="sc-rollup-row sc-rollup-subtotal" data-rollup-level="' . _h($level) . '"'
                : ' class="sc-rollup-row sc-rollup-detail" data-rollup-level="' . _h($level) . '"';
        my $cells = '';
        for my $column_index (0 .. $#columns) {
            my $column = $columns[$column_index];
            if ($column->{action_id}) {
                my $target = $record->{$result->{action_key}};
                $cells .= '<td class="sc-select-column" data-sc-action-column="' .
                    _h($column->{action_id}) . '"><input type="checkbox" data-sc-row-select ' .
                    'data-sc-action-id="' . _h($column->{action_id}) . '" value="' .
                    _h(defined($target) ? $target : '') . '" aria-label="Select row ' .
                    _h($index + 1) . ' for ' . _h($column->{label}) . '"' .
                    (defined($target) && "$target" ne '' ? '' : ' disabled') . '></td>';
                next;
            }
            if ($column->{measure}) {
                $cells .= '<td>' . _h(_display($record->{$column->{key}})) . '</td>';
                next;
            }
            my $group_index = $group_position{$column_index};
            my $content = '';
            if ($result->{rollup} && $level == 0) {
                $content = $group_index == 0 ? '<span class="sc-rollup-total-label">Total</span>' : '';
            } elsif (!$result->{rollup} || $group_index == $level - 1) {
                my $label = _display_group($record->{$column->{key}});
                my $pairs = $result->{drilldowns}[$index][$group_index];
                $content = $pairs
                    ? $class->_drilldown_control($model, $pairs, $label, $group_index + 1)
                    : $column->{link}
                        ? _object_link($column, $record, $label)
                        : _h($label);
            }
            $cells .= '<td>' . $content . '</td>';
        }
        $rows .= '<tr' . $row_class . '>' . $cells . '</tr>';
    }
    my $column_count = scalar(@columns);
    $rows ||= '<tr><td class="sc-empty-cell" colspan="' . $column_count . '">No rows matched this query.</td></tr>';
    return '<div class="sc-table-wrap"><table><thead><tr>' . $head . '</tr></thead><tbody>' . $rows . '</tbody></table></div>';
}

sub _graph ($class, $result, $model) {
    my @measures = grep { $_->{measure} } @{$result->{columns}};
    my @dimensions = grep { !$_->{measure} } @{$result->{columns}};
    my @records = @{$result->{records}};
    my @labels = map {
        my $record = $_;
        join(' · ', map { _display($record->{$_->{key}}) } @dimensions)
    } @records;
    my @palette = (
        '#55d6be', '#5b8ff9', '#f6bd16', '#e8684a', '#9270ca', '#6dc8ec',
        '#ff9d4d', '#269a99', '#ff99c3', '#5d7092', '#f08bb4', '#78d3f8',
    );
    my @datasets;
    for my $measure_index (0 .. $#measures) {
        my $measure = $measures[$measure_index];
        my @values = map { _number($_->{$measure->{key}}) } @records;
        my $color = $palette[$measure_index % @palette];
        my $data = \@values;
        if ($model->{state}->chart_type eq 'scatter') {
            my @points = map {
                my $index = $_;
                my $raw_x = @dimensions
                    ? $records[$index]{$dimensions[0]{key}} : $index + 1;
                +{
                    x => _numeric($raw_x) ? 0 + $raw_x : $index + 1,
                    y => $values[$index],
                    label => $labels[$index],
                }
            } 0 .. $#records;
            $data = \@points;
        }
        push @datasets, {
            label => $measure->{label},
            data => $data,
            backgroundColor => $model->{state}->chart_type =~ /\A(?:pie|doughnut)\z/
                ? [map { $palette[$_ % @palette] } 0 .. $#records] : $color,
            borderColor => $color,
            borderWidth => 2,
        };
    }
    my $chart_data = encode_json({labels => \@labels, datasets => \@datasets});
    my @values = map {
        my $record = $_;
        map { _number($record->{$_->{key}}) } @measures
    } @records;
    my $max = 0;
    for my $value (@values) {
        $max = $value if $value > $max;
    }
    $max = 1 unless $max > 0;
    my $bars = join '', map {
        my $record = $_;
        my $group_label = join(' · ', map { _display($record->{$_->{key}}) } @dimensions);
        join '', map {
            my $measure = $_;
            my $value = _number($record->{$measure->{key}});
            my $label = length($group_label)
                ? $group_label . ' · ' . $measure->{label} : $measure->{label};
            '<li><span class="sc-graph-label">' . _h($label) . '</span><meter min="0" max="' .
            _h($max) . '" value="' . _h($value) . '"></meter><strong>' .
            _h(_display($record->{$measure->{key}})) . '</strong></li>'
        } @measures
    } @records;
    $bars ||= '<li class="sc-empty-cell">No rows matched this query.</li>';
    my $drilldown_forms = '';
    my $method = $model->{config}->query_params_enabled($model->{domain}) ? 'get' : 'post';
    for my $record_index (0 .. $#records) {
        my $row_drilldowns = $result->{drilldowns}[$record_index] // [];
        next unless @$row_drilldowns;
        my $pairs = $row_drilldowns->[-1];
        my $hidden = '';
        for (my $pair_index = 0; $pair_index < @$pairs; $pair_index += 2) {
            $hidden .= _hidden($pairs->[$pair_index], $pairs->[$pair_index + 1]);
        }
        $drilldown_forms .= '<form action="' . _h($model->{config}->path) . '" method="' .
            $method . '" hx-ws:send data-sc-graph-drilldown="' . _h($record_index) .
            '">' . $hidden . '</form>';
    }
    return '<div class="sc-chart sc-chart-' . _h($model->{state}->chart_type) .
        '" role="group" aria-label="Selected measures by selected groups" data-sc-chart ' .
        'data-chart-type="' . _h($model->{state}->chart_type) . '" data-chart-data="' .
        _h($chart_data) . '"><div class="sc-chart-canvas"><canvas role="img" aria-label="' .
        _h(_humanize($model->{state}->chart_type) . ' chart of selected measures by selected groups') .
        '"></canvas></div><div class="sc-chart-fallback"><ul>' . $bars . '</ul></div>' .
        '<p class="sc-chart-hint">Click a data point to drill down to detail rows.</p>' .
        '<div class="sc-chart-drilldowns" hidden>' . $drilldown_forms . '</div></div>' .
        $class->_table($result, $model);
}

sub _drilldown_control ($class, $model, $pairs, $label, $level) {
    my $method = $model->{config}->query_params_enabled($model->{domain}) ? 'get' : 'post';
    my $hidden = '';
    for (my $index = 0; $index < @$pairs; $index += 2) {
        $hidden .= _hidden($pairs->[$index], $pairs->[$index + 1]);
    }
    return '<form class="sc-drilldown-form" action="' . _h($model->{config}->path) . '" method="' .
        $method . '" hx-ws:send>' . $hidden .
        '<button class="sc-drilldown-value" style="--sc-rollup-level:' . _h($level) .
        '" type="submit">' . _h($label) . '</button></form>';
}

sub _pagination ($class, $model) {
    my $state = $model->{state};
    my @buttons;
    if ($state->page > 1) {
        push @buttons, '<button class="sc-button sc-secondary" type="submit" name="page" value="' .
            _h($state->page - 1) . '">Previous</button>';
    }
    if ($state->page < $model->{result}{total_pages}) {
        push @buttons, '<button class="sc-button sc-secondary" type="submit" name="page" value="' .
            _h($state->page + 1) . '">Next</button>';
    }
    my $hidden = '';
    my $pairs = $state->query_pairs;
    for (my $index = 0; $index < @$pairs; $index += 2) {
        next if $pairs->[$index] eq 'page';
        $hidden .= _hidden($pairs->[$index], $pairs->[$index + 1]);
    }
    my $method = $model->{config}->query_params_enabled($model->{domain}) ? 'get' : 'post';
    my $controls = @buttons
        ? '<form action="' . _h($model->{config}->path) . '" method="' . $method . '" hx-ws:send>' .
          $hidden . join('', @buttons) . '</form>'
        : '<span></span>';
    return '<nav class="sc-pagination" aria-label="Results pages"><span>Page ' . _h($state->page) .
        ' of ' . _h($model->{result}{total_pages}) . '</span>' . $controls . '</nav>';
}

sub _limit_options ($state, $config) {
    my %seen;
    my @limits = sort { $a <=> $b } grep { $_ <= $config->max_limit && !$seen{$_}++ }
        (10, 25, 50, 100, $config->default_limit, $state->limit);
    return join '', map {
        '<option value="' . $_ . '"' . ($_ == $state->limit ? ' selected' : '') . '>' . $_ . '</option>'
    } @limits;
}

sub _hidden ($name, $value) {
    return '<input type="hidden" name="' . _h($name) . '" value="' . _h($value) . '">';
}

sub _selection_hidden ($kind, $values, $configs) {
    return join '', map {
        my $field = $_;
        my $config = $configs->{$field} // {};
        _hidden($kind, $field) .
            _hidden($kind . '_alias', $config->{alias} // '') .
            _hidden($kind . '_format', $config->{format} // '') .
            ($kind eq 'group'
                ? _hidden('group_bucket_ranges', $config->{bucket_ranges} // '') .
                  _hidden('group_prefix_length', $config->{prefix_length} // 2) .
                  _hidden('group_exclude_articles', $config->{exclude_articles} ? 1 : 0)
                : '')
    } @$values;
}

sub _measure_selection_hidden ($state) {
    return join '', map {
        my $measure = $_;
        my $config = $state->measure_configs->{$measure} // {};
        _hidden('measure', $measure) .
            _hidden('measure_alias', $config->{alias} // '') .
            _hidden('measure_function', $config->{function} // 'count') .
            _hidden('measure_bucket_ranges', $config->{bucket_ranges} // '') .
            _hidden('measure_ignore_nulls', $config->{ignore_nulls} ? 1 : 0)
    } @{$state->measures};
}

sub _number ($value) {
    return 0 unless defined($value) && !ref($value) && "$value" =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return 0 + $value;
}

sub _numeric ($value) {
    return defined($value) && !ref($value) &&
        "$value" =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/ ? 1 : 0;
}

sub _display ($value) { return defined($value) ? "$value" : '—'; }
sub _display_group ($value) { return defined($value) ? "$value" : '[NULL]'; }
sub _object_link ($column, $record, $label) {
    my $id = $record->{$column->{link_key}};
    return _h($label) unless defined($id) && !ref($id) && length("$id");
    my $href = $column->{link}{url_template};
    my $escaped_id = url_escape("$id");
    $href =~ s/\{\{id\}\}/$escaped_id/g;
    return '<a class="sc-object-link" href="' . _h($href) . '">' . _h($label) . '</a>';
}
sub _humanize ($value) { my $text = "$value"; $text =~ s/_/ /g; return ucfirst $text; }
sub _h ($value) { return xml_escape(defined($value) ? "$value" : ''); }

1;
