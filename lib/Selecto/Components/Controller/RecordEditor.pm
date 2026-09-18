package Selecto::Components::Controller::RecordEditor;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Digest::SHA qw(hmac_sha256_hex);
use Encode qw(encode_utf8);
use JSON::PP ();
use Mojo::Util qw(secure_compare url_escape xml_escape);
use Scalar::Util qw(blessed);
use Selecto::Components::Actions ();
use Selecto::Components::RecordEditor ();
use Selecto::Components::Renderer::Results ();

my $JSON = JSON::PP->new->canonical->allow_nonref;

sub show ($class, $controller, $explorer) {
    my ($context, $error) = _context($controller, $explorer);
    return _error($controller, $error->{status}, $error->{message}) if $error;
    my $record;
    my $ok = eval {
        $record = Selecto::Components::RecordEditor->load(
            $context->{engine}, $context->{editor}, $context->{target},
        );
        1;
    };
    unless ($ok) {
        $controller->app->log->error("Selecto record editor load failed: $@");
        return _error($controller, 500, 'The record could not be loaded.');
    }
    return _error($controller, 404, 'That record is not available.') unless $record;

    my $snapshot = {
        map { $_->{field} => $record->{$_->{field}} }
        grep { !$_->{readonly} } @{$context->{editor}{fields}}
    };
    my $snapshot_json = $JSON->encode($snapshot);
    my $signature = _signature(
        $controller, $context->{editor}{id}, $context->{target}, $snapshot_json,
    );
    my $html = _form($controller, $context, $record, $snapshot_json, $signature);
    $controller->res->headers->cache_control('no-store');
    # `data` is reserved for response bytes in Mojolicious and bypasses the
    # renderer's UTF-8 encoding. Editor HTML can contain Unicode from labels,
    # values, and its own empty-value marker, so render it as text before the
    # renderer optionally applies gzip compression.
    return $controller->render(text => $html, format => 'html', status => 200);
}

