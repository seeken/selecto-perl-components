package Selecto::Components::Renderer::Results;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use POSIX qw(ceil);
use Selecto::Components::Renderer::Markup;
use Selecto::Components::Renderer::Debug ();
use Selecto::Components::RowActions ();

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
    my $grid_warning = $model->{state}->view eq 'aggregate'
        && $model->{state}->aggregate_grid
        && !$result->{grid_data}
        ? '<div class="sc-grid-warning" role="status">Grid view requires exactly two Group By fields and one Aggregate.</div>'
        : '';
    my $body = $result->{graph} ? $class->_graph($result, $model)
        : $result->{grid_data} ? $class->_grid($result, $model)
        : $class->_table($result, $model);
    my $pagination = $class->_pagination($model);
    my $debug = Selecto::Components::Renderer::Debug->_debug_panel($result, $model);
    return $meta . $actions . $grid_warning . $body . $pagination . $debug;
}
sub _bulk_actions ($class, $model) {
    my $actions = $model->{bulk_actions} // [];
    return '' unless @$actions && $model->{result} && defined($model->{result}{action_key});
    my $config = $model->{config};
    my $panels = '';
    for my $action (@$actions) {
        if (($action->{selection}{mode} // 'rows') eq 'groups') {
            $panels .= _grouped_action_panel($model, $action);
            next;
        }
        my $id = $action->{id};
        my $dialog_id = 'selecto-action-' . $config->id . '-' . $id;
        my $dialog_title_id = $dialog_id . '-title';
        my $enabled = ($action->{status} // 'enabled') eq 'enabled';
        my $button = '<button type="button" class="sc-button sc-secondary" data-sc-action-open="' .
            _h($dialog_id) . '" data-sc-action-disabled="' . ($enabled ? '0' : '1') . '" disabled' .
            ($enabled ? '' : ' title="' . _h($action->{status_reason} // 'Action unavailable') . '"') .
            '>' . _h($action->{label}) . '</button>';
        my $inputs = join '', map { _action_input($_, $id) } @{$action->{inputs}};
        my $description = length($action->{description} // '')
            ? '<p class="sc-action-description">' . _h($action->{description}) . '</p>' : '';
        my $dialog = '<dialog class="sc-action-dialog" id="' . _h($dialog_id) .
            '" aria-labelledby="' . _h($dialog_title_id) . '" data-sc-action-dialog>' .
            '<form method="post" action="' . _h($config->path . '/actions/' . $id) .
            '" data-sc-action-form><header><div><p class="sc-eyebrow">Selected-row action</p><h3 id="' .
            _h($dialog_title_id) . '">' .
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
            _h($id) . '"><div role="status" aria-live="polite" aria-atomic="true"><strong ' .
            'data-sc-selection-count>0</strong> ' .
            '<span data-sc-selection-label>rows selected</span></div>' . $button . $dialog . '</section>';
    }
    return '<div class="sc-bulk-actions" data-sc-bulk-actions>' . $panels . '</div>';
}

sub _grouped_action_panel ($model, $action) {
    my $config = $model->{config};
    my $id = $action->{id};
    my $dialog_id = 'selecto-action-' . $config->id . '-' . $id;
    my $dialog_title_id = $dialog_id . '-title';
    my $enabled = ($action->{status} // 'enabled') eq 'enabled';
    my $description = length($action->{description} // '')
        ? '<p class="sc-action-description">' . _h($action->{description}) . '</p>' : '';
    my $button = '<button type="button" class="sc-button sc-secondary" data-sc-action-open="' .
        _h($dialog_id) . '" data-sc-action-disabled="' . ($enabled ? '0' : '1') . '" disabled' .
        ($enabled ? '' : ' title="' . _h($action->{status_reason} // 'Action unavailable') . '"') .
        '>' . _h($action->{label}) . '</button>';
    my $dialog = '<dialog class="sc-action-dialog sc-group-action-dialog" id="' . _h($dialog_id) .
        '" aria-labelledby="' . _h($dialog_title_id) .
        '" data-sc-action-dialog><form method="post" action="' .
        _h($config->path . '/actions/' . $id) .
        '" data-sc-action-form><header><div><p class="sc-eyebrow">Grouped-row action</p><h3 id="' .
        _h($dialog_title_id) . '">' .
        _h($action->{label}) . '</h3></div><button type="button" class="sc-action-close" ' .
        'data-sc-action-close aria-label="Close action form">×</button></header>' . $description .
        '<p class="sc-action-target-summary">Build <strong data-sc-action-group-count>0</strong> ' .
        'loads from <strong data-sc-action-selection-count>0</strong> selected rows.</p>' .
        '<input type="hidden" name="csrf_token" value="' . _h($model->{csrf_token} // '') . '">' .
        '<input type="hidden" name="return_to" value="' . _h($model->{canonical_url}) . '">' .
        '<input type="hidden" name="action_groups" value="[]" data-sc-action-groups>' .
        '<div data-sc-action-targets></div><div class="sc-group-action-groups" ' .
        'data-sc-group-action-groups></div>' .
        '<div class="sc-action-result" data-sc-action-result role="status" hidden></div>' .
        '<footer><button type="button" class="sc-button sc-secondary" data-sc-action-close>Cancel</button>' .
        '<button type="submit" class="sc-button sc-primary">' .
        _h($action->{submit_label}) . '</button></footer></form></dialog>';
    return '<section class="sc-bulk-action sc-group-action" data-sc-bulk-action ' .
        'data-sc-action-id="' . _h($id) . '" data-sc-action-mode="groups" ' .
        'data-sc-action-state-key="' . _h($config->id . ':' . $id) . '" ' .
        'data-sc-action-submit-label="' . _h($action->{submit_label}) . '" ' .
        'data-sc-action-markers="' . _h(encode_json($action->{selection}{markers})) . '" ' .
        'data-sc-group-inputs="' . _h(encode_json($action->{selection}{group_inputs})) . '">' .
        '<div role="status" aria-live="polite" aria-atomic="true"><strong ' .
        'data-sc-selection-count>0</strong> <span data-sc-selection-label>rows assigned</span>' .
        '<span class="sc-group-count-summary"> · <strong data-sc-group-count>0</strong> loads</span></div>' .
        $button . $dialog . '</section>';
}

sub _action_input ($input, $action_id = 'action') {
    my $name = 'action_input_' . $input->{id};
    my $required = $input->{required} ? ' required aria-required="true"' : '';
    my $marker = $input->{required} ? ' <span aria-hidden="true">*</span>' : '';
    my $control;
    if ($input->{type} eq 'lookup') {
        my $results_id = 'sc-action-lookup-' . $action_id . '-' . $input->{id};
        my $placeholder = $input->{placeholder}
            // ('Search and choose ' . lc($input->{label}));
        my $hint = $input->{direct_entry}
            ? 'Search and choose a result, or enter a known ID.'
            : 'Search and choose a result.';
        $control = '<div class="sc-action-lookup" data-sc-action-lookup>' .
            '<input type="hidden" name="' . _h($name) . '" data-sc-lookup-value>' .
            '<input type="search" class="sc-action-lookup-query" autocomplete="off" spellcheck="false" ' .
            'data-sc-lookup-query data-sc-lookup-url="' . _h($input->{lookup_url}) . '" ' .
            'data-sc-lookup-input="' . _h($input->{id}) . '" ' .
            'data-sc-lookup-minimum-length="' . _h($input->{minimum_query_length} // 2) . '" ' .
            'data-sc-lookup-direct-entry="' . ($input->{direct_entry} ? 1 : 0) . '" ' .
            'data-sc-lookup-value-type="' . _h($input->{value_type} // 'string') . '" ' .
            'data-sc-lookup-selected-value="" placeholder="' . _h($placeholder) . '" ' .
            'role="combobox" aria-autocomplete="list" aria-expanded="false" ' .
            'aria-controls="' . _h($results_id) . '" aria-label="' . _h($input->{label}) . '"' .
            $required . '><div class="sc-action-lookup-results" data-sc-lookup-results id="' .
            _h($results_id) . '" role="listbox" hidden></div>' .
            '<small class="sc-action-lookup-hint">' . _h($hint) . '</small></div>';
    } elsif ($input->{type} eq 'select') {
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
    my $element = $input->{type} eq 'lookup' ? 'div' : 'label';
    return '<' . $element . ' class="sc-action-input"><span>' . _h($input->{label}) . $marker .
        '</span>' . $control . '</' . $element . '>';
}

sub _table ($class, $result, $model) {
    my %actions = map { $_->{id} => $_ } @{$model->{bulk_actions} // []};
    my @columns = grep { !$_->{action_id} || $actions{$_->{action_id}} } @{$result->{columns}};
    my $head = join '', map {
        my $column = $_;
        if ($column->{action_id}) {
            my $action = $actions{$column->{action_id}};
            ($action->{selection}{mode} // 'rows') eq 'groups'
                ? '<th scope="col" class="sc-select-column sc-group-select-column" ' .
                    'data-sc-action-column="' . _h($column->{action_id}) . '">' .
                    _h($column->{label}) . '</th>'
                : '<th scope="col" class="sc-select-column" data-sc-action-column="' .
                    _h($column->{action_id}) . '"><label><input type="checkbox" data-sc-select-page ' .
                    'data-sc-action-id="' . _h($column->{action_id}) . '" aria-label="Select every row for ' .
                    _h($column->{label}) . '"><span>' . _h($column->{label}) . '</span></label></th>';
        } else {
            '<th scope="col"' . _numeric_measure_class($column, $model) . '>' .
                _h($column->{label}) . '</th>';
        }
    } @columns;
    my @group_indexes = grep { !$columns[$_]{measure} && !$columns[$_]{action_id} } 0 .. $#columns;
    my %group_position = map { $group_indexes[$_] => $_ } 0 .. $#group_indexes;
    my $rows = '';
    my $row_dialog_id = 'selecto-row-dialog-' .
        ($model->{config} && $model->{config}->can('id') ? $model->{config}->id : 'results');
    my $row_dialog_action;
    my $row_dialog_count = 0;
    for my $index (0 .. $#{$result->{records}}) {
        my $record = $result->{records}[$index];
        my $continued = $result->{rollup} && $record->{__selecto_rollup_continued};
        my $level = $result->{rollup}
            ? $record->{__selecto_rollup_level} : scalar(@group_indexes);
        my $row_class = !$result->{rollup} ? ''
            : $continued
                ? ' class="sc-rollup-row sc-rollup-continued" data-rollup-level="' .
                    _h($level) . '" data-rollup-continued="1"'
            : $level == 0 ? ' class="sc-rollup-row sc-rollup-total" data-rollup-level="0"'
            : $level < @group_indexes
                ? ' class="sc-rollup-row sc-rollup-subtotal" data-rollup-level="' . _h($level) . '"'
                : ' class="sc-rollup-row sc-rollup-detail" data-rollup-level="' . _h($level) . '"';
        my $row_action = $continued ? undef : Selecto::Components::RowActions->resolve(
            $result->{row_click_action}, $record, $result->{row_click_fields},
        );
        if ($row_action) {
            $row_class = ' class="sc-clickable-row" tabindex="0" data-sc-row-click ' .
                'data-sc-row-click-type="' . _h($row_action->{type}) . '" ' .
                'data-sc-row-click-url="' . _h($row_action->{url}) . '" ';
            if ($row_action->{type} eq 'iframe_modal') {
                $row_dialog_action //= $row_action;
                $row_dialog_count++;
                $row_class .= 'data-sc-row-dialog-id="' . _h($row_dialog_id) . '" ' .
                    'data-sc-row-click-title="' . _h($row_action->{title}) . '" ' .
                    'aria-label="' . _h('Preview ' . $row_action->{title}) . '"';
            } else {
                $row_class .= 'data-sc-row-click-target="' . _h($row_action->{target}) . '" ' .
                    'aria-label="' . _h('Open ' . $result->{row_click_action}{name}) . '"';
            }
        }
        my $cells = '';
        for my $column_index (0 .. $#columns) {
            my $column = $columns[$column_index];
            if ($column->{action_id}) {
                my $target = $record->{$result->{action_key}};
                my $action = $actions{$column->{action_id}};
                my $eligibility_field = $result->{action_eligibility_fields}{$column->{action_id}}
                    // $action->{selection}{eligibility_field};
                my $eligible = !defined($eligibility_field)
                    || $record->{$eligibility_field} ? 1 : 0;
                unless ($eligible && defined($target) && "$target" ne '') {
                    $cells .= '<td class="sc-select-column sc-action-ineligible" ' .
                        'data-sc-action-column="' . _h($column->{action_id}) . '" ' .
                        'data-sc-action-eligible="0"></td>';
                    next;
                }
                if (($action->{selection}{mode} // 'rows') eq 'groups') {
                    my $detail_specs = $result->{action_row_details}{$column->{action_id}} // [];
                    my @row_details = map {
                        +{
                            id => $_->{id},
                            label => $_->{label},
                            value => defined($record->{$_->{key}}) && !ref($record->{$_->{key}})
                                ? "$record->{$_->{key}}" : '',
                        }
                    } grep { ref($_) eq 'HASH' } @$detail_specs;
                    my $row_details = @row_details
                        ? ' data-sc-row-details="' . _h(encode_json(\@row_details)) . '"' : '';
                    $cells .= '<td class="sc-select-column sc-group-select-column" ' .
                        'data-sc-action-column="' . _h($column->{action_id}) . '"><div ' .
                        'class="sc-group-markers" data-sc-group-markers data-sc-action-id="' .
                        _h($column->{action_id}) . '" data-sc-row-id="' .
                        _h($target) . '"' . $row_details . '></div></td>';
                } else {
                    $cells .= '<td class="sc-select-column" data-sc-action-column="' .
                        _h($column->{action_id}) . '"><input type="checkbox" data-sc-row-select ' .
                        'data-sc-action-id="' . _h($column->{action_id}) . '" value="' .
                        _h($target) . '" aria-label="Select row ' .
                        _h($index + 1) . ' for ' . _h($column->{label}) . '"' .
                        '></td>';
                }
                next;
            }
            if ($column->{nested}) {
                $cells .= '<td class="sc-nested-cell">' .
                    _nested_table($column, $record->{$column->{key}}, $index + 1) . '</td>';
                next;
            }
            if ($column->{measure}) {
                $cells .= '<td' . _numeric_measure_class($column, $model) . '>' .
                    ($continued
                        ? '<span class="sc-rollup-continued-measure">-</span>'
                        : _html_display($column, $record->{$column->{key}})) . '</td>';
                next;
            }
            my $group_index = $group_position{$column_index};
            my $content = '';
            if ($result->{rollup} && $level == 0) {
                $content = $group_index == 0 ? '<span class="sc-rollup-total-label">Total</span>' : '';
            } elsif (!$result->{rollup} || $group_index == $level - 1) {
                my $label_html = _html_display($column, $record->{$column->{key}}, 1);
                my $pairs = $result->{drilldowns}[$index][$group_index];
                if ($continued) {
                    my $continued_label = '<span class="sc-rollup-continued-label">' .
                        $label_html . ' <span>(continued)</span></span>';
                    $content = $pairs
                        ? $class->_drilldown_control(
                            $model, $pairs, $continued_label, $group_index + 1,
                        )
                        : $continued_label;
                } else {
                    $content = $pairs
                        ? $class->_drilldown_control(
                            $model, $pairs, $label_html, $group_index + 1,
                        )
                        : $column->{link}
                            ? _object_link($column, $record, $label_html)
                            : $label_html;
                }
            }
            $cells .= '<td>' . $content . '</td>';
        }
        $rows .= '<tr' . $row_class . '>' . $cells . '</tr>';
    }
    my $column_count = scalar(@columns);
    $rows ||= '<tr><td class="sc-empty-cell" colspan="' . $column_count . '">No rows matched this query.</td></tr>';
    my $dialog = $row_dialog_action
        ? _row_iframe_dialog($row_dialog_id, $row_dialog_action, $row_dialog_count) : '';
    return '<div class="sc-table-wrap"><table><caption class="sc-visually-hidden">Query results</caption>' .
        '<thead><tr>' . $head . '</tr></thead><tbody>' . $rows . '</tbody></table></div>' .
        $dialog;
}

sub _grid ($class, $result, $model) {
    my $grid = $result->{grid_data};
    my $state = $model->{state};
    my $colorize = $state->aggregate_grid_colorize ? 1 : 0;
    my $scale = $state->aggregate_grid_color_scale;
    my $heading = '<div class="sc-grid-heading"><strong>Aggregate Grid</strong>' .
        ($colorize ? '<span>' . _h(_humanize($scale)) . ' heat scale</span>' : '') .
        '</div>';
    my $legend = '';
    if ($colorize) {
        my $swatches = join '', map {
            '<span style="background:color-mix(in srgb, var(--sc-accent) ' . $_ .
                '%, var(--sc-panel))"></span>'
        } (10, 16, 22, 28, 34, 40, 46, 52, 58, 64);
        $legend = '<div class="sc-grid-legend"><strong>Color legend</strong><span>Low</span>' .
            '<span class="sc-grid-legend-scale" aria-label="Grid color legend">' .
            $swatches . '</span><span>High</span></div>';
    }

    my $method = $model->{config}->query_params_enabled($model->{domain}) ? 'get' : 'post';
    my $hidden = '';
    my $selection_pairs = $grid->{selection_pairs} // [];
    for (my $index = 0; $index < @$selection_pairs; $index += 2) {
        $hidden .= _hidden($selection_pairs->[$index], $selection_pairs->[$index + 1]);
    }
    my $column_index = 0;
    my $head = '<th scope="col" class="sc-grid-corner"><label class="sc-grid-axis-toggle">' .
        '<input class="sc-grid-axis-input" type="checkbox" data-sc-grid-toggle-all ' .
        'aria-label="Select all grid cells">' .
        '<span>' . _h($grid->{row_axis}{label}) . '<small> / ' .
        _h($grid->{column_axis}{label}) . '</small></span></label></th>' . join('', map {
            my $column = $_;
            my $index = $column_index++;
            '<th scope="col"><label class="sc-grid-axis-toggle"><input class="sc-grid-axis-input" ' .
                'type="checkbox" name="grid_axis" value="' .
                _h(encode_json({axis => 1, value => $column->{selection_value}})) . '" ' .
                'data-sc-grid-column-toggle="' . _h($index) . '" aria-label="Select column ' .
                _h(_display_group($column->{value})) . '"><span>' .
                _html_display($grid->{column_axis}, $column->{value}, 1) . '</span></label></th>'
        } @{$grid->{columns}});

    my $rows = '';
    my $row_index = 0;
    for my $row (@{$grid->{rows}}) {
        my $current_row = $row_index++;
        my $cells = '<th scope="row"><label class="sc-grid-axis-toggle"><input ' .
            'class="sc-grid-axis-input" type="checkbox" name="grid_axis" value="' .
            _h(encode_json({axis => 0, value => $row->{selection_value}})) . '" ' .
            'data-sc-grid-row-toggle="' . _h($current_row) . '" aria-label="Select row ' .
            _h(_display_group($row->{value})) . '"><span>' .
            _html_display($grid->{row_axis}, $row->{value}, 1) . '</span></label></th>';
        my $current_column = 0;
        for my $column (@{$grid->{columns}}) {
            my $row_cells = $grid->{cells}{$row->{key}};
            my $cell = ref($row_cells) eq 'HASH' ? $row_cells->{$column->{key}} : undef;
            unless ($cell) {
                $cells .= '<td class="sc-grid-cell sc-grid-empty-cell" data-sc-grid-row="' .
                    _h($current_row) . '" data-sc-grid-column="' .
                    _h($current_column) . '"><label class="sc-grid-cell-toggle"><input ' .
                    'class="sc-grid-cell-input" type="checkbox" name="grid_cell" value="' .
                    _h(encode_json([$row->{selection_value}, $column->{selection_value}])) . '" ' .
                    'data-sc-grid-cell data-sc-grid-row="' . _h($current_row) .
                    '" data-sc-grid-column="' . _h($current_column) . '" aria-label="Select empty ' .
                    _h(_display_group($row->{value}) . ', ' .
                        _display_group($column->{value})) . '"><span class="sc-grid-cell-value">—</span>' .
                    '<span class="sc-grid-cell-selected" aria-hidden="true">&#10003;</span></label></td>';
                $current_column++;
                next;
            }
            my $heat = $colorize ? _grid_heat_percentage(
                $cell->{value}, $grid->{maximum_positive}, $scale,
            ) : undef;
            my $style = defined($heat)
                ? ' style="background:color-mix(in srgb, var(--sc-accent) ' .
                    _h($heat) . '%, var(--sc-panel))" data-sc-grid-heat="' .
                    _h($heat) . '"'
                : '';
            $cells .= '<td class="sc-grid-cell' .
                (_numeric_measure_class($grid->{measure}, $model) ? ' sc-numeric-measure' : '') .
                '" data-sc-grid-row="' . _h($current_row) . '" data-sc-grid-column="' .
                _h($current_column) . '"' . $style . '><label class="sc-grid-cell-toggle"><input ' .
                'class="sc-grid-cell-input" type="checkbox" ' .
                'name="grid_cell" value="' . _h(encode_json($cell->{selection_values})) . '" ' .
                'data-sc-grid-cell data-sc-grid-row="' . _h($current_row) .
                '" data-sc-grid-column="' . _h($current_column) . '" aria-label="Select ' .
                _h(_display_group($row->{value}) . ', ' .
                    _display_group($column->{value})) . '"><span class="sc-grid-cell-value">' .
                _html_display($grid->{measure}, $cell->{value}) .
                '</span><span class="sc-grid-cell-selected" aria-hidden="true">&#10003;</span></label></td>';
            $current_column++;
        }
        $rows .= '<tr>' . $cells . '</tr>';
    }
    my $column_count = 1 + scalar(@{$grid->{columns}});
    $rows ||= '<tr><td class="sc-empty-cell" colspan="' . $column_count .
        '">No rows matched this query.</td></tr>';
    my $max_cells = $model->{config}->max_grid_cells;
    my $selection_controls = '<div class="sc-grid-selection-actions"><span role="status" ' .
        'aria-live="polite"><strong data-sc-grid-selection-count>0</strong> ' .
        '<span data-sc-grid-selection-label>cells selected</span></span><span class="sc-grid-selection-buttons">' .
        '<button class="sc-button sc-secondary" type="button" data-sc-grid-clear disabled>Clear</button>' .
        '<button class="sc-button sc-primary" type="submit" data-sc-grid-apply>' .
        'Show selected details</button></span></div><p class="sc-grid-selection-help" ' .
        'data-sc-grid-selection-help>Selections may compile to at most ' .
        _h($max_cells) . ' filter groups. Full rows and columns become one condition.</p>';
    return '<form class="sc-grid-selection-form" action="' . _h($model->{config}->path) .
        '" method="' . $method . '" hx-ws:send data-sc-grid-selection data-sc-grid-max="' .
        _h($max_cells) . '">' . $hidden . $heading . $legend . $selection_controls .
        '<div class="sc-table-wrap sc-aggregate-grid-wrap"><table class="sc-aggregate-grid">' .
        '<caption class="sc-visually-hidden">Aggregate grid of ' .
        _h($grid->{measure}{label}) . ' by ' . _h($grid->{row_axis}{label}) .
        ' and ' . _h($grid->{column_axis}{label}) . '</caption><thead><tr>' .
        $head . '</tr></thead><tbody>' . $rows . '</tbody></table></div>' .
        '<noscript><p class="sc-note">Choose cells and submit with Show selected details.</p></noscript></form>';
}

sub _grid_heat_percentage ($value, $maximum, $scale) {
    return undef unless defined($value) && !ref($value) && _numeric($value)
        && $value > 0 && defined($maximum) && $maximum > 0;
    my $ratio = $scale eq 'log'
        ? log($value + 1) / log($maximum + 1)
        : $value / $maximum;
    my $bucket = ceil($ratio * 10);
    $bucket = 1 if $bucket < 1;
    $bucket = 10 if $bucket > 10;
    return 10 + (($bucket - 1) * 6);
}

sub _numeric_measure_class ($column, $model) {
    return '' unless $column->{measure};
    my $config = $model->{config};
    return '' unless $config && $config->can('numeric_type')
        && $config->numeric_type($column->{type});
    return ' class="sc-numeric-measure"';
}

sub _row_iframe_dialog ($dialog_id, $action, $row_count) {
    my $title_id = $dialog_id . '-title';
    my $navigation = $action->{navigation_enabled} ? '' : ' hidden';
    my $allow = defined($action->{allow})
        ? ' allow="' . _h($action->{allow}) . '"' : '';
    my $sandbox = defined($action->{sandbox})
        ? ' sandbox="' . _h($action->{sandbox}) . '"' : '';
    return '<dialog class="sc-row-dialog sc-row-dialog-' . _h($action->{size}) . '" id="' .
        _h($dialog_id) . '" aria-labelledby="' . _h($title_id) . '" data-sc-row-dialog ' .
        'data-sc-row-dialog-navigation="' . ($action->{navigation_enabled} ? '1' : '0') . '">' .
        '<section class="sc-row-dialog-panel"><header><div><p class="sc-eyebrow">Result details</p>' .
        '<h3 id="' . _h($title_id) . '" data-sc-row-dialog-title>' . _h($action->{title}) .
        '</h3></div><button type="button" class="sc-action-close" data-sc-row-dialog-close ' .
        'aria-label="Close detail preview">×</button></header>' .
        '<div class="sc-row-dialog-toolbar"><div class="sc-row-dialog-navigation"' . $navigation .
        '><button type="button" class="sc-button sc-secondary" data-sc-row-dialog-nav="previous">' .
        'Previous</button><button type="button" class="sc-button sc-secondary" ' .
        'data-sc-row-dialog-nav="next">Next</button></div>' .
        '<span data-sc-row-dialog-position aria-live="polite">Row 1 of ' . _h($row_count) .
        ' on this page</span><a class="sc-button sc-secondary" href="#" target="_blank" ' .
        'rel="noopener" data-sc-row-dialog-open>Open full page</a></div>' .
        '<div class="sc-row-dialog-frame-shell"><div class="sc-row-dialog-loading" ' .
        'data-sc-row-dialog-loading role="status" hidden>Loading details…</div>' .
        '<iframe data-sc-row-dialog-frame title="' . _h($action->{title}) . '" loading="lazy" ' .
        'referrerpolicy="' . _h($action->{referrer_policy}) . '"' . $allow . $sandbox . '></iframe></div>' .
        '<footer><button type="button" class="sc-button sc-secondary" ' .
        'data-sc-row-dialog-close>Close</button></footer></section></dialog>';
}

sub _nested_table ($column, $value, $row_number = undef) {
    my @fields = @{$column->{nested_fields} // []};
    return '<span class="sc-nested-empty">No data</span>' unless @fields;
    my $caption = defined($row_number)
        ? ($column->{label} // 'Nested data') . ', result row ' . $row_number
        : ($column->{label} // 'Nested data');
    my $head = '<thead><tr>' . join('', map {
        '<th scope="col">' . _h($_->{label}) . '</th>'
    } @fields) . '</tr></thead>';
    my $rows = ref($value) eq 'ARRAY' && @$value ? join('', map {
        my $record = ref($_) eq 'HASH' ? $_ : {};
        '<tr>' . join('', map {
            my $cell = $record->{$_->{field}};
            my $display = ref($cell) ? encode_json($cell) : _display($cell);
            '<td>' . _html_display($_, $display) . '</td>'
        } @fields) . '</tr>'
    } @$value) : '<tr><td class="sc-nested-empty" colspan="' . scalar(@fields) . '">No data</td></tr>';
    return '<table class="sc-nested-table"><caption class="sc-visually-hidden">' .
        _h($caption) . '</caption>' . $head . '<tbody>' . $rows . '</tbody></table>';
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

sub _drilldown_control ($class, $model, $pairs, $label_html, $level, $options = undef) {
    $options = {} unless ref($options) eq 'HASH';
    my $method = $model->{config}->query_params_enabled($model->{domain}) ? 'get' : 'post';
    my $hidden = '';
    for (my $index = 0; $index < @$pairs; $index += 2) {
        $hidden .= _hidden($pairs->[$index], $pairs->[$index + 1]);
    }
    my $button_class = $options->{grid}
        ? 'sc-drilldown-value sc-grid-drilldown-value' : 'sc-drilldown-value';
    my $style = $options->{grid} ? ''
        : ' style="--sc-rollup-level:' . _h($level) . '"';
    return '<form class="sc-drilldown-form" action="' . _h($model->{config}->path) . '" method="' .
        $method . '" hx-ws:send>' . $hidden .
        '<button class="' . $button_class . '"' . $style .
        ' type="submit">' . $label_html . '</button></form>';
}

sub _pagination ($class, $model) {
    my $state = $model->{state};
    return '' if $model->{result}{grid_data};
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

1;
