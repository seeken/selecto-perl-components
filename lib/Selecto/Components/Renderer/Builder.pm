package Selecto::Components::Renderer::Builder;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Selecto::Components::QueryLibrary ();
use Selecto::Components::Renderer::Markup;

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
    my $query_library_views = $class->_query_library_view_controls($state, $model->{domain});
    my $query_library_filters = $class->_query_library_filter_controls($state, $model->{domain});
    my $governed_segments = Selecto::Components::QueryLibrary->active_segment_entries(
        $model->{domain},
        $state->query_library_view,
        $state->query_library_segments // [],
    );
    my $applied_filter_count = scalar(grep { !$_->{draft} } @{$state->filters})
        + scalar(@$governed_segments);
    my $query_summary = $class->_query_summary($state, $catalog, $governed_segments);
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
    my $saved_tab_id = 'selecto-builder-saved-tab-' . $builder_id;
    my $view_panel_id = 'selecto-builder-view-panel-' . $builder_id;
    my $filter_panel_id = 'selecto-builder-filters-panel-' . $builder_id;
    my $saved_panel_id = 'selecto-builder-saved-panel-' . $builder_id;
    my $saved_enabled = $config->saved_queries_enabled($model->{domain});
    my $saved_tab = $saved_enabled
        ? '<button class="sc-builder-tab" type="button" role="tab" id="' . $saved_tab_id .
          '" aria-controls="' . $saved_panel_id .
          '" aria-selected="false" data-sc-builder-tab="saved">Saved queries</button>'
        : '';
    my $builder_tabs = '<div class="sc-builder-tabs" role="tablist" aria-label="Explorer sections">' .
        '<button class="sc-builder-tab" type="button" role="tab" id="' . $view_tab_id .
        '" aria-controls="' . $view_panel_id . '" aria-selected="true" data-sc-builder-tab="view">View</button>' .
        '<button class="sc-builder-tab" type="button" role="tab" id="' . $filter_tab_id .
        '" aria-controls="' . $filter_panel_id . '" aria-selected="false" data-sc-builder-tab="filters">' .
        'Filters <span data-sc-filter-badge>' . $applied_filter_count . '</span></button>' .
        $saved_tab . '</div>';
    my $view_panel = '<section class="sc-builder-panel" role="tabpanel" id="' . $view_panel_id .
        '" aria-labelledby="' . $view_tab_id . '" data-sc-builder-panel="view">' .
        $query_library_views .
        '<div class="sc-view-tabs" role="radiogroup" aria-label="Result view">' . $views . '</div>' .
        $view_controls . '</section>';
    my $filter_panel = '<section class="sc-builder-panel" role="tabpanel" id="' . $filter_panel_id .
        '" aria-labelledby="' . $filter_tab_id . '" data-sc-builder-panel="filters" hidden>' .
        $query_library_filters . $filter_picker . '</section>';
    my $saved_queries = $class->_saved_queries($model, $saved_panel_id, $saved_tab_id);
    my $collapsed = Selecto::Components::Renderer::_builder_collapsed($model);
    my $tray_content_id = 'selecto-builder-tray-content-' . $builder_id;
    my $tray_header = '<header class="sc-builder-tray-header"><span>View menu</span>' .
        '<button class="sc-builder-toggle" type="button" data-sc-builder-toggle aria-controls="' .
        $tray_content_id . '" aria-expanded="' . ($collapsed ? 'false' : 'true') .
        '" aria-label="' . ($collapsed ? 'Expand view menu' : 'Collapse view menu') . '">' .
        '<span data-sc-builder-chevron aria-hidden="true">' . ($collapsed ? '&#8250;' : '&#8249;') .
        '</span></button></header>';
    return '<aside class="sc-builder' . ($collapsed ? ' is-collapsed' : '') .
        '" data-sc-builder-shell="' . $builder_id . '" data-sc-builder-collapsed="' .
        ($collapsed ? 'true' : 'false') . '">' . $tray_header .
        '<div id="' . $tray_content_id . '" data-sc-builder-content>' .
        $builder_tabs . '<form id="selecto-query-' . _h($config->id) . '" action="' .
        _h($config->path) . '" method="' . $method . '" hx-ws:send hx-trigger="submit" data-sc-builder="' .
        $builder_id . '" data-sc-builder-query>' . _hidden('q', 1) .
        _hidden('query_signature', $state->query_signature) .
        $query_summary . $view_panel . $filter_panel .
        '<div class="sc-builder-apply-note"><span>Changes apply only when you run the query.</span>' .
        '<strong data-sc-builder-pending hidden>Pending changes</strong></div>' .
        '<div class="sc-control-row"><label>Rows<select name="limit">' . _limit_options($state, $config) . '</select></label>' .
        '<label>Page<input name="page" inputmode="numeric" value="' . _h($state->page) . '"></label></div>' .
        '<button class="sc-button sc-primary" type="submit">Run query</button>' .
        '<noscript><p class="sc-note">JavaScript is off; this form still runs as a normal GET.</p></noscript></form>' .
        $saved_queries . '</div></aside>';
}