sub save ($class, $controller, $explorer) {
    my ($context, $error) = _context($controller, $explorer);
    my $return_to = Selecto::Components::_safe_return_to(
        $explorer->config, scalar $controller->param('return_to'),
    );
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, %$error,
    }) if $error;

    my $submitted_token = $controller->param('csrf_token') // '';
    my $expected_token = $controller->session('selecto_components_csrf') // '';
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => 'The edit form expired. Reload the row and try again.',
    }) unless length($submitted_token) && length($expected_token)
        && secure_compare("$submitted_token", "$expected_token");

    my $snapshot_json = $controller->param('record_snapshot') // '';
    my $submitted_signature = $controller->param('record_signature') // '';
    my $expected_signature = _signature(
        $controller, $context->{editor}{id}, $context->{target}, $snapshot_json,
    );
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => 'The record snapshot is invalid. Reload the row and try again.',
    }) unless length($submitted_signature)
        && secure_compare("$submitted_signature", "$expected_signature");

    my $original;
    my $decoded = eval { $original = $JSON->decode($snapshot_json); 1 };
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 422,
        message => 'The record snapshot could not be read. Reload the row and try again.',
    }) unless $decoded && ref($original) eq 'HASH';
    my %allowed = map { $_->{field} => 1 }
        grep { !$_->{readonly} } @{$context->{editor}{fields}};
    my @snapshot_unknown = grep { !$allowed{$_} } keys %$original;
    my @snapshot_missing = grep { !exists($original->{$_}) } keys %allowed;
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 422,
        message => 'The record snapshot does not match this editor.',
    }) if @snapshot_unknown || @snapshot_missing;

    my @parameter_names = @{$controller->req->params->names};
    my @forged = grep {
        my $name = $_;
        $name =~ s/\Aeditor_field_//;
        $_ =~ /\Aeditor_field_/ && !$allowed{$name}
    } @parameter_names;
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 422,
        message => 'The edit includes a field that is not available in this editor.',
    }) if @forged;

    my %params;
    for my $spec (@{$context->{editor}{fields}}) {
        next if $spec->{readonly};
        my $field = $spec->{field};
        my @values = $controller->every_param('editor_field_' . $field);
        next unless @values || ($spec->{control} // '') eq 'checkbox';
        $params{$field} = @values > 1 ? \@values : $values[0];
    }
    my $normalized = Selecto::Components::RecordEditor->normalize(
        $context->{domain}, $context->{editor}, \%params, $original,
    );
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 422,
        message => 'Correct the highlighted fields and try again.',
        field_errors => $normalized->{errors},
    }) unless $normalized->{valid};

    my $assignments = Selecto::Components::RecordEditor->changed(
        $context->{editor}, $original, $normalized->{values},
    );
    my $result;
    my $saved = eval {
        my $handler = $context->{config}->record_editor_handler;
        $result = $handler
            ? $handler->($controller, {
                engine => $context->{engine}, domain => $context->{domain},
                editor => $context->{editor}, target_id => $context->{target},
                original => {%$original}, assignments => {%$assignments},
                default_save => sub {
                    return Selecto::Components::RecordEditor->save(
                        $context->{engine}, $context->{target}, $original, $assignments,
                    );
                },
            })
            : Selecto::Components::RecordEditor->save(
                $context->{engine}, $context->{target}, $original, $assignments,
            );
        die "record editor handler returned an invalid result\n"
            unless ref($result) eq 'HASH';
        1;
    };
    unless ($saved) {
        my $caught = $@;
        if (blessed($caught) && $caught->can('code')
            && $caught->code eq 'cardinality_mismatch') {
            return Selecto::Components::_action_response($controller, $return_to, {
                ok => 0, status => 409, code => 'record_changed',
                message => 'This record changed after you opened it. Reload the row and review the newer values.',
            });
        }
        $controller->app->log->error("Selecto record editor save failed: $caught");
        return Selecto::Components::_action_response($controller, $return_to, {
            ok => 0, status => 500,
            message => 'The record could not be saved. No row replacement was made.',
        });
    }

    my $visible;
    my $reloaded = eval {
        $visible = Selecto::Components::RecordEditor->load(
            $context->{engine}, $context->{editor}, $context->{target},
        );
        1;
    };
    $visible = undef unless $reloaded;
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 1,
        status => 200,
        message => keys(%$assignments) ? 'The record was updated.' : 'No changes were needed.',
        row_id => "" . $context->{target},
        changed_fields => [sort keys %$assignments],
        authorized => $visible ? 1 : 0,
        return_to => $return_to,
        affected_rows => $result->{affected_rows} // 0,
        close_dialog => $result->{close_dialog} ? 1 : 0,
    });
}

sub _context ($controller, $explorer) {
    my $config = $explorer->config->for_request($controller);
    my ($engine, $domain, $editor);
    my $ok = eval {
        $engine = $config->engine($controller);
        $domain = $engine->domain;
        $editor = Selecto::Components::RecordEditor->find(
            $domain, scalar($controller->param('editor')),
        );
        1;
    };
    unless ($ok) {
        $controller->app->log->error("Selecto record editor discovery failed: $@");
        return (undef, {status => 500, message => 'The editor could not be prepared.'});
    }
    return (undef, {status => 404, message => 'That editor is not available.'})
        unless $editor;
    my $target = $controller->stash('selecto_record_id') // '';
    return (undef, {status => 404, message => 'That record is not available.'})
        if ref($target) || "$target" eq '' || length("$target") > 200;
    return ({config => $config, engine => $engine, domain => $domain,
        editor => $editor, target => "$target"}, undef);
}

