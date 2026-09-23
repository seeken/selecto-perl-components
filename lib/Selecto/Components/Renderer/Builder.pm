package Selecto::Components::Renderer::Builder;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::URL ();
use Selecto::Components::QueryLibrary ();
use Selecto::Components::RowActions ();
use Selecto::Components::Renderer::Markup;
use Selecto::Analytics::TransformRegistry ();

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
    my $filter_catalog = $config->filter_catalog($model->{domain});
    my $root_label = $model->{domain}->name;
    my $filter_picker = $class->_filter_picker($state, $filter_catalog, $config, $root_label);
    my $query_library_views = $class->_query_library_view_controls(
        $state, $model->{domain}, $config,
    );
    my $query_library_filters = $class->_query_library_filter_controls(
        $state, $model->{domain}, $config,
    );
    my $governed_segments = Selecto::Components::QueryLibrary->active_segment_entries(
        $model->{domain},
        $state->query_library_view,
        $state->query_library_segments // [],
        $config,
    );
    my $applied_filter_count = _logical_filter_count($state->filters)
        + scalar(@$governed_segments);
    my $query_summary = $class->_query_summary($state, $filter_catalog, $governed_segments);
    my $detail_controls = $class->_row_click_picker($state, $model->{domain}, $config) .
        $class->_field_picker($state, $detail_catalog // $catalog, $config, $root_label) .
        $class->_order_picker($state, $catalog, $config->max_orders, $root_label) .
        _measure_selection_hidden($state) .
        _selection_hidden('group', $state->groups, $state->group_configs);
    my $summary_controls = $class->_aggregate_grid_picker($state) .
        $class->_chart_type_picker($state, $catalog) .
        $class->_group_picker($state, $catalog, $config, $root_label) .
        $class->_measure_picker($state, $measure_catalog, $config, $root_label) .
        _selection_hidden(
            'field', $state->fields, $state->field_configs, $state->field_config_list
        ) .
        _hidden('row_click_action', $state->row_click_action // '') .
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
    return '<aside class="sc-builder' . ($collapsed ? ' is-collapsed' : '') .
        '" data-sc-builder-shell="' . $builder_id . '" data-sc-builder-collapsed="' .
        ($collapsed ? 'true' : 'false') . '"><div id="' . $tray_content_id .
        '" data-sc-builder-content>' .
        $builder_tabs . '<form id="selecto-query-' . _h($config->id) . '" action="' .
        _h($config->path) . '" method="' . $method . '" hx-ws:send hx-trigger="submit" data-sc-builder="' .
        $builder_id . '" data-sc-builder-query data-sc-date-shortcuts="' .
        _h(encode_json([map { [$_->{group}, $_->{id}, $_->{label}] } @{$config->date_shortcuts}])) . '">' .
        _hidden('q', 1) .
        _hidden('query_signature', $state->query_signature) .
        ($model->{loaded_saved_query} && $model->{loaded_saved_query}{id}
            ? _hidden('saved_query_id', $model->{loaded_saved_query}{id}) : '') .
        $query_summary . $view_panel . $filter_panel .
        '<div class="sc-builder-apply-note"><span>Changes apply only when you run the query.</span>' .
        '<strong data-sc-builder-pending role="status" aria-live="polite" aria-atomic="true"></strong></div>' .
        '<div class="sc-control-row"><label><span data-sc-limit-label>' .
        ($state->view eq 'graph' ? 'Points' : 'Rows') .
        '</span><select name="limit" data-sc-limit>' . _limit_options($state, $config) . '</select></label>' .
        '<label data-sc-page-control' . ($state->view eq 'graph' ? ' hidden' : '') .
        '>Page<input name="page" inputmode="numeric" value="' . _h($state->page) . '"' .
        ($state->view eq 'graph' ? ' disabled' : '') . '></label></div>' .
        '<button class="sc-button sc-primary" type="submit">Run query</button>' .
        '<noscript><p class="sc-note">JavaScript is off; this form still runs as a normal GET.</p></noscript></form>' .
        $saved_queries . '</div></aside>';
}

sub _query_summary_for_model ($class, $model, $catalog) {
    my $segments = Selecto::Components::QueryLibrary->active_segment_entries(
        $model->{domain},
        $model->{state}->query_library_view,
        $model->{state}->query_library_segments // [],
        $model->{config},
    );
    return $class->_query_summary($model->{state}, $catalog, $segments);
}

sub _row_click_picker ($class, $state, $domain, $config) {
    my $catalog = Selecto::Components::RowActions->catalog($domain, $config);
    return '' unless @$catalog;
    my $options = '<option value="">No row action</option>' . join('', map {
        '<option value="' . _h($_->{id}) . '"' .
            ($_->{id} eq ($state->row_click_action // '') ? ' selected' : '') . '>' .
            _h($_->{name}) . '</option>'
    } @$catalog);
    return '<label class="sc-row-click-control"><span>Row click</span>' .
        '<select name="row_click_action" aria-label="Action when a result row is clicked">' .
        $options . '</select></label>';
}

sub _saved_queries ($class, $model, $panel_id, $tab_id) {
    my $config = $model->{config};
    return '' unless $config->saved_queries_enabled($model->{domain});
    my $csrf = _h($model->{csrf_token} // '');
    my $current_url = _h($model->{canonical_url});
    my $return_url = Mojo::URL->new($model->{canonical_url});
    $return_url->query->param(saved_query_id => $model->{loaded_saved_query}{id})
        if $model->{loaded_saved_query} && $model->{loaded_saved_query}{id};
    $return_url = _h($return_url->to_string);
    my $items = join '', map {
        my $saved_url = Mojo::URL->new($_->{url});
        $saved_url->query->param(saved_query_name => $_->{name});
        $saved_url->query->param(saved_query_id => $_->{id}) if $_->{id};
        my $scope = $_->{scope} // ($_->{readonly} ? 'client' : 'user');
        my $scope_label = $scope eq 'priv' ? 'Privilege' :
            $scope eq 'client' ? 'Client' : 'Personal';
        '<li><a href="' . _h($saved_url->to_string) . '">' . _h($_->{name}) . '</a>' .
        '<span class="sc-saved-query-shared">' . _h($scope_label) . '</span>' .
        ($_->{folder} ? '<small>' . _h($_->{folder}) . '</small>' : '') .
        ($_->{readonly}
            ? ''
            : '<form method="post" action="' . _h($config->path) . '/saved-queries/delete">' .
                '<input type="hidden" name="csrf_token" value="' . $csrf . '">' .
                '<input type="hidden" name="saved_query_name" value="' . _h($_->{name}) . '">' .
                ($_->{id} ? '<input type="hidden" name="saved_query_id" value="' . _h($_->{id}) . '">' : '') .
                ($_->{revision} ? '<input type="hidden" name="saved_query_revision" value="' . _h($_->{revision}) . '">' : '') .
                '<input type="hidden" name="return_to" value="' . $return_url . '">' .
                '<button type="submit" class="sc-saved-query-delete" aria-label="Delete saved query ' .
                _h($_->{name}) . '">Delete</button></form>') . '</li>'
    } @{$model->{saved_queries} // []};
    my $list = length($items)
        ? '<ul class="sc-saved-query-list">' . $items . '</ul>'
        : '<p class="sc-note">No saved queries yet.</p>';
    my $loaded = $model->{loaded_saved_query};
    my $target_options = join '', map {
        ref($_) eq 'HASH' && defined($_->{id}) && defined($_->{label})
            ? '<option value="' . _h($_->{id}) . '">' . _h($_->{label}) . '</option>' : ''
    } @{$model->{saved_query_targets} // []};
    my $target_picker = length($target_options)
        ? '<label>Save for<select name="saved_query_target" required>' . $target_options . '</select></label>'
        : '<input type="hidden" name="saved_query_target" value="user">';
    my $update_form = $loaded && $loaded->{id} && !$loaded->{readonly}
        && $loaded->{revision}
        ? '<form class="sc-saved-query-form" method="post" action="' . _h($config->path) .
            '/saved-queries" data-sc-saved-original-url="' . _h($loaded->{url}) .
            '" data-sc-saved-name="' . _h($loaded->{name}) . '">' .
            '<input type="hidden" name="csrf_token" value="' . $csrf . '">' .
            '<input type="hidden" name="saved_query_operation" value="update">' .
            '<input type="hidden" name="saved_query_id" value="' . _h($loaded->{id}) . '">' .
            '<input type="hidden" name="saved_query_revision" value="' . _h($loaded->{revision}) . '">' .
            '<input type="hidden" name="saved_query_name" value="' . _h($loaded->{name}) . '">' .
            '<input type="hidden" name="saved_query_url" value="' . $current_url . '">' .
            '<input type="hidden" name="return_to" value="' . $return_url . '">' .
            '<p data-sc-saved-edit-status>Editing ' . _h($loaded->{name}) .
                ($model->{saved_query_dirty} ? ' — unsaved changes' : ' — unchanged') . '</p>' .
            '<label><input type="checkbox" name="confirm_saved_query_update" value="1" required>' .
                ' Replace this saved view with the current query</label>' .
            '<button class="sc-button sc-secondary" type="submit">Update this view</button></form>'
        : '';
    my $loaded_note = $loaded && $loaded->{readonly}
        ? '<p class="sc-note">This shared view is read-only for you. Save a new view to keep your changes.</p>'
        : '';
    return '<section class="sc-builder-panel sc-saved-queries" role="tabpanel" id="' .
        _h($panel_id) . '" aria-labelledby="' . _h($tab_id) .
        '" data-sc-builder-panel="saved" data-sc-saved-queries hidden>' .
        '<div class="sc-saved-query-heading">' .
        '<h2>Saved queries</h2></div>' . $loaded_note . $list .
        '<form class="sc-saved-query-form" method="post" action="' . _h($config->path) . '/saved-queries">' .
        '<input type="hidden" name="csrf_token" value="' . $csrf . '">' .
        '<input type="hidden" name="saved_query_operation" value="new">' .
        '<input type="hidden" name="saved_query_url" value="' . $current_url . '">' .
        '<input type="hidden" name="return_to" value="' . $return_url . '">' .
        $target_picker .
        '<label>Name<input name="saved_query_name" maxlength="30" required autocomplete="off"></label>' .
        '<button class="sc-button sc-secondary" type="submit">Save new view</button></form>' .
        $update_form . '</section>';
}

sub _query_library_view_controls ($class, $state, $domain, $config = undef) {
    my $views = Selecto::Components::QueryLibrary->entries($domain, 'views', $config);
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

sub _query_library_filter_controls ($class, $state, $domain, $config = undef) {
    my %selected_segment = map { $_ => 1 } @{$state->query_library_segments // []};
    my %view_segment = map { $_ => 1 } @{Selecto::Components::QueryLibrary->view_segment_ids(
        $domain, $state->query_library_view,
    )};
    my $picker_groups = Selecto::Components::QueryLibrary->segment_picker_groups($domain, $config);
    my %grouped_segment = map { $_->{segment} => 1 }
        map { @{$_->{choices}} } @$picker_groups;
    my $segments = [grep { !$_->{picker_hidden} || $selected_segment{$_->{id}} }
        grep { !$grouped_segment{$_->{id}} }
        @{Selecto::Components::QueryLibrary->entries($domain, 'segments', $config)}];
    my $parameters = [];
    eval {
        $parameters = Selecto::Components::QueryLibrary->parameter_entries(
            $domain,
            $state->query_library_view,
            $state->query_library_segments // [],
            $config,
        );
        1;
    };
    return '' unless @$segments || @$picker_groups || @$parameters;

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

    my $group_choices = join('', map {
        my $group = $_;
        my @selected = grep { $selected_segment{$_->{segment}} || $view_segment{$_->{segment}} }
            @{$group->{choices}};
        my $inherited = scalar grep { $view_segment{$_->{segment}} } @{$group->{choices}};
        my $name = 'query_library_segment_choice_' . $group->{id};
        my $heading_id = 'sc-segment-group-' . $group->{id};
        my $off = '<label class="sc-query-library-choice"><input type="radio" name="' .
            _h($name) . '" value="" data-sc-query-library-group-choice' .
            ($inherited ? ' disabled' : '') .
            (@selected ? '' : ' checked') . '><span>' . _h($group->{off_label}) . '</span></label>';
        my $options = join('', map {
            '<label class="sc-query-library-choice"><input type="radio" name="' . _h($name) .
                '" value="' . _h($_->{segment}) . '" data-sc-query-library-group-choice' .
                ($inherited ? ' disabled' : '') .
                (($selected_segment{$_->{segment}} || $view_segment{$_->{segment}}) && @selected == 1 ? ' checked' : '') .
                '><span>' . _h($_->{label}) . '</span></label>'
        } @{$group->{choices}});
        my $conflict = @selected > 1
            ? '<label class="sc-query-library-choice"><input type="radio" name="' . _h($name) .
              '" value="__conflict__" checked><span>Multiple selected; choose one</span></label>'
            : '';
        '<div class="sc-query-library-choice-group" role="group" aria-labelledby="' .
            _h($heading_id) . '"><div class="sc-query-library-choice-group-heading"><strong id="' .
            _h($heading_id) . '">' . _h($group->{label}) . '</strong>' .
            (length($group->{description}) ? '<small>' . _h($group->{description}) . '</small>' : '') .
            '</div><div class="sc-query-library-choice-group-options">' .
            $off . $options . $conflict . '</div>' .
            ($inherited ? '<small>Set by the named view; change the view to change this choice.</small>' : '') .
            '</div>'
    } @$picker_groups);

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
        (@$segments || @$picker_groups
            ? '<fieldset><legend>Named segments</legend><div class="sc-query-library-choices">' .
                $group_choices . $segment_choices . '</div></fieldset>' : '') .
        (length($parameter_controls) ? '<fieldset><legend>Parameters</legend><div class="sc-query-library-parameters">' .
            $parameter_controls . '</div></fieldset>' : '') . '</section>';
}

sub _query_library_picker ($class, $state, $domain, $config = undef) {
    return $class->_query_library_view_controls($state, $domain, $config) .
        $class->_query_library_filter_controls($state, $domain, $config);
}

sub _query_summary ($class, $state, $catalog, $governed_segments) {
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my @filters = grep { !$_->{draft} && !defined($_->{clause}) } @{$state->filters};
    my @chips = map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        my $label = $field ? $field->{label} : _humanize($filter->{field});
        '<span data-sc-filter-summary>' . _h(_filter_summary_text($label, $filter, $field)) . '</span>'
    } @filters;
    my %clause;
    $clause{$_->{clause}} = 1
        for grep { !$_->{draft} && defined($_->{clause}) } @{$state->filters};
    my $clause_count = scalar(keys %clause);
    my %grid_fields = map { $_ => 1 } @{$state->groups // []};
    my $grid_mode = keys(%grid_fields) == 2
        && !grep { !$grid_fields{$_->{field}} }
            grep { defined($_->{clause}) } @{$state->filters};
    push @chips, '<span data-sc-filter-clause-summary>' .
        ($grid_mode ? 'Grid selection: ' : 'Alternatives: ') .
        $clause_count . ($grid_mode ? ($clause_count == 1 ? ' area' : ' areas') : '') . '</span>'
        if $clause_count;
    push @chips, map {
        '<span data-sc-query-library-segment-summary="' . _h($_->{id}) . '">' .
            _h('Segment: ' . $_->{label}) . '</span>'
    } @$governed_segments;
    my $count = @filters + $clause_count + @$governed_segments;
    my $filter_label = $count == 1 ? 'applied filter' : 'applied filters';
    my $chips = @chips ? '<div class="sc-query-summary-chips">' . join('', @chips) . '</div>'
        : '<p>No filters applied</p>';
    return '<section class="sc-query-summary" data-sc-query-summary><div class="sc-query-summary-heading">' .
        '<div><small>View controller</small><strong>' . _h(_humanize($state->view)) .
        ' results</strong></div><span>' . $count . ' ' . $filter_label . '</span></div>' .
        $chips . '</section>';
}

sub _logical_filter_count ($filters) {
    my $ordinary = scalar(grep { !$_->{draft} && !defined($_->{clause}) } @$filters);
    my %clauses;
    $clauses{$_->{clause}} = 1
        for grep { !$_->{draft} && defined($_->{clause}) } @$filters;
    return $ordinary + scalar(keys %clauses);
}

sub _promoted_filter_header ($class, $model, $catalog) {
    my $state = $model->{state};
    my $config = $model->{config};
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my @promoted = map {
        my $filter = $state->filters->[$_];
        $filter->{promoted} && !defined($filter->{clause})
            ? ({%$filter, instance => $_ + 1}) : ()
    } (@{$state->filters} ? (0 .. $#{$state->filters}) : ());
    my %by_clause;
    my @clause_order;
    for my $filter (@{$state->filters}) {
        next unless defined($filter->{clause});
        push @clause_order, $filter->{clause} unless exists($by_clause{$filter->{clause}});
        push @{$by_clause{$filter->{clause}}}, $filter;
    }
    return '' unless @promoted || @clause_order;
    my $form_id = 'selecto-query-' . $config->id;
    my $filter_cards = join '', map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        return '' unless $field;
        '<article class="sc-promoted-filter" data-sc-promoted-filter data-field="' .
            _h($filter->{field}) . '" data-filter-instance="' .
            _h($filter->{instance} // '') . '"><header><strong>' . _h($field->{label}) .
            '</strong></header>' .
            $class->_promoted_filter_mode_control($config, $field, $filter) .
            '<div data-sc-promoted-filter-values>' .
            $class->_promoted_filter_value_controls($config, $field, $filter) . '</div></article>'
    } @promoted;
    my $clause_cards = join '', map {
        my $clause = $_;
        my $conditions = join '<span class="sc-promoted-filter-and">AND</span>', map {
            my $filter = $_;
            my $field = $by_path{$filter->{field}};
            return '' unless $field;
            '<section class="sc-promoted-filter-pair-condition" data-sc-promoted-filter-condition ' .
                'data-field="' . _h($filter->{field}) . '"><strong>' .
                _h($field->{label}) . '</strong><span class="sc-promoted-filter-pair-value">' .
                _h(_filter_value_text($filter, $field)) . '</span></section>'
        } @{$by_clause{$clause}};
        my $kind = @{$by_clause{$clause}} == 1 ? 'row or column' : 'cell';
        '<article class="sc-promoted-filter sc-promoted-filter-pair" data-sc-promoted-filter ' .
            'data-sc-promoted-filter-clause="' . _h($clause) . '"><header><strong>Selected ' .
            _h($kind) . ' ' . _h($clause) . '</strong><button type="button" data-sc-promoted-clause-remove ' .
            'data-filter-clause="' . _h($clause) . '" aria-label="Remove grid selection ' .
            _h($clause) . '" title="Remove grid selection">×</button></header>' .
            '<div class="sc-promoted-filter-pair-body">' . $conditions . '</div></article>'
    } @clause_order;
    my $cards = $filter_cards . $clause_cards;
    return '' unless length($cards);
    return '<section class="sc-promoted-filters" data-sc-promoted-filters><div class="sc-promoted-filters-heading">' .
        '<div><small>View filters</small><strong>Quick filters</strong></div>' .
        '<button class="sc-button sc-primary" type="submit" form="' . _h($form_id) .
        '">Run query</button></div><div class="sc-promoted-filter-grid">' . $cards . '</div></section>';
}

sub _promoted_filter_mode_control ($class, $config, $field, $filter, $clause = undef) {
    my $operator = $filter->{op};
    my $options = join '', map {
        '<option value="' . _h($_->[0]) . '"' . ($_->[0] eq $operator ? ' selected' : '') . '>' .
            _h($_->[1]) . '</option>'
    } @{_filter_operators_for_filter($config, $field, $filter)};
    return '<label class="sc-promoted-filter-mode">Match<select' .
        _promoted_filter_input_attributes('op', $field->{path}, $clause, $filter->{instance}) .
        ' aria-label="Match mode for ' . _h($field->{label}) . '">' .
        $options . '</select></label>';
}

sub _promoted_filter_value_controls ($class, $config, $field, $filter, $clause = undef) {
    my $operator = $filter->{op};
    my $value = $filter->{value} // '';
    my $value_end = $filter->{value_end} // '';
    my $field_name = $field->{path};
    my $label = $field->{label};
    my $type = $field->{type};
    return '<p class="sc-promoted-filter-note">No value needed.</p>' if $operator =~ /_null\z/;
    if ($filter->{grouped}) {
        return '<label>Value<input type="text" value="' . _h($value) .
            '" placeholder="Enter an aggregate value"' .
            _promoted_filter_input_attributes('value', $field_name, $clause, $filter->{instance}) .
            ' aria-label="Value for ' .
            _h($label) . '"></label>';
    }
    if ($operator eq 'date_shortcut') {
        my $options = join '', map {
            '<option value="' . _h($_->{id}) . '"' . ($_->{id} eq $value ? ' selected' : '') . '>' .
                _h($_->{label}) . '</option>'
        } @{$config->date_shortcuts};
        return '<label>Period<select' .
            _promoted_filter_input_attributes('value', $field_name, $clause, $filter->{instance}) .
            ' aria-label="Period for ' . _h($label) . '">' . $options . '</select></label>';
    }
    if ($operator eq 'between') {
        my $input_type = $config->temporal_type($type)
            ? _temporal_filter_input_type($config, $type, $value, $value_end)
            : ($config->numeric_type($type) ? 'number' : 'text');
        my $step = $input_type eq 'number' ? ' step="any"' : '';
        return '<div class="sc-promoted-filter-range"><label>Start<input type="' . $input_type . '"' . $step .
            ' value="' . _h($value) . '"' .
            _promoted_filter_input_attributes('value', $field_name, $clause, $filter->{instance}) .
            ' aria-label="Start value for ' . _h($label) . '"></label>' .
            '<label>End<input type="' . $input_type . '"' . $step . ' value="' . _h($value_end) .
            '"' . _promoted_filter_input_attributes('value_end', $field_name, $clause, $filter->{instance}) .
            ' aria-label="End value for ' . _h($label) . '"></label></div>';
    }
    if (ref($field->{filter_choices}) eq 'ARRAY'
        && @{$field->{filter_choices}}
        && $operator =~ /\A(?:eq|ne|in|not_in)\z/) {
        my $multiple = $operator eq 'in' || $operator eq 'not_in';
        my %selected = map { my $id = $_; $id =~ s/\A\s+|\s+\z//g; $id => 1 }
            split /,/, $value, -1;
        my %known;
        my $options = $multiple ? '' : '<option value="">Choose a value</option>';
        for my $choice (@{$field->{filter_choices}}) {
            $known{$choice->{value}} = 1;
            $options .= '<option value="' . _h($choice->{value}) . '"' .
                ($selected{$choice->{value}} ? ' selected' : '') . '>' .
                _h($choice->{label}) . '</option>';
        }
        for my $unlisted (sort grep { length($_) && !$known{$_} } keys %selected) {
            $options .= '<option value="' . _h($unlisted) . '" selected>' .
                'Unavailable option</option>';
        }
        return '<label>' . ($multiple ? 'Values' : 'Value') . '<select' .
            ($multiple ? ' multiple size="6"' : '') .
            _promoted_filter_input_attributes('value', $field_name, $clause, $filter->{instance}) .
            ' aria-label="Choices for ' . _h($label) . '">' . $options . '</select></label>';
    }
    if ($config->boolean_type($type)) {
        return '<label>Value<select' .
            _promoted_filter_input_attributes('value', $field_name, $clause, $filter->{instance}) .
            ' aria-label="Value for ' . _h($label) . '"><option value=""' .
            (!length($value) ? ' selected' : '') . '>Choose true or false</option><option value="true"' .
            (lc($value) eq 'true' || $value eq '1' ? ' selected' : '') . '>True</option><option value="false"' .
            (lc($value) eq 'false' || $value eq '0' ? ' selected' : '') . '>False</option></select></label>';
    }
    my $input_type = $operator eq 'in' ? 'text' : $config->temporal_type($type)
        ? _temporal_filter_input_type($config, $type, $value)
        : ($config->numeric_type($type) ? 'number' : 'text');
    my $step = $input_type eq 'number' ? ' step="any"' : '';
    my $placeholder = $operator eq 'in' ? 'Comma-separated values'
        : ($config->temporal_type($type) ? 'Choose a date' : 'Enter a value');
    return '<label>Value<input type="' . $input_type . '"' . $step . ' value="' . _h($value) .
        '" placeholder="' . _h($placeholder) . '"' .
        _promoted_filter_input_attributes('value', $field_name, $clause, $filter->{instance}) .
        ' aria-label="Value for ' . _h($label) . '"></label>';
}

sub _promoted_filter_input_attributes ($kind, $field, $clause = undef, $instance = undef) {
    return ' data-sc-promoted-filter-input="' . _h($kind) . '" data-filter-field="' .
        _h($field) . '"' . (defined($clause)
            ? ' data-filter-clause="' . _h($clause) . '"' : '') .
        (defined($instance) ? ' data-filter-instance="' . _h($instance) . '"' : '');
}

sub _filter_summary_text ($label, $filter, $field = undef) {
    return "$label " . _filter_value_text($filter, $field);
}

sub _filter_value_text ($filter, $field = undef) {
    my $operator = $filter->{op} // 'eq';
    return $operator eq 'is_null' ? 'is empty' : 'is not empty'
        if $operator eq 'is_null' || $operator eq 'not_null';
    return 'between ' . ($filter->{value} // '') . ' and ' . ($filter->{value_end} // '')
        if $operator eq 'between';
    my %symbols = (eq => '=', ne => '!=', gt => '>', gte => '>=', lt => '<', lte => '<=');
    my $display_operator = $symbols{$operator} // _humanize($operator);
    if (ref($field) eq 'HASH' && ref($field->{filter_choices}) eq 'ARRAY'
        && $operator =~ /\A(?:eq|ne|in|not_in)\z/) {
        $display_operator = 'one of' if $operator eq 'in';
        $display_operator = 'not one of' if $operator eq 'not_in';
        my %labels = map { $_->{value} => $_->{label} } @{$field->{filter_choices}};
        my @values = map { my $id = $_; $id =~ s/\A\s+|\s+\z//g;
            $labels{$id} // 'Unavailable option' }
            grep { length($_) } split /,/, ($filter->{value} // ''), -1;
        return "$display_operator " . join(', ', @values);
    }
    return "$display_operator " . ($filter->{value} // '');
}

sub _chart_type_picker ($class, $state, $catalog) {
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
    my $show_table = $state->graph_show_table ? ' checked' : '';
    my %field_labels = map { ($_->{path} => $_->{label}) } @$catalog;
    my $series_group = $state->graph_series_group // '';
    my $series_options = '<option value="">One series per measure</option>' . join '', map {
        my $field = $_;
        my $label = $state->group_configs->{$field}{alias}
            || $field_labels{$field} || _humanize($field);
        '<option value="' . _h($field) . '"' .
            ($series_group eq $field ? ' selected' : '') . '>' .
            _h($label) . '</option>'
    } @{$state->groups};
    return '<fieldset class="sc-chart-type-picker" data-sc-graph-options' . $inactive . '>' .
        '<legend>Chart</legend><label>Chart type<select name="chart_type" ' .
        'data-sc-chart-type-picker>' . $options . '</select></label>' .
        '<label>Separate series by<select name="graph_series_group">' .
        $series_options . '</select></label>' .
        '<label class="sc-option-check"><input type="checkbox" name="graph_show_table" value="1"' .
        $show_table . '><span>Show aggregate data below the graph</span></label>' .
        '<p>Choose a dashboard visualization for the selected groups and measures. A series group draws one line or bar set per value. The optional table shows the underlying aggregate values before graph transforms.</p></fieldset>';
}

sub _aggregate_grid_picker ($class, $state) {
    my $inactive = $state->view eq 'aggregate' ? '' : ' hidden disabled';
    my $enabled = $state->aggregate_grid ? ' checked' : '';
    my $colorize = $state->aggregate_grid_colorize ? ' checked' : '';
    my $scale = $state->aggregate_grid_color_scale;
    my $scales = join '', map {
        '<option value="' . $_ . '"' . ($_ eq $scale ? ' selected' : '') . '>' .
            _h(_humanize($_)) . '</option>'
    } qw(linear log);
    return '<fieldset class="sc-aggregate-grid-options" data-sc-aggregate-options' .
        $inactive . '><legend>Grid display</legend><label class="sc-option-check">' .
        '<input type="checkbox" name="aggregate_grid" value="1"' . $enabled .
        '><span>Grid view <small>2 Group By fields + 1 Aggregate</small></span></label>' .
        '<label class="sc-option-check"><input type="checkbox" ' .
        'name="aggregate_grid_colorize" value="1"' . $colorize .
        '><span>Heat map colors</span></label><label>Color scale<select ' .
        'name="aggregate_grid_color_scale">' . $scales . '</select></label></fieldset>';
}

sub _field_picker ($class, $state, $catalog, $config, $root_label = 'Main record') {
    return $class->_selection_picker(
        $state,
        $catalog,
        kind => 'field',
        legend => 'Columns',
        selected => $state->fields,
        configs => $state->field_configs,
        config_list => $state->field_config_list,
        maximum => scalar(@$catalog),
        search_label => 'Filter available fields',
        hint => 'Drag or use arrows to reorder columns. Configure labels and date formats per column.',
        set_label => 'Set columns',
        date_formats => $config->date_formats,
        root_label => $root_label,
    );
}

sub _group_picker ($class, $state, $catalog, $config, $root_label = 'Main record') {
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
        root_label => $root_label,
    );
}

sub _measure_picker ($class, $state, $catalog, $config, $root_label = 'Main record') {
    return $class->_selection_picker(
        $state,
        $catalog,
        kind => 'measure',
        legend => 'Measures',
        selected => $state->measures,
        configs => $state->measure_configs,
        config_list => $state->measure_config_list,
        maximum => $config->max_measures,
        search_label => 'Filter available aggregate columns',
        hint => 'Choose domain columns or curated presets, then configure functions, aliases, and buckets.',
        set_label => 'Set measures',
        config => $config,
        root_label => $root_label,
    );
}

sub _order_picker ($class, $state, $catalog, $maximum, $root_label = 'Main record') {
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
        root_label => $root_label,
    );
}

sub _selection_picker ($class, $state, $catalog, %options) {
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my $kind = $options{kind};
    my $selected_values = $options{selected};
    my $configs = $options{configs};
    my %selected = map { $_ => 1 } @$selected_values;
    my @available = $kind eq 'field'
        ? grep { !$_->{picker_hidden} && (($_->{type} // '') ne 'action' || !$selected{$_->{path}}) } @$catalog
        : $kind eq 'measure' ? grep { !$_->{picker_hidden} } @$catalog
        : grep { !$_->{picker_hidden} && !$selected{$_->{path}} } @$catalog;
    my $at_limit = @$selected_values >= $options{maximum};
    my $available_items = _grouped_picker_items(\@available, $options{root_label}, sub {
        my ($field, $group_key) = @_;
        local $_ = $field;
        '<button class="sc-picker-choice" type="button" data-sc-picker-action="add"' .
        ($at_limit ? ' disabled' : '') . ' ' .
        'data-sc-picker-available-item data-field="' . _h($_->{path}) . '" data-label="' .
        _h($_->{label}) . '" data-type="' . _h($_->{type}) . '" data-sc-picker-group-key="' .
        _h($group_key) . '" data-search="' .
        _h(lc($_->{label} . ' ' . $_->{type} . ' ' . $_->{path})) . '" data-default-function="' .
        _h($_->{default_function} // '') . '" data-measure-field="' .
        _h($_->{field} // '') . '"' .
        (($kind eq 'field' && ($_->{type} // '') ne 'action') || $kind eq 'measure'
            ? ' data-sc-picker-repeatable' : '') .
        '><span><strong>' . _h(_picker_leaf_label($_)) .
        '</strong><small>' . _h($_->{path} . ' - ' . $_->{type}) .
        '</small></span><span aria-hidden="true">+</span></button>'
    });
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
        my $item_config = ref($options{config_list}) eq 'ARRAY'
            ? ($options{config_list}->[$index] // {}) : ($configs->{$path} // {});
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
        '" data-sc-picker-group-key="' . _h(_picker_group_key($field)) .
        '"' . (($kind eq 'field' && ($field->{type} // '') ne 'action') || $kind eq 'measure'
            ? ' data-sc-picker-repeatable' : '') .
        '><input type="hidden" name="' . _h($kind) . '" value="' . _h($path) . '">' .
        '<button class="sc-picker-grip" type="button" title="Drag to reorder" aria-label="Drag ' .
        _h($field->{label}) . ' to reorder">⠿</button><span class="sc-picker-set-label"><strong>' .
        _h($field->{label}) . '</strong><small>' . _h($path . ' - ' . $field->{type}) . '</small></span>' .
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

sub _picker_group_key ($field) {
    return '_actions' if ($field->{type} // '') eq 'action';
    my $path = $field->{field} // $field->{path} // '';
    $path =~ s/\Afield://;
    return $path =~ /\A([^.]+)\./ ? $1 : '';
}

sub _picker_leaf_label ($field) {
    my $label = $field->{label} // '';
    return $label =~ s/\AAction:\s*//r if ($field->{type} // '') eq 'action';
    my $group = $field->{picker_group_label} // '';
    if (length($group)) {
        my $leaf = $label =~ s/\A\Q$group\E\s*[-:]\s*//r;
        return $leaf if length($leaf) && $leaf ne $label;
    }
    return $label;
}

sub _grouped_picker_items ($fields, $root_label, $render) {
    my %groups;
    push @{$groups{_picker_group_key($_)}}, $_ for @$fields;
    return join '', map {
        my $key = $_;
        my $label = $key eq '_actions' ? 'Actions'
            : length($key)
                ? ($groups{$key}[0]{picker_group_label} // _humanize($key))
                : ($root_label // 'Main record');
        my $items = join '', map { $render->($_, $key) } @{$groups{$key}};
        '<details class="sc-picker-group" data-sc-picker-group data-sc-picker-group-key="' .
            _h($key) . '" data-search-label="' . _h(lc($label)) . '"' .
            (length($key) ? '' : ' open') . '><summary>' . _h($label) .
            '<small>' . scalar(@{$groups{$key}}) . '</small></summary>' .
            '<div class="sc-picker-group-items" data-sc-picker-group-items>' .
            $items . '</div></details>'
    } sort { !length($a) ? -1 : !length($b) ? 1 : lc($a) cmp lc($b) } keys %groups;
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
        my $null_handling = $item_config->{null_handling} //
            ($item_config->{ignore_nulls} ? 'zero' : 'sql');
        my $series_id = $item_config->{series_id} // 'series';
        my $series_chart_type = $item_config->{chart_type} // 'auto';
        my $series_axis = $item_config->{axis} // 'auto';
        my $series_stack = $item_config->{stack} // '';
        my $series_color = $item_config->{color} // '';
        my $color_value = length($series_color) ? $series_color : '#55d6be';
        my $chart_options = join '', map {
            '<option value="' . $_->[0] . '"' .
                ($_->[0] eq $series_chart_type ? ' selected' : '') . '>' . $_->[1] . '</option>'
        } ([auto => 'Use chart default'], [bar => 'Bar'], [line => 'Line'], [area => 'Area']);
        my $axis_options = join '', map {
            '<option value="' . $_->[0] . '"' .
                ($_->[0] eq $series_axis ? ' selected' : '') . '>' . $_->[1] . '</option>'
        } ([auto => 'Automatic'], [left => 'Left'], [right => 'Right']);
        my %safe_transform = map { $_ => 1 } qw(
            percent_of_total percent_change index_to_first cumulative moving_average
        );
        my $transform_config = ref($item_config->{transforms}) eq 'ARRAY'
            && ref($item_config->{transforms}[0]) eq 'HASH'
            ? $item_config->{transforms}[0] : {};
        my $selected_transform = $transform_config->{type} // '';
        my $transform_options = '<option value=""' .
            ($selected_transform eq '' ? ' selected' : '') . '>None</option>';
        if (defined($item_config->{raw_unit})) {
            $transform_options .= join '', map {
                '<option value="' . _h($_->{id}) . '"' .
                    ($_->{id} eq $selected_transform ? ' selected' : '') . '>' .
                    _h($_->{label}) . '</option>'
            } grep { $safe_transform{$_->{id}} }
                @{Selecto::Analytics::TransformRegistry->catalog(
                    $item_config->{raw_unit}, $item_config->{behavior},
                )};
        }
        my $transform_window = ref($transform_config->{parameters}) eq 'HASH'
            ? $transform_config->{parameters}{window} // 3 : 3;
        my $window_visible = $selected_transform eq 'moving_average';
        $controls .= _hidden('measure_series_id', $series_id) .
            '<label>Function<select name="measure_function" data-sc-measure-function ' .
            'aria-label="Measure function for ' . _h($field->{label}) . '">' . $functions .
            '</select></label><label data-sc-measure-buckets' . ($bucket_visible ? '' : ' hidden') .
            '>Bucket ranges<input name="measure_bucket_ranges" value="' .
            _h($item_config->{bucket_ranges} // '') .
            '" placeholder="0-10, 11-50, 51+" aria-label="Measure bucket ranges for ' .
            _h($field->{label}) . '"></label><label data-sc-measure-sum' .
            ($sum_visible ? '' : ' hidden') . '>NULL handling<select name="measure_ignore_nulls" ' .
            'aria-label="NULL handling for ' . _h($field->{label}) . '"><option value="0"' .
            ($null_handling eq 'sql' ? ' selected' : '') . '>Keep SQL SUM behavior</option>' .
            '<option value="1"' . ($null_handling eq 'zero' ? ' selected' : '') .
            '>Always treat NULL as 0</option><option value="auto"' .
            ($null_handling eq 'auto' ? ' selected' : '') .
            '>Automatic for view</option></select><small>Automatic treats NULL as 0 in graphs and aggregates.</small></label>' .
            '<label>Series style<select name="measure_chart_type" aria-label="Series style for ' .
            _h($field->{label}) . '">' . $chart_options . '</select></label>' .
            '<label>Y axis<select name="measure_axis" aria-label="Y axis for ' .
            _h($field->{label}) . '">' . $axis_options . '</select></label>' .
            '<label>Stack group<input name="measure_stack" value="' . _h($series_stack) .
            '" maxlength="32" pattern="[a-z][a-z0-9_]*" placeholder="e.g. expenses" ' .
            'aria-label="Stack group for ' . _h($field->{label}) . '"><small>Series with the same group stack together.</small></label>' .
            '<div class="sc-series-color" data-sc-measure-color-control>' .
            '<span>Series color</span><input type="hidden" name="measure_color" value="' .
            _h($series_color) . '"><input type="color" value="' . _h($color_value) .
            '" data-sc-measure-color-picker aria-label="Color for ' . _h($field->{label}) . '"' .
            (length($series_color) ? '' : ' disabled') . '><label class="sc-option-check"><input ' .
            'type="checkbox" data-sc-measure-color-auto' . (length($series_color) ? '' : ' checked') .
            '><span>Automatic contrasting color</span></label></div>' .
            '<label>Transform<select name="measure_transform" data-sc-measure-transform ' .
            'aria-label="Analytical transform for ' . _h($field->{label}) . '">' .
            $transform_options . '</select></label>' .
            '<label data-sc-measure-transform-window' . ($window_visible ? '' : ' hidden') .
            '>Moving window<input type="number" min="2" max="365" ' .
            'name="measure_transform_window" value="' . _h($transform_window) .
            '" aria-label="Moving-average window for ' . _h($field->{label}) . '"></label>';
    }

    return '<details class="sc-column-config"><summary>Configure</summary>' .
        '<div class="sc-column-config-grid">' . $controls . '</div></details>';
}

sub _filter_picker ($class, $state, $catalog, $config, $root_label = 'Main record') {
    my $max_filters = $config->max_filters;
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my @ordinary_filters = map {
        my $filter = $state->filters->[$_];
        !defined($filter->{clause}) ? ({%$filter, instance => $_ + 1}) : ()
    } (@{$state->filters} ? (0 .. $#{$state->filters}) : ());
    my @available = grep { !$_->{picker_hidden} } @$catalog;
    my $at_limit = @ordinary_filters >= $max_filters;
    my $available_items = $at_limit ? '' : _grouped_picker_items(\@available, $root_label, sub {
        my ($field, $group_key) = @_;
        local $_ = $field;
        '<button class="sc-picker-choice" type="button" data-sc-filter-action="add" ' .
        'data-sc-filter-available-item data-field="' . _h($_->{path}) . '" data-label="' .
        _h($_->{label}) . '" data-type="' . _h($_->{type}) . '" data-sc-picker-group-key="' .
        _h($group_key) . '"' .
        _filter_choice_attribute($_) . ' data-search="' .
        _h(lc($_->{label} . ' ' . $_->{type} . ' ' . $_->{path})) . '"><span><strong>' . _h(_picker_leaf_label($_)) .
        '</strong><small>' . _h($_->{path} . ' - ' . $_->{type}) .
        '</small></span><span aria-hidden="true">+</span></button>'
    });
    $available_items ||= '<p class="sc-picker-empty">' .
        ($at_limit ? 'Maximum of ' . _h($max_filters) . ' filters set.' : 'Every available filter is set.') .
        '</p>';

    my $set_items = join '', map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        my $ops = join '', map {
            '<option value="' . $_->[0] . '"' . ($_->[0] eq $filter->{op} ? ' selected' : '') . '>' .
            _h($_->[1]) . '</option>'
        } @{_filter_operators_for_filter($config, $field, $filter)};
        my $input_field = $filter->{grouped} ? {%$field, type => 'string'} : $field;
        my $filter_controls = '<label>Operator<select name="filter_op" aria-label="Operator for ' .
            _h($field->{label}) . '">' . $ops . '</select></label>' .
            $class->_filter_value_controls($config, $input_field, $filter) .
            '<label class="sc-filter-promote"><input type="checkbox" name="filter_promote_index" value="' .
            _h($filter->{instance}) . '"' . ($filter->{promoted} ? ' checked' : '') .
            '> Promote to View Controller</label>';
        '<article class="sc-filter-set-item' . ($filter->{draft} ? ' is-draft' : '') .
        '" data-sc-filter-set-item' . ($filter->{grouped} ? ' data-sc-grouped-filter' : '') .
        ' data-field="' . _h($filter->{field}) . '" data-filter-instance="' .
        _h($filter->{instance}) . '" data-label="' .
        _h($field->{label}) . '" data-type="' .
        _h($filter->{grouped} ? 'string' : $field->{type}) . '"' .
        ($filter->{grouped} ? '' : _filter_choice_attribute($field)) . '>' .
        '<input type="hidden" name="filter_field" value="' . _h($filter->{field}) . '">' .
        _hidden('filter_group', $filter->{grouped} ? 1 : 0) .
        _hidden('filter_clause', '') .
        '<div class="sc-filter-set-heading"><span><strong>' . _h($field->{label}) . '</strong><small>' .
        _h($filter->{field} . ' - ' . $field->{type}) .
        '</small></span><button type="button" data-sc-filter-action="remove" ' .
        'aria-label="Remove ' . _h($field->{label}) . ' filter" title="Remove filter">×</button></div>' .
        '<div class="sc-filter-editor">' . $filter_controls . '</div>' .
        ($filter->{draft} ? '<p class="sc-filter-draft-note">' .
            _h($filter->{op} eq 'between' ? 'Enter both values to apply this filter.'
                : 'Enter a value to apply this filter.') . '</p>' : '') .
        '</article>'
    } @ordinary_filters;
    $set_items ||= '<p class="sc-picker-empty">Choose fields from Available to build filters.</p>';

    my $ordinary_picker = '<fieldset class="sc-picker-fieldset"><legend>Filters <small>up to ' . _h($max_filters) .
        '</small></legend><div class="sc-list-picker sc-filter-picker" data-sc-filter-root data-sc-filter-max="' .
        _h($max_filters) . '"><section class="sc-picker-pane"><div class="sc-picker-heading">' .
        '<span>Available</span><span data-sc-filter-available-count>' .
        ($at_limit ? 0 : scalar(@available)) . '</span></div><input class="sc-picker-filter" type="search" ' .
        'data-sc-filter-search placeholder="Filter available filters" aria-label="Filter available filters">' .
        '<div class="sc-picker-list" data-sc-filter-available>' . $available_items . '</div></section>' .
        '<section class="sc-picker-pane sc-picker-set-pane"><div class="sc-picker-heading"><span>Set</span>' .
        '<span data-sc-filter-set-count>' . scalar(@ordinary_filters) . '</span></div>' .
        '<p class="sc-picker-hint">Set filters are combined with AND.</p>' .
        '<div class="sc-picker-list sc-filter-set" data-sc-filter-set aria-label="Set filters">' .
        $set_items . '</div></section></div></fieldset>';
    return $class->_filter_clause_picker($state, \%by_path, $config) . $ordinary_picker;
}

sub _filter_clause_picker ($class, $state, $by_path, $config) {
    my %by_clause;
    my @order;
    for my $filter (@{$state->filters}) {
        next unless defined($filter->{clause});
        push @order, $filter->{clause} unless exists($by_clause{$filter->{clause}});
        push @{$by_clause{$filter->{clause}}}, $filter;
    }
    return '' unless @order;
    my %grid_fields = map { $_ => 1 } @{$state->groups // []};
    my $grid_mode = keys(%grid_fields) == 2
        && !grep { !$grid_fields{$_->{field}} } map { @$_ } values %by_clause;
    my $cards = join '', map {
        my $clause = $_;
        my $conditions = join '', map {
            my $filter = $_;
            my $field = $by_path->{$filter->{field}};
            return '' unless $field;
            my $ops = join '', map {
                '<option value="' . $_->[0] . '"' . ($_->[0] eq $filter->{op} ? ' selected' : '') . '>' .
                _h($_->[1]) . '</option>'
            } @{_filter_operators_for_filter($config, $field, $filter)};
            '<section class="sc-filter-clause-condition' . ($filter->{draft} ? ' is-draft' : '') .
                '" data-sc-filter-condition data-field="' . _h($filter->{field}) .
                '" data-label="' . _h($field->{label}) . '" data-type="' .
                _h($filter->{grouped} ? 'string' : $field->{type}) . '"' .
                ($filter->{grouped} ? '' : _filter_choice_attribute($field)) . '>' .
                _hidden('filter_field', $filter->{field}) .
                _hidden('filter_group', $filter->{grouped} ? 1 : 0) .
                _hidden('filter_clause', $clause) .
                ($grid_mode
                    ? _hidden('filter_op', $filter->{op}) .
                      _hidden('filter_value', $filter->{value}) .
                      _hidden('filter_value_end', $filter->{value_end} // '') .
                      '<strong>' . _h(_filter_summary_text($field->{label}, $filter, $field)) . '</strong>'
                    : '<strong>' . _h($field->{label}) . '</strong>' .
                      '<div class="sc-filter-editor"><label>Operator<select name="filter_op" aria-label="Operator for ' .
                      _h($field->{label}) . '">' . $ops . '</select></label>' .
                      $class->_filter_value_controls($config, $field, $filter) . '</div>') .
                '</section>'
        } @{$by_clause{$clause}};
        '<article class="sc-filter-clause' .
            ($by_clause{$clause}[0]{draft} ? ' is-draft' : '') .
            '" data-sc-filter-clause="' . _h($clause) . '"><header><div><small>Alternative</small>' .
            '<strong>' . ($grid_mode ? 'Selected area ' : 'Match ') . _h($clause) . '</strong></div>' .
            '<button type="button" data-sc-filter-clause-remove aria-label="Remove alternative ' .
            _h($clause) . '" title="Remove alternative">×</button></header>' .
            '<div class="sc-filter-clause-conditions">' . $conditions . '</div>' .
            ($by_clause{$clause}[0]{draft}
                ? '<p class="sc-filter-draft-note" data-sc-filter-clause-note>' .
                    'Complete all conditions to apply this alternative.</p>' : '') .
            '</article>'
    } @order;
    return '<fieldset class="sc-picker-fieldset sc-filter-clauses" data-sc-filter-clauses ' .
        'data-sc-filter-clause-mode="' . ($grid_mode ? 'grid' : 'ordinary') . '">' .
        '<legend>' . ($grid_mode ? 'Selected grid areas' : 'Alternative filters (OR)') .
        ' <small><span data-sc-filter-clause-count>' .
        scalar(@order) . '</span> of ' .
        _h($config->max_grid_cells) . '</small></legend>' .
        '<p class="sc-picker-hint">' . ($grid_mode
            ? 'Full rows and columns use one condition. Within a cell, row and column conditions use AND; selections use OR.'
            : 'Conditions within an alternative use AND. Alternatives use OR; regular filters apply to all alternatives.') .
        '</p><div class="sc-filter-clause-list">' .
        $cards . '</div></fieldset>';
}

sub _filter_operators_for_filter ($config, $field, $filter) {
    return [[eq => 'equals'], [is_null => 'is empty']] if $filter->{grouped};
    return [
        [eq => 'equals'], [ne => 'does not equal'],
        [in => 'one of'], [not_in => 'not one of'],
        [is_null => 'is empty'], [not_null => 'is not empty'],
    ] if ref($field->{filter_choices}) eq 'ARRAY' && @{$field->{filter_choices}};
    return $config->filter_operators($field->{type});
}

sub _filter_choice_attribute ($field) {
    return '' unless ref($field->{filter_choices}) eq 'ARRAY'
        && @{$field->{filter_choices}};
    return ' data-sc-filter-choices="' . _h(encode_json($field->{filter_choices})) . '"';
}

sub _filter_value_controls ($class, $config, $field, $filter) {
    my $operator = $filter->{op};
    my $value = $filter->{value} // '';
    my $value_end = $filter->{value_end} // '';
    my $label = $field->{label};
    my $type = $field->{type};
    my $input_type = $config->temporal_type($type)
        ? _temporal_filter_input_type($config, $type, $value, $value_end)
        : $config->filter_input_type($type);
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
    if (ref($field->{filter_choices}) eq 'ARRAY'
        && @{$field->{filter_choices}}
        && $operator =~ /\A(?:eq|ne|in|not_in)\z/) {
        my $multiple = $operator eq 'in' || $operator eq 'not_in';
        my %selected = map { my $id = $_; $id =~ s/\A\s+|\s+\z//g; $id => 1 }
            split /,/, $value, -1;
        my %known;
        my $options = $multiple ? '' : '<option value="">Choose a value</option>';
        for my $choice (@{$field->{filter_choices}}) {
            $known{$choice->{value}} = 1;
            $options .= '<option value="' . _h($choice->{value}) . '"' .
                ($selected{$choice->{value}} ? ' selected' : '') . '>' .
                _h($choice->{label}) . '</option>';
        }
        for my $unlisted (sort grep { length($_) && !$known{$_} } keys %selected) {
            $options .= '<option value="' . _h($unlisted) . '" selected>' .
                'Unavailable option</option>';
        }
        return $controls . '<label class="sc-filter-value-wide">' .
            ($multiple ? 'Values' : 'Value') .
            '<input type="text" name="filter_value" data-sc-filter-choice-value value="' .
            _h($value) . '" aria-label="Option IDs for ' . _h($label) . '">' .
            '<select data-sc-filter-choice-select' . ($multiple ? ' multiple size="6"' : '') .
            ' hidden aria-label="Choices for ' . _h($label) . '">' . $options . '</select>' .
            ($multiple ? '<small class="sc-filter-choice-hint">Use Ctrl or Command to select multiple options.</small>' : '') .
            '</label>' . _hidden('filter_value_end', '') . '</div>';
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

sub _temporal_filter_input_type ($config, $type, @values) {
    return 'date' if defined($type) && !ref($type) && lc("$type") eq 'date';
    my @populated = grep { defined($_) && !ref($_) && length("$_") } @values;
    return 'date' if @populated && !grep { "$_" !~ /\A\d{4}-\d{2}-\d{2}\z/ } @populated;
    return $config->filter_input_type($type);
}

1;
