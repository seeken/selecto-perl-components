package Selecto::Components::CannedPage;

use utf8;
use Mojo::Base -base, -signatures;
use Mojo::Util qw(xml_escape);
use Mojo::JSON qw(decode_json encode_json);
use Encode qw(encode);
use Scalar::Util qw(blessed);
use Selecto::CannedPage ();
use Selecto::Error ();
use Selecto::Components::Renderer ();
use Selecto::Components::Renderer::Results ();
use Selecto::Components::AssetManifest qw(asset_revision);
use Selecto::Components::Config ();
use Selecto::Components::Util qw(humanize);

has [qw(page engine_factory scope_factory path title record_link websocket_enabled column_layout)];

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    die "canned page must be a Selecto::CannedPage\n"
        unless blessed($self->page) && $self->page->isa('Selecto::CannedPage');
    die "canned page needs an engine_factory\n" unless ref($self->engine_factory) eq 'CODE';
    die "canned page scope_factory must be a coderef\n"
        if defined($self->scope_factory) && ref($self->scope_factory) ne 'CODE';
    die "canned page path is invalid\n"
        unless defined($self->path) && $self->path =~ m{\A/(?!/)[A-Za-z0-9/_-]+\z};
    if (my $link = $self->record_link) {
        die "canned page record_link must contain a selected field and local URL prefix\n"
            unless ref($link) eq 'HASH'
                && !(grep { $_ ne 'field' && $_ ne 'url_prefix' && $_ ne 'target'
                    && $_ ne 'modal_title' } keys %$link)
                && defined($link->{field}) && !ref($link->{field})
                && $link->{field} =~ /\A[A-Za-z][A-Za-z0-9_.]*\z/
                && defined($link->{url_prefix}) && !ref($link->{url_prefix})
                && $link->{url_prefix} =~ m{\A/(?!/)[A-Za-z0-9/_-]+(?:\.[A-Za-z0-9]+)?(?:\?[A-Za-z0-9_=&%-]*)?\z}
                && (!defined($link->{target}) || $link->{target} =~ /\A_(?:self|parent|top)\z/)
                && (!defined($link->{modal_title}) || (!ref($link->{modal_title})
                    && length($link->{modal_title}) && !defined($link->{target})));
        for my $view (@{$self->page->views}) {
            next unless $view->{kind} eq 'detail';
            die "canned page record_link field must be selected by every detail view\n"
                unless grep { $_->kind eq 'field' && $_->arguments->[0] eq $link->{field} }
                    @{$view->{query}->selections};
        }
    }
    $self->_validate_column_layout if $self->column_layout;
    return $self;
}