sub _form ($controller, $context, $record, $snapshot, $signature) {
    my $editor = $context->{editor};
    my $field_map = $context->{config}->field_map($context->{domain});
    my @rendered = map {
        my $spec = $_;
        my $field = $spec->{field};
        my $label = $spec->{label} // $field_map->{$field}{label} // $field;
        my $type = lc($context->{domain}->resolve($field)->{type} // 'string');
        my $options = $spec->{options}
            // $context->{domain}->field_metadata($field)->{options};
        my $control = $spec->{control}
            // (ref($options) eq 'ARRAY' && @$options
                ? 'select'
                : Selecto::Components::RecordEditor::_control_for_type($type));
        my $value = $record->{$field};
        my $required = $spec->{required} ? ' required aria-required="true"' : '';
        my $marker = $spec->{required} ? ' <span aria-hidden="true">*</span>' : '';
        my $placeholder = defined($spec->{placeholder})
            ? ' placeholder="' . _h($spec->{placeholder}) . '"' : '';
        my $input;
        if ($spec->{readonly}) {
            $input = '<output class="sc-record-editor-readonly">' .
                _h(defined($value) && "$value" ne '' ? $value : '—') . '</output>';
        } elsif ($control eq 'textarea') {
            $input = '<textarea name="editor_field_' . _h($field) . '" rows="' .
                _h($spec->{rows} // 4) . '"' . $required . $placeholder . '>' .
                _h($value // '') . '</textarea>';
        } elsif ($control eq 'select') {
            my %available = map {
                defined($_->{value}) && !ref($_->{value})
                    ? (("" . $_->{value}) => 1) : ()
            } @{$options // []};
            my $display_value = $context->{domain}->normalize_field_value(
                $field, $value,
            );
            $display_value = $value unless defined($display_value)
                && $available{"$display_value"};
            my $current_option = defined($display_value) && "$display_value" ne ''
                    && !$available{"$display_value"}
                ? '<option value="' . _h($value) .
                    '" selected data-sc-legacy-current-value>' .
                    _h("Current value — $value (not in current choices)") .
                    '</option>'
                : '';
            my $has_display_value = defined($display_value)
                && "$display_value" ne '';
            my $empty_option = _select_empty_option(
                $spec, $has_display_value,
            );
            my $option_html = join '', map {
                '<option value="' . _h($_->{value}) . '"' .
                    (defined($display_value) && "$display_value" eq ("" . $_->{value}) ? ' selected' : '') . '>' .
                    _h($_->{label}) . '</option>'
            } @{$options // []};
            $input = '<select name="editor_field_' . _h($field) . '"' . $required . '>' .
                $empty_option . $current_option . $option_html . '</select>';
        } elsif ($control eq 'checkbox') {
            $input = '<input type="checkbox" name="editor_field_' . _h($field) .
                '" value="1"' . ($value ? ' checked' : '') . '>';
        } else {
            $input = '<input type="' . _h($control) . '" name="editor_field_' .
                _h($field) . '" value="' . _h(_input_value($value, $control)) . '"' .
                $required . $placeholder . ($control eq 'number' ? ' step="any"' : '') . '>';
        }
        my $help = defined($spec->{help})
            ? '<small class="sc-record-editor-help">' . _h($spec->{help}) . '</small>' : '';
        my $html = '<label class="sc-record-editor-field' .
            ($spec->{readonly} ? ' is-readonly' : '') .
            '" data-sc-record-editor-field="' . _h($field) . '">' .
            '<span>' . _h($label) . $marker . '</span>' . $input .
            $help .
            '<small class="sc-record-editor-error" data-sc-record-editor-error hidden></small></label>'
        ;
        {section => $spec->{section} // '', html => $html};
    } @{$editor->{fields}};
    my $has_sections = grep { length($_->{section}) } @rendered;
    my $fields;
    if ($has_sections) {
        my (@sections, $current);
        for my $item (@rendered) {
            my $section = length($item->{section}) ? $item->{section} : 'Other';
            if (!$current || $current->{label} ne $section) {
                $current = {label => $section, fields => []};
                push @sections, $current;
            }
            push @{$current->{fields}}, $item->{html};
        }
        $fields = join '', map {
            '<section class="sc-record-editor-section"><h4>' . _h($_->{label}) .
            '</h4><div class="sc-record-editor-section-fields">' .
            join('', @{$_->{fields}}) . '</div></section>'
        } @sections;
    } else {
        $fields = join '', map { $_->{html} } @rendered;
    }
    my $description = defined($editor->{description})
        ? '<p class="sc-record-editor-description">' . _h($editor->{description}) . '</p>' : '';
    my $return_to = Selecto::Components::_safe_return_to(
        $context->{config}, scalar $controller->param('return_to'),
    );
    my $actions = _actions($controller, $context, $return_to);
    my $collections = _collections($context, $record);
    return '<form class="sc-record-editor-form" method="post" data-sc-record-editor-form action="' .
        _h($context->{config}->path . '/records/' . url_escape($context->{target}) .
            '/edit?editor=' . url_escape($editor->{id})) .
        '">' . $description . '<p class="sc-record-editor-identity"><strong>Record:</strong> ' .
        _h($context->{target}) . '</p><div class="sc-record-editor-fields">' . $fields . '</div>' .
        '<input type="hidden" name="csrf_token" value="' .
        _h(Selecto::Components::_csrf_token($controller)) . '">' .
        '<input type="hidden" name="return_to" value="' . _h($return_to) . '">' .
        '<input type="hidden" name="record_snapshot" value="' . _h($snapshot) . '">' .
        '<input type="hidden" name="record_signature" value="' . _h($signature) . '">' .
        $collections .
        '<div class="sc-record-editor-result" data-sc-record-editor-result role="status" hidden></div>' .
        '<footer><button type="button" class="sc-button sc-secondary" data-sc-row-dialog-close>Cancel</button>' .
        '<button type="submit" class="sc-button sc-primary" data-sc-record-editor-save disabled>' .
        _h($editor->{submit_label} // 'Save changes') . '</button></footer></form>' . $actions;
}

sub _collections ($context, $record) {
    my $rows_by_id = $record->{__selecto_editor_collections} // {};
    my $field_map = $context->{config}->field_map($context->{domain});
    return join '', map {
        my $collection = $_;
        my $rows = $rows_by_id->{$collection->{id}} // [];
        my $headers = join '', map {
            my $spec = $_;
            '<th scope="col">' . _h(
                $spec->{label} // $field_map->{$spec->{field}}{label} // $spec->{field},
            ) . '</th>'
        } @{$collection->{fields}};
        my $body = @$rows ? join('', map {
            my $row = $_;
            '<tr>' . join('', map {
                my $value = $row->{$_->{field}};
                '<td>' . _h(defined($value) && "$value" ne '' ? $value : '—') . '</td>'
            } @{$collection->{fields}}) . '</tr>'
        } @$rows) : '<tr><td colspan="' . scalar(@{$collection->{fields}}) .
            '" class="sc-record-editor-collection-empty">' .
            _h($collection->{empty_label} // 'No records.') . '</td></tr>';
        '<section class="sc-record-editor-collection" data-sc-record-editor-collection="' .
            _h($collection->{id}) . '"><h4>' . _h($collection->{label}) .
            '</h4><div class="sc-table-scroll"><table><thead><tr>' . $headers .
            '</tr></thead><tbody>' . $body . '</tbody></table></div></section>'
    } @{$context->{editor}{collections} // []};
}

sub _actions ($controller, $context, $return_to) {
    my (@buttons, @panels);
    for my $action_id (@{$context->{editor}{actions} // []}) {
        my $resolved = Selecto::Components::Actions->find(
            $context->{config}, $context->{domain}, $controller, $action_id,
            'preview', {ids => [$context->{target}]},
        );
        next unless $resolved && $resolved->{decision}{status} eq 'enabled';
        my $action = $resolved->{action};
        my $eligible;
        my $eligibility_ok = eval {
            $eligible = Selecto::Components::Actions->row_eligibility(
                $context->{config}, $controller, $action,
                [$context->{target}], 'display',
            );
            1;
        };
        unless ($eligibility_ok) {
            $controller->app->log->error(
                "Selecto record editor action $action_id eligibility failed: $@",
            );
            next;
        }
        next if defined($eligible) && !$eligible->{"$context->{target}"};
        my $inputs = join '', map {
            Selecto::Components::Renderer::Results::_action_input(
                $_, $action_id, 'record-editor',
            )
        } @{$action->{inputs} // []};
        my $description = length($action->{description} // '')
            ? '<p>' . _h($action->{description}) . '</p>' : '';
        my $panel_id = 'sc-record-editor-action-' . $action_id;
        push @buttons, '<button type="button" class="sc-button sc-secondary" ' .
            'data-sc-record-editor-action-open="' . _h($panel_id) . '" ' .
            'aria-controls="' . _h($panel_id) . '" aria-expanded="false">' .
            _h($action->{label}) . '</button>';
        push @panels, '<form class="sc-record-editor-action" method="post" hidden ' .
            'id="' . _h($panel_id) . '" data-sc-record-editor-action-panel ' .
            'data-sc-action-form ' .
            'data-sc-record-editor-action-form data-sc-record-id="' . _h($context->{target}) .
            '" data-sc-return-to="' . _h($return_to) . '" action="' .
            _h($context->{config}->path . '/actions/' . $action_id) . '"><header><div><h5>' .
            _h($action->{label}) . '</h5>' . $description . '</div>' .
            '<button type="button" class="sc-button sc-secondary" ' .
            'data-sc-record-editor-action-close>Back to actions</button></header>' .
            '<input type="hidden" name="csrf_token" value="' .
            _h(Selecto::Components::_csrf_token($controller)) . '">' .
            '<input type="hidden" name="return_to" value="' . _h($return_to) . '">' .
            '<input type="hidden" name="selected_id" value="' . _h($context->{target}) . '">' .
            '<fieldset><div class="sc-action-inputs">' .
            $inputs . '</div><button type="submit" class="sc-button sc-secondary">' .
            _h($action->{label}) . '</button></fieldset>' .
            '<div class="sc-action-result" data-sc-action-result role="status" hidden></div></form>';
    }
    return '' unless @buttons;
    return '<section class="sc-record-editor-actions"><header><h4>Operational actions</h4>' .
        '<p>Choose an action to open its form. Actions run separately from profile Save.</p></header>' .
        '<div class="sc-record-editor-action-buttons">' . join('', @buttons) . '</div>' .
        '<div class="sc-record-editor-action-panels">' . join('', @panels) . '</div></section>';
}

sub _input_value ($value, $control) {
    return '' unless defined $value;
    my $text = "$value";
    $text =~ s/ /T/ if $control eq 'datetime-local';
    $text =~ s/(?:Z|[+-]\d\d:?\d\d)\z// if $control eq 'datetime-local';
    return $text;
}

sub _select_empty_option ($spec, $has_display_value) {
    return '' unless $spec->{nullable} || !$has_display_value;
    my $empty_label = $spec->{nullable} ? '— None —'
        : $spec->{required} ? '— Select —' : '— Blank —';
    return '<option value=""' .
        (!$has_display_value ? ' selected' : '') .
        ($spec->{required} ? ' disabled' : '') . '>' .
        _h($empty_label) . '</option>';
}

sub _signature ($controller, $editor, $target, $snapshot) {
    my $secret = $controller->app->secrets->[0] // 'selecto-components';
    return hmac_sha256_hex(
        encode_utf8(join("\x1f", $editor, $target, $snapshot)),
        encode_utf8($secret),
    );
}

sub _error ($controller, $status, $message) {
    $controller->res->headers->cache_control('no-store');
    return $controller->render(
        text => '<div class="sc-record-editor-error-panel" role="alert">' .
            _h($message) . '</div>',
        format => 'html', status => $status,
    );
}

sub _h ($value) { return xml_escape(defined($value) ? "$value" : ''); }

1;