sub _saved_queries ($class, $model, $panel_id, $tab_id) {
    my $config = $model->{config};
    return '' unless $config->saved_queries_enabled($model->{domain});
    my $csrf = _h($model->{csrf_token} // '');
    my $current_url = _h($model->{canonical_url});
    my $items = join '', map {
        '<li><a href="' . _h($_->{url}) . '">' . _h($_->{name}) . '</a>' .
        '<form method="post" action="' . _h($config->path) . '/saved-queries/delete">' .
        '<input type="hidden" name="csrf_token" value="' . $csrf . '">' .
        '<input type="hidden" name="saved_query_name" value="' . _h($_->{name}) . '">' .
        '<input type="hidden" name="return_to" value="' . $current_url . '">' .
        '<button type="submit" class="sc-saved-query-delete" aria-label="Delete saved query ' .
        _h($_->{name}) . '">Delete</button></form></li>'
    } @{$model->{saved_queries} // []};
    my $list = length($items)
        ? '<ul class="sc-saved-query-list">' . $items . '</ul>'
        : '<p class="sc-note">No saved queries yet.</p>';
    return '<section class="sc-builder-panel sc-saved-queries" role="tabpanel" id="' .
        _h($panel_id) . '" aria-labelledby="' . _h($tab_id) .
        '" data-sc-builder-panel="saved" data-sc-saved-queries hidden>' .
        '<div class="sc-saved-query-heading">' .
        '<h2>Saved queries</h2></div>' . $list .
        '<form class="sc-saved-query-form" method="post" action="' . _h($config->path) . '/saved-queries">' .
        '<input type="hidden" name="csrf_token" value="' . $csrf . '">' .
        '<input type="hidden" name="saved_query_url" value="' . $current_url . '">' .
        '<input type="hidden" name="return_to" value="' . $current_url . '">' .
        '<label>Name<input name="saved_query_name" maxlength="30" required autocomplete="off"></label>' .
        '<button class="sc-button sc-secondary" type="submit">Save query</button></form></section>';
}

sub _query_library_view_controls ($class, $state, $domain) {
    my $views = Selecto::Components::QueryLibrary->entries($domain, 'views');
    return '' unless @$views;
    my $selected_view = $state->query_library_view // '';
    my $view_options = '<option value=""' . ($selected_view eq '' ? ' selected' : '') .
        ' data-sc-view-segments="[]">No named view</option>' . join('', map {
            my $entry = $_;
            my $segment_ids = Selecto::Components::QueryLibrary->view_segment_ids(
                $domain, $entry->{id},
            );
            '<option value="' . _h($entry->{id}) . '" data-sc-view-segments="' .
                _h(encode_json($segment_ids)) . '"' .
                ($selected_view eq $entry->{id} ? ' selected' : '') . '>' .
                _h($entry->{label}) . '</option>'
        } @$views);
    my $view_description = '';
    if (my ($entry) = grep { $_->{id} eq $selected_view } @$views) {
        $view_description = '<div class="sc-query-library-summary"><strong>' .
            _h($entry->{label}) . '</strong>' .
            (length($entry->{description}) ? '<p>' . _h($entry->{description}) . '</p>' : '') .
            (length($entry->{capability}) ? '<small>Capability metadata: ' .
                _h($entry->{capability}) . '</small>' : '') .
            '</div>';
    }

    return '<section class="sc-query-library sc-query-library-view" ' .
        'data-sc-query-library-view-controls><p class="sc-picker-hint">Named views seed the ' .
        'editable Detail columns and ordering. The seeded view remains editable.</p>' .
        '<label>Named view<select name="query_library_view">' . $view_options . '</select></label>' .
        (length($selected_view) ? _hidden('query_library_materialized_view', $selected_view) : '') .
        $view_description . '</section>';
}

sub _query_library_filter_controls ($class, $state, $domain) {
    my $segments = Selecto::Components::QueryLibrary->entries($domain, 'segments');
    my $parameters = [];
    eval {
        $parameters = Selecto::Components::QueryLibrary->parameter_entries(
            $domain,
            $state->query_library_view,
            $state->query_library_segments // [],
        );
        1;
    };
    return '' unless @$segments || @$parameters;

    my %selected_segment = map { $_ => 1 } @{$state->query_library_segments // []};

    my $segment_choices = join('', map {
        my $entry = $_;
        '<label class="sc-query-library-choice"><input type="checkbox" name="query_library_segment" value="' .
            _h($entry->{id}) . '"' . ($selected_segment{$entry->{id}} ? ' checked' : '') .
            '><span><strong>' . _h($entry->{label}) . '</strong>' .
            (length($entry->{description}) ? '<small>' . _h($entry->{description}) . '</small>' : '') .
            (length($entry->{capability}) ? '<small>Capability metadata: ' .
                _h($entry->{capability}) . '</small>' : '') .
            '</span></label>'
    } @$segments);

    my $parameter_controls = join('', map {
            my $entry = $_;
            my $input_type = Selecto::Components::QueryLibrary->input_type($entry->{type});
            my $value = exists($state->query_library_parameters->{$entry->{id}})
                ? $state->query_library_parameters->{$entry->{id}}
                : defined($entry->{default}) && !ref($entry->{default}) ? $entry->{default} : '';
            my $required = $entry->{required} ? ' required' : '';
            my $control = $input_type eq 'checkbox'
                ? '<select name="query_library_param_value"' . $required . '><option value="false"' .
                  ("$value" =~ /\A(?:0|false|off|no)\z/i ? ' selected' : '') . '>False</option>' .
                  '<option value="true"' . ("$value" =~ /\A(?:1|true|on|yes)\z/i ? ' selected' : '') .
                  '>True</option></select>'
                : '<input type="' . $input_type . '" name="query_library_param_value" value="' .
                  _h($value) . '"' . ($entry->{type} =~ /\A(?:float|decimal)\z/
                    ? ' step="any"' : '') . $required . '>';
            '<label><span>' . _h($entry->{label}) . ($entry->{required} ? ' *' : '') . '</span>' .
                _hidden('query_library_param_name', $entry->{id}) . $control .
                (length($entry->{description}) ? '<small>' . _h($entry->{description}) . '</small>' : '') .
                '</label>'
        } @$parameters);

    return '<section class="sc-query-library sc-query-library-filters" ' .
        'data-sc-query-library-filter-controls><p class="sc-picker-hint">Named segments add ' .
        'governed constraints alongside the visual filters below.</p>' .
        (@$segments ? '<fieldset><legend>Named segments</legend><div class="sc-query-library-choices">' .
            $segment_choices . '</div></fieldset>' : '') .
        (length($parameter_controls) ? '<fieldset><legend>Parameters</legend><div class="sc-query-library-parameters">' .
            $parameter_controls . '</div></fieldset>' : '') . '</section>';
}

sub _query_library_picker ($class, $state, $domain) {
    return $class->_query_library_view_controls($state, $domain) .
        $class->_query_library_filter_controls($state, $domain);
}

sub _query_summary ($class, $state, $catalog, $governed_segments) {
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my @filters = grep { !$_->{draft} } @{$state->filters};
    my @chips = map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        my $label = $field ? $field->{label} : _humanize($filter->{field});
        '<span data-sc-filter-summary>' . _h(_filter_summary_text($label, $filter)) . '</span>'
    } @filters;
    push @chips, map {
        '<span data-sc-query-library-segment-summary="' . _h($_->{id}) . '">' .
            _h('Segment: ' . $_->{label}) . '</span>'
    } @$governed_segments;
    my $count = @filters + @$governed_segments;
    my $filter_label = $count == 1 ? 'applied filter' : 'applied filters';
    my $chips = @chips ? '<div class="sc-query-summary-chips">' . join('', @chips) . '</div>'
        : '<p>No filters applied</p>';
    return '<section class="sc-query-summary" data-sc-query-summary><div class="sc-query-summary-heading">' .
        '<div><small>View controller</small><strong>' . _h(_humanize($state->view)) .
        ' results</strong></div><span>' . $count . ' ' . $filter_label . '</span></div>' .
        $chips . '</section>';
}

sub _promoted_filter_header ($class, $model, $catalog) {
    my $state = $model->{state};
    my $config = $model->{config};
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my @promoted = grep { $_->{promoted} && !$_->{grouped} } @{$state->filters};
    return '' unless @promoted;
    my $form_id = 'selecto-query-' . $config->id;
    my $cards = join '', map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        return '' unless $field;
        '<article class="sc-promoted-filter" data-sc-promoted-filter data-field="' .
            _h($filter->{field}) . '"><header><strong>' . _h($field->{label}) .
            '</strong></header>' .
            $class->_promoted_filter_mode_control($config, $field, $filter) .
            '<div data-sc-promoted-filter-values>' .
            $class->_promoted_filter_value_controls($config, $field, $filter) . '</div></article>'
    } @promoted;
    return '' unless length($cards);
    return '<section class="sc-promoted-filters" data-sc-promoted-filters><div class="sc-promoted-filters-heading">' .
        '<div><small>View filters</small><strong>Quick filters</strong></div>' .
        '<button class="sc-button sc-primary" type="submit" form="' . _h($form_id) .
        '">Run query</button></div><div class="sc-promoted-filter-grid">' . $cards . '</div></section>';
}

sub _promoted_filter_mode_control ($class, $config, $field, $filter) {
    my $operator = $filter->{op};
    my $options = join '', map {
        '<option value="' . _h($_->[0]) . '"' . ($_->[0] eq $operator ? ' selected' : '') . '>' .
            _h($_->[1]) . '</option>'
    } @{$config->filter_operators($field->{type})};
    return '<label class="sc-promoted-filter-mode">Match<select data-sc-promoted-filter-input="op" data-filter-field="' .
        _h($field->{path}) . '" aria-label="Match mode for ' . _h($field->{label}) . '">' .
        $options . '</select></label>';
}

sub _promoted_filter_value_controls ($class, $config, $field, $filter) {
    my $operator = $filter->{op};
    my $value = $filter->{value} // '';
    my $value_end = $filter->{value_end} // '';
    my $field_name = $field->{path};
    my $label = $field->{label};
    my $type = $field->{type};
    return '<p class="sc-promoted-filter-note">No value needed.</p>' if $operator =~ /_null\z/;
    if ($operator eq 'date_shortcut') {
        my $options = join '', map {
            '<option value="' . _h($_->{id}) . '"' . ($_->{id} eq $value ? ' selected' : '') . '>' .
                _h($_->{label}) . '</option>'
        } @{$config->date_shortcuts};
        return '<label>Period<select data-sc-promoted-filter-input="value" data-filter-field="' .
            _h($field_name) . '" aria-label="Period for ' . _h($label) . '">' . $options . '</select></label>';
    }
    if ($operator eq 'between') {
        my $input_type = $config->temporal_type($type)
            ? (lc($type) eq 'date' ? 'date' : 'datetime-local')
            : ($config->numeric_type($type) ? 'number' : 'text');
        my $step = $input_type eq 'number' ? ' step="any"' : '';
        return '<div class="sc-promoted-filter-range"><label>Start<input type="' . $input_type . '"' . $step .
            ' value="' . _h($value) . '" data-sc-promoted-filter-input="value" data-filter-field="' .
            _h($field_name) . '" aria-label="Start value for ' . _h($label) . '"></label>' .
            '<label>End<input type="' . $input_type . '"' . $step . ' value="' . _h($value_end) .
            '" data-sc-promoted-filter-input="value_end" data-filter-field="' . _h($field_name) .
            '" aria-label="End value for ' . _h($label) . '"></label></div>';
    }
    if ($config->boolean_type($type)) {
        return '<label>Value<select data-sc-promoted-filter-input="value" data-filter-field="' .
            _h($field_name) . '" aria-label="Value for ' . _h($label) . '"><option value=""' .
            (!length($value) ? ' selected' : '') . '>Choose true or false</option><option value="true"' .
            (lc($value) eq 'true' || $value eq '1' ? ' selected' : '') . '>True</option><option value="false"' .
            (lc($value) eq 'false' || $value eq '0' ? ' selected' : '') . '>False</option></select></label>';
    }
    my $input_type = $operator eq 'in' ? 'text' : $config->temporal_type($type)
        ? (lc($type) eq 'date' ? 'date' : 'datetime-local')
        : ($config->numeric_type($type) ? 'number' : 'text');
    my $step = $input_type eq 'number' ? ' step="any"' : '';
    my $placeholder = $operator eq 'in' ? 'Comma-separated values'
        : ($config->temporal_type($type) ? 'Choose a date' : 'Enter a value');
    return '<label>Value<input type="' . $input_type . '"' . $step . ' value="' . _h($value) .
        '" placeholder="' . _h($placeholder) . '" data-sc-promoted-filter-input="value" data-filter-field="' .
        _h($field_name) . '" aria-label="Value for ' . _h($label) . '"></label>';
}

sub _filter_summary_text ($label, $filter) {
    my $operator = $filter->{op} // 'eq';
    return "$label " . ($operator eq 'is_null' ? 'is empty' : 'is not empty')
        if $operator eq 'is_null' || $operator eq 'not_null';
    return "$label between " . ($filter->{value} // '') . ' and ' . ($filter->{value_end} // '')
        if $operator eq 'between';
    my %symbols = (eq => '=', ne => '!=', gt => '>', gte => '>=', lt => '<', lte => '<=');
    my $display_operator = $symbols{$operator} // _humanize($operator);
    return "$label $display_operator " . ($filter->{value} // '');
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
        if ($field->{dimension}) {
            $controls .= _hidden('group_format', '') .
                _hidden('group_bucket_ranges', '') .
                _hidden('group_prefix_length', '2') .
                _hidden('group_exclude_articles', '1');
            return $controls;
        }
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
              $class->_filter_value_controls($config, $field, $filter) .
              '<label class="sc-filter-promote"><input type="checkbox" name="filter_promote_field" value="' .
              _h($filter->{field}) . '"' . ($filter->{promoted} ? ' checked' : '') .
              '> Promote to View Controller</label>';
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

1;