sub _validate_column_layout ($self) {
    my $layout = $self->column_layout;
    die "canned page column_layout must be a nonempty array\n"
        unless ref($layout) eq 'ARRAY' && @$layout;
    if (my $link = $self->record_link) {
        die "canned page column_layout must display the record link field\n"
            unless grep { ref($_) eq 'HASH' && ($_->{kind} // '') eq 'field'
                && ($_->{field} // '') eq $link->{field} } @$layout;
    }
    for my $view (grep { $_->{kind} eq 'detail' } @{$self->page->views}) {
        my %fields = map { $_->arguments->[0] => 1 }
            grep { $_->kind eq 'field' } @{$view->{query}->selections};
        my %collections = map {
            my $selection = $_;
            $selection->alias_name => {map { $_ => 1 } @{$selection->arguments->[1]}}
        }
            grep { $_->kind eq 'related_collection' } @{$view->{query}->selections};
        for my $column (@$layout) {
            die "canned page column_layout entries must be objects\n"
                unless ref($column) eq 'HASH';
            my $kind = $column->{kind} // '';
            die "canned page column_layout kind is invalid\n"
                unless $kind =~ /\A(?:field|link|collection_link|join|nested|collection_values|row_number)\z/;
            die "canned page column_layout label is invalid\n"
                unless defined($column->{label}) && !ref($column->{label})
                    && length($column->{label});
            if ($kind eq 'field') {
                die "canned page column_layout field is not selected\n"
                    unless $fields{$column->{field} // ''};
            } elsif ($kind eq 'link' || $kind eq 'collection_link') {
                die "canned page link must use a selected field, local URL, and text\n"
                    unless $fields{$column->{field} // ''}
                        && ($kind ne 'collection_link'
                            || $collections{$column->{collection} // ''})
                        && defined($column->{url_prefix}) && !ref($column->{url_prefix})
                        && $column->{url_prefix} =~ m{\A/(?!/)[A-Za-z0-9_/-]*/\z}
                        && defined($column->{text}) && !ref($column->{text})
                        && length($column->{text})
                        && (!defined($column->{target})
                            || $column->{target} =~ /\A_(?:self|parent|top)\z/);
            } elsif ($kind eq 'join') {
                die "canned page column_layout join fields are not selected\n"
                    unless ref($column->{fields}) eq 'ARRAY' && @{$column->{fields}}
                        && !grep { !$fields{$_} } @{$column->{fields}};
                die "canned page column_layout join separator is invalid\n"
                    if defined($column->{separator}) && ref($column->{separator});
            } elsif ($kind eq 'nested' || $kind eq 'collection_values') {
                my $available = $collections{$column->{collection} // ''};
                die "canned page column_layout collection is not selected\n"
                    unless $available;
                if ($kind eq 'nested') {
                    die "canned page column_layout nested fields are invalid\n"
                        unless ref($column->{fields}) eq 'ARRAY' && @{$column->{fields}}
                            && !grep { ref($_) ne 'HASH'
                                || !$available->{$_->{field} // ''}
                                || !defined($_->{label}) || ref($_->{label}) } @{$column->{fields}};
                    for my $nested_field (@{$column->{fields}}) {
                        next unless exists $nested_field->{link};
                        my $link = $nested_field->{link};
                        die "canned page nested link must use a local URL prefix\n"
                            unless ref($link) eq 'HASH'
                                && !grep({ $_ ne 'url_prefix' && $_ ne 'text'
                                    && $_ ne 'parent_field' } keys %$link)
                                && defined($link->{url_prefix})
                                && !ref($link->{url_prefix})
                                && $link->{url_prefix} =~ m{\A/(?!/)[A-Za-z0-9_/-]*/\z}
                                && (!exists($link->{text})
                                    || (defined($link->{text}) && !ref($link->{text})
                                        && length($link->{text})))
                                && (!exists($link->{parent_field})
                                    || (defined($link->{parent_field})
                                        && !ref($link->{parent_field})
                                        && $fields{$link->{parent_field}}));
                    }
                } else {
                    die "canned page column_layout collection field is not selected\n"
                        unless $available->{$column->{field} // ''};
                }
            }
        }
    }
}

sub handle ($self, $controller) {
    my $domain = $self->page->domain;
    my $public = ($domain->components->{query_params} // 1) ? 1 : 0;
    $controller->res->headers->cache_control('no-store') unless $public;
    if (!$public && $controller->req->method eq 'GET'
        && length($controller->req->url->query->to_string)) {
        return $controller->redirect_to($self->path);
    }
    my ($result, $error);
    eval {
        my $engine = $self->engine_factory->($controller);
        my $scope = $self->scope_factory
            ? $self->scope_factory->($controller, $engine) : undef;
        $result = $self->page->run($engine, $self->_input($controller), $scope);
        1;
    } or $error = $@ || 'Canned page execution failed';
    if ($error) {
        $controller->app->log->error("Selecto canned page failed: $error");
        my $invalid = blessed($error) && $error->can('code')
            && $error->code eq 'invalid_canned_page';
        return $controller->render(
            text => $invalid ? 'Invalid page selection' : 'Page data is unavailable',
            status => $invalid ? 422 : 500,
        );
    }
    return $controller->render(data => encode('UTF-8', $self->_html($result, $public)),
        format => 'html', status => 200);
}

sub handle_websocket ($self, $controller) {
    $controller->on(message => sub ($socket, $message) {
        return $socket->finish(1009 => 'WebSocket message is too large')
            if !defined($message) || length($message) > 131_072;
        my $payload = eval { decode_json($message) };
        return $socket->finish(1003 => 'Expected a JSON form')
            unless ref($payload) eq 'HASH';
        my $request_id = $payload->{selecto_request_id};
        return $socket->finish(1003 => 'Invalid request id')
            unless defined($request_id) && !ref($request_id)
                && "$request_id" =~ /\A[0-9]{1,12}\z/;
        my $result;
        my $ok = eval {
            my $engine = $self->engine_factory->($socket);
            my $scope = $self->scope_factory
                ? $self->scope_factory->($socket, $engine) : undef;
            $result = $self->page->run($engine, $self->_input($socket, $payload), $scope);
            1;
        };
        unless ($ok) {
            $socket->app->log->error("Selecto canned page WebSocket failed: $@");
            my $invalid = blessed($@) && $@->can('code')
                && $@->code eq 'invalid_canned_page';
            my $code = $invalid ? 1003 : 1011;
            my $reason = $invalid ? 'Invalid page selection'
                : 'Page request could not be completed';
            return $socket->finish($code => $reason);
        }
        my $public = ($self->page->domain->components->{query_params} // 1) ? 1 : 0;
        return $socket->send({text => encode_json({
            content => $self->_surface($result, $public),
            target => '#selecto-page-' . $self->page->id,
            swap => 'outerHTML',
            selecto => {request_id => "$request_id"},
        })});
    });
}

sub _input ($self, $controller, $payload = undef) {
    my $get = sub ($name) {
        return defined($payload) ? $payload->{$name} : $controller->param($name);
    };
    my $submitted = defined($get->('submitted'));
    return {} unless $submitted;
    my (%filters, %facet_search);
    for my $control (@{$self->page->controls}) {
        my $id = $control->{id};
        if ($control->{kind} eq 'facet') {
            my $values = defined($payload) ? $payload->{"f_$id"}
                : $controller->every_param("f_$id");
            $filters{$id} = !defined($values) ? []
                : ref($values) eq 'ARRAY' ? [@$values] : [$values];
            if ($control->{values}{searchable}) {
                $facet_search{$id} = $get->("facet_search_$id") // '';
            }
        } elsif ($control->{kind} eq 'range') {
            my %range;
            for my $bound (qw(min max)) {
                my $value = $get->("f_${id}_$bound");
                $range{$bound} = $value if defined($value) && length($value);
            }
            $filters{$id} = \%range;
        } else {
            $filters{$id} = $get->("f_$id") // '';
        }
    }
    my $drilldown;
    my $clicked = defined($get->('drilldown_select'));
    my $drilldown_json = $clicked ? $get->('drilldown_select') : $get->('drilldown');
    if (!$get->('clear_drilldown') && defined($drilldown_json)
        && length($drilldown_json)) {
        $drilldown = eval { decode_json($drilldown_json) };
        Selecto::Error->throw('invalid_canned_page', 'invalid drilldown')
            unless ref($drilldown) eq 'HASH';
    }
    my ($detail) = grep { $_->{kind} eq 'detail' } @{$self->page->views};
    return {
        view => $clicked && $detail ? $detail->{id} : $get->('view'),
        page => $clicked ? 1 : $get->('page') // 1,
        limit => $get->('limit') // 25,
        filters => \%filters,
        facet_search => \%facet_search,
        (defined($drilldown) ? (drilldown => $drilldown) : ()),
    };
}

sub _html ($self, $result, $public) {
    my $title = _escape($self->title // $self->page->id);
    return Selecto::Components::Renderer->page_document(
        title => $title, channel_id => 'selecto-page-channel-' . $self->page->id,
        (($self->websocket_enabled // 1) ? (ws_path => $self->path . '/ws') : ()),
        surface => $self->_surface($result, $public),
        include_explorer_script => 0,
        extra_head_html => '<link rel="stylesheet" href="/selecto-components/canned-page.css?v=' .
            asset_revision() . '">' .
            '<script defer src="/selecto-components/canned-page.js?v=' .
            asset_revision() . '"></script>',
    );
}

sub _surface ($self, $result, $public) {
    my $state = $result->{state};
    my $title = _escape($self->title // $self->page->id);
    my $path = _escape($self->path);
    my $id = _escape($self->page->id);
    my $method = $public ? 'get' : 'post';
    my $ws_send = ($self->websocket_enabled // 1) ? ' hx-ws:send' : '';
    my $html = qq{<section id="selecto-page-$id" class="sc-surface selecto-canned-page">};
    $html .= qq{<header class="sc-hero"><div class="sc-hero-heading"><h1>$title</h1></div>};
    $html .= $public ? qq{<div class="sc-hero-actions"><a class="sc-button sc-secondary" href="$path">Reset</a></div>}
        : '<div class="sc-hero-actions"><span class="sc-private-mode">Private URL mode</span></div>';
    $html .= '</header><div class="sc-workspace">';
    $html .= qq{<aside class="sc-builder selecto-canned-controls"><form method="$method" action="$path"$ws_send><input type="hidden" name="submitted" value="1">};
    $html .= '<input type="hidden" name="limit" value="' . _escape($state->{limit}) . '">';
    if ($state->{drilldown}) {
        $html .= '<input type="hidden" name="drilldown" value="'
            . _escape(encode_json($state->{drilldown})) . '">';
        $html .= '<p class="sc-note">Showing matching detail rows from ' . _escape($state->{drilldown}{view})
            . '.</p><button class="sc-button sc-secondary" type="submit" name="clear_drilldown" value="1">Clear drilldown</button>';
    }
    $html .= '<p class="sc-eyebrow">Views and filters</p>';
    $html .= '<label for="selecto-page-view">View</label><select id="selecto-page-view" name="view">';
    for my $view (@{$self->page->views}) {
        my $selected = $view->{id} eq $state->{view} ? ' selected' : '';
        $html .= '<option value="' . _escape($view->{id}) . '"' . $selected . '>'
            . _escape($view->{label} // $view->{id}) . '</option>';
    }
    $html .= '</select>';
    for my $control (@{$self->page->controls}) {
        my $id = $control->{id};
        my $name = _escape("f_$id");
        my $label = _escape($control->{label} // $id);
        my $value = $state->{filters}{$id};
        if ($control->{kind} eq 'facet') {
            $html .= '<fieldset><legend>' . $label . '</legend>';
            if ($control->{values}{searchable}) {
                $html .= '<label>Find ' . $label . ' options <input type="search" name="'
                    . _escape("facet_search_$id") . '" value="'
                    . _escape($state->{facet_search}{$id} // '') . '"></label>';
            }
            my %selected = map { $_ => 1 } @{$value // []};
            for my $option (@{$result->{facets}{$id}{options}}) {
                my $raw = defined($option->{value}) ? "$option->{value}" : '';
                my $checked = $selected{$raw} ? ' checked' : '';
                my $caption = defined($option->{label}) ? $option->{label} : '(missing)';
                $html .= '<label><input type="checkbox" name="' . $name
                    . '" value="' . _escape($raw) . '"' . $checked . '>'
                    . _escape($caption) . ' <span>(' . _escape($option->{count})
                    . ')</span></label> ';
            }
            $html .= '<p>More values are available.</p>' if $result->{facets}{$id}{truncated};
            $html .= '</fieldset>';
        } elsif ($control->{kind} eq 'range') {
            $html .= '<fieldset><legend>' . $label . '</legend>';
            for my $bound (qw(min max)) {
                $html .= '<label>' . ucfirst($bound) . ' <input type="number" name="'
                    . _escape("f_${id}_$bound") . '" value="'
                    . _escape($value->{$bound} // '') . '"></label> ';
            }
            $html .= '</fieldset>';
        } else {
            $html .= '<label>' . $label . ' <input type="search" name="' . $name
                . '" value="' . _escape($value // '') . '"></label>';
        }
    }
    $html .= '<div class="selecto-canned-actions"><button class="sc-button sc-primary" type="submit" name="page" value="1">Apply filters</button> ';
    $html .= '<a class="sc-button sc-secondary" href="' . $path . '">Reset</a></div>';
    $html .= '</form></aside><section class="sc-results selecto-canned-results" aria-label="Search results">';
    my $total = $result->{total} // 0;
    my $total_pages = int(($total + $state->{limit} - 1) / $state->{limit}) || 1;
    my $row_label = $total == 1 ? 'row matched' : 'rows matched';
    my $page_label = $total_pages == 1 ? 'page' : 'pages';
    my $query_time = defined($result->{elapsed_ms})
        ? ' · <strong>' . _escape($result->{elapsed_ms}) . ' ms</strong> query time' : '';
    $html .= '<div class="sc-result-meta"><div><h2>' .
        _escape(Selecto::Components::Renderer::Results->heading_for_view($result->{view}{kind})) .
        '</h2></div><div><strong>' . _escape($total) . '</strong> ' . $row_label .
        ' · <strong>' . _escape($total_pages) . '</strong> ' . $page_label .
        $query_time . '</div></div>';
    $html .= $self->_pagination($state, $total_pages, $public, 'top');
    $html .= qq{<form method="$method" action="$path"$ws_send>} . $self->_hidden_state($state);
    $html .= $self->_table($result);
    $html .= '</form>';
    $html .= $self->_pagination($state, $total_pages, $public, 'bottom');
    return $html . '</section></div></section>';
}

sub _pagination ($self, $state, $total_pages, $public, $position) {
    my $method = $public ? 'get' : 'post';
    my $ws_send = ($self->websocket_enabled // 1) ? ' hx-ws:send' : '';
    my $controls = $total_pages > 1
        ? '<form method="' . $method . '" action="' . _escape($self->path) . '"' .
            $ws_send . '>' . $self->_hidden_state($state) .
            Selecto::Components::Renderer::Results->pagination_buttons(
                $state->{page}, $total_pages) . '</form>'
        : '<span></span>';
    return '<nav class="sc-pagination sc-pagination-' . _escape($position) .
        '" data-sc-pagination-position="' . _escape($position) .
        '" aria-label="Results pages, ' . _escape($position) . '"><span>Page ' .
        _escape($state->{page}) . ' of ' . _escape($total_pages) .
        '<span class="sc-pagination-status" data-sc-pagination-status role="status" ' .
        'aria-live="polite" hidden></span></span>' . $controls . '</nav>';
}

sub _hidden_state ($self, $state) {
    my $html = '<input type="hidden" name="submitted" value="1"><input type="hidden" name="view" value="' .
        _escape($state->{view}) . '"><input type="hidden" name="limit" value="' .
        _escape($state->{limit}) . '">';
    for my $control (@{$self->page->controls}) {
        my $value = $state->{filters}{$control->{id}};
        my $name = 'f_' . $control->{id};
        if ($control->{kind} eq 'facet') {
            $html .= '<input type="hidden" name="' . _escape($name) . '" value="' . _escape($_) . '">'
                for @{$value // []};
            $html .= '<input type="hidden" name="facet_search_' . _escape($control->{id}) .
                '" value="' . _escape($state->{facet_search}{$control->{id}} // '') . '">'
                if $control->{values}{searchable};
        } elsif ($control->{kind} eq 'range') {
            for my $bound (qw(min max)) {
                $html .= '<input type="hidden" name="' . _escape("${name}_$bound") .
                    '" value="' . _escape($value->{$bound}) . '">'
                    if defined($value->{$bound});
            }
        } else {
            $html .= '<input type="hidden" name="' . _escape($name) . '" value="' .
                _escape($value // '') . '">';
        }
    }
    $html .= '<input type="hidden" name="drilldown" value="' . _escape(encode_json($state->{drilldown})) . '">'
        if $state->{drilldown};
    return $html;
}

sub _table ($self, $result) {
    my ($view) = grep { $_->{id} eq $result->{state}{view} } @{$self->page->views};
    my $label_config = Selecto::Components::Config->new(
        id => $self->page->id, title => $self->title // $self->page->id,
        path => $self->path, engine_factory => $self->engine_factory,
    );
    my $field_labels = $label_config->field_map($self->page->domain);
    my $selections = $view->{query}->selections;
    my @columns = map {
        my $selection = $selections->[$_];
        my $path = $selection && $selection->kind eq 'field'
            ? $selection->arguments->[0] : undef;
        my $label = defined($path) && $field_labels->{$path}
            ? $field_labels->{$path}{label}
            : humanize($selection && $selection->alias_name
                ? $selection->alias_name : $result->{columns}[$_]);
        my $nested = $selection && $selection->kind eq 'related_collection';
        my ($association, $fields) = $nested ? @{$selection->arguments} : ();
        +{key => "column_$_", field => $path, label => $label,
            ($nested ? (collection => $selection->alias_name) : ()),
            ($nested ? (nested => 1, association => $association,
                nested_fields => [map {
                    +{field => $_, label => humanize($_)}
                } @$fields]) : ()),
            measure => $view->{kind} eq 'aggregate' && $_ >= @{$view->{query}->groups} ? 1 : 0}
    } 0 .. $#{$result->{columns}};
    my @records = map {
        my %record;
        @record{map { "column_$_" } 0 .. $#{$_}} = @{$_};
        \%record;
    } @{$result->{rows}};
    for my $record (@records) {
        for my $column (grep { $_->{nested} } @columns) {
            my $value = $record->{$column->{key}};
            if (defined($value) && !ref($value)) {
                $value = eval { decode_json($value) };
            }
            my $valid_collection = ref($value) eq 'ARRAY'
                && !(grep { ref($_) ne 'HASH' } @$value);
            $record->{$column->{key}} = $valid_collection ? $value : [];
        }
    }
    if ($self->column_layout && $view->{kind} eq 'detail') {
        my ($columns, $records) = $self->_layout_table(\@columns, \@records,
            $result->{state});
        @columns = @$columns;
        @records = @$records;
    }
    my $table = {columns => \@columns, records => \@records,
        detail => $view->{kind} eq 'detail' ? 1 : 0};
    if ($view->{kind} eq 'aggregate') {
        my $group_count = @{$view->{query}->groups};
        $table->{extra_column} = {label => 'Details', cell => sub ($record, $index) {
            my @values = map { $record->{"column_$_"} } 0 .. $group_count - 1;
            return '<button class="sc-button sc-secondary" type="submit" name="drilldown_select" value="' .
                _escape(encode_json({view => $result->{state}{view}, values => \@values})) .
                '">Show matching items</button>';
        }};
    } elsif (my $link = $self->record_link) {
        my ($column) = grep { ($_->{field} // '') eq $link->{field} } @columns;
        $column->{link} = {
            url_template => $link->{url_prefix} . '{{id}}',
            target => $link->{target}, numeric_id => 1,
            (defined($link->{modal_title})
                ? (modal_title => $link->{modal_title}) : ()),
        };
        $column->{link_key} = $column->{key};
    }
    return Selecto::Components::Renderer::Results->_table($table, {bulk_actions => []});
}

sub _layout_table ($self, $source_columns, $source_records, $state) {
    my %field = map { defined($_->{field}) ? ($_->{field} => $_) : () }
        @$source_columns;
    my %collection = map { defined($_->{collection}) ? ($_->{collection} => $_) : () }
        @$source_columns;
    my (@columns, @records);
    for my $index (0 .. $#$source_records) {
        my $source = $source_records->[$index];
        my %record;
        for my $position (0 .. $#{$self->column_layout}) {
            my $spec = $self->column_layout->[$position];
            my $key = "display_$position";
            my $kind = $spec->{kind};
            if ($kind eq 'row_number') {
                $record{$key} = ($state->{page} - 1) * $state->{limit} + $index + 1;
                push @columns, {key => $key, label => $spec->{label}}
                    if $index == 0;
            } elsif ($kind eq 'field') {
                my $column = $field{$spec->{field}};
                $record{$key} = $source->{$column->{key}};
                push @columns, {%$column, key => $key, label => $spec->{label}}
                    if $index == 0;
            } elsif ($kind eq 'link' || $kind eq 'collection_link') {
                my $column = $field{$spec->{field}};
                my $enabled = $kind eq 'link'
                    || @{$source->{$collection{$spec->{collection}}{key}} // []};
                $record{$key} = $enabled ? $spec->{text} : '';
                $record{$key . '_id'} = $enabled
                    ? $source->{$column->{key}} : undef;
                push @columns, {key => $key, label => $spec->{label},
                    link => {url_template => $spec->{url_prefix} . '{{id}}',
                        numeric_id => 1, target => $spec->{target} // '_top'},
                    link_key => $key . '_id'} if $index == 0;
            } elsif ($kind eq 'join') {
                $record{$key} = join($spec->{separator} // ' ',
                    grep { defined($_) && !ref($_) && length("$_") }
                    map { $source->{$field{$_}{key}} } @{$spec->{fields}});
                push @columns, {key => $key, label => $spec->{label}}
                    if $index == 0;
            } else {
                my $column = $collection{$spec->{collection}};
                my $items = $source->{$column->{key}} // [];
                if ($kind eq 'nested') {
                    my @parent_fields = map { $_->{link}{parent_field} }
                        grep { ref($_->{link}) eq 'HASH'
                            && defined($_->{link}{parent_field}) } @{$spec->{fields}};
                    $record{$key} = @parent_fields
                        ? [map {
                            my %item = %$_;
                            $item{'__selecto_parent_' . $_} =
                                $source->{$field{$_}{key}} for @parent_fields;
                            \%item;
                        } @$items]
                        : $items;
                    push @columns, {key => $key, label => $spec->{label},
                        nested => 1, nested_fields => $spec->{fields}}
                        if $index == 0;
                } else {
                    $record{$key} = join(', ', grep { defined($_) && !ref($_) && length("$_") }
                        map { ref($_) eq 'HASH' ? $_->{$spec->{field}} : undef } @$items);
                    push @columns, {key => $key, label => $spec->{label}}
                        if $index == 0;
                }
            }
        }
        push @records, \%record;
    }
    if (!@$source_records) {
        # Even an empty result retains the authored table headers.
        for my $position (0 .. $#{$self->column_layout}) {
            my $spec = $self->column_layout->[$position];
            my $column = $spec->{kind} eq 'field' ? $field{$spec->{field}} : {};
            push @columns, {%$column, key => "display_$position",
                label => $spec->{label},
                ($spec->{kind} eq 'nested'
                    ? (nested => 1, nested_fields => $spec->{fields}) : ())};
        }
    }
    return (\@columns, \@records);
}

sub _escape ($value) { xml_escape(defined($value) ? "$value" : '') }

1;
