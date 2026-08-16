package Selecto::Components::Renderer;

use Mojo::Base -base, -signatures;
use Mojo::Util qw(xml_escape);

sub page ($class, $model) {
    my $config = $model->{config};
    my $title = _h($config->title) . ' · Selecto Components Perl';
    my $surface = $class->surface($model);
    my $ws_path = _h($config->path . '/ws');
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">' .
        '<meta name="viewport" content="width=device-width,initial-scale=1">' .
        '<title>' . $title . '</title>' .
        '<link rel="stylesheet" href="/selecto-components/selecto-components.css">' .
        '<script defer src="/selecto-components/htmx.min.js"></script>' .
        '<script defer src="/selecto-components/hx-ws.min.js"></script>' .
        '<script defer src="/selecto-components/selecto-components.js"></script>' .
        '</head><body><main class="sc-page"><div class="sc-shell">' .
        '<header class="sc-masthead"><div><a class="sc-brand" href="' . _h($config->path) . '">SELECTO</a>' .
        '<span class="sc-product">Components · Perl</span></div>' .
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
    my $errors = join '', map { '<li>' . _h($_) . '</li>' } @{$state->errors};
    $errors .= '<li>' . _h($model->{runtime_error}) . '</li>' if $model->{runtime_error};
    my $alert = length($errors)
        ? '<div class="sc-alert" role="alert"><strong>Query stopped</strong><ul>' . $errors . '</ul></div>'
        : '';
    return '<section id="selecto-surface-' . _h($config->id) . '" class="sc-surface" data-selecto-url="' .
        _h($model->{canonical_url}) . '">' .
        '<header class="sc-hero"><div><p class="sc-eyebrow">Governed data explorer</p><h1>' .
        _h($config->title) . '</h1><p>Build the query in the URL. htmx WebSockets replace server-rendered fragments.</p></div>' .
        '<div class="sc-hero-actions"><a class="sc-button sc-secondary" href="' . _h($model->{canonical_url}) . '">Permalink</a>' .
        '<a class="sc-button sc-secondary" href="' . _h($model->{canonical_url} . '&format=csv') . '">Export CSV</a></div></header>' .
        $alert . '<div class="sc-workspace">' .
        $class->_form($model, $field_catalog) .
        '<section class="sc-results" aria-live="polite">' . $class->_results($model) . '</section>' .
        '</div></section>';
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

sub _form ($class, $model, $catalog) {
    my $config = $model->{config};
    my $state = $model->{state};
    my %selected_group = map { $_ => 1 } @{$state->groups};
    my $views = join '', map {
        '<label class="sc-view-tab"><input type="radio" name="view" value="' . _h($_) . '"' .
        ($_ eq $state->view ? ' checked' : '') . '><span>' . _h(_humanize($_)) . '</span></label>'
    } @{$config->views};
    my $groups = join '', map {
        '<label class="sc-check"><input type="checkbox" name="group" value="' . _h($_->{path}) . '"' .
        ($selected_group{$_->{path}} ? ' checked' : '') . '><span>' . _h($_->{label}) .
        '<small>' . _h($_->{type}) . '</small></span></label>'
    } @$catalog;
    my $measures = join '', map {
        '<option value="' . _h($_->{id}) . '"' . ($_->{id} eq $state->measure ? ' selected' : '') . '>' .
        _h($_->{label}) . '</option>'
    } @{$config->measures};
    my $orders = join '', map {
        '<option value="' . _h($_->{path}) . '"' . ($_->{path} eq $state->order ? ' selected' : '') . '>' .
        _h($_->{label}) . '</option>'
    } @$catalog;
    my $filter_picker = $class->_filter_picker($state, $catalog, $config->max_filters);
    my $view_controls = $state->view eq 'detail'
        ? $class->_field_picker($state, $catalog) .
          '<div class="sc-control-row"><label>Order by<select name="order">' . $orders . '</select></label>' .
          '<label>Direction<select name="direction"><option value="asc"' . ($state->direction eq 'asc' ? ' selected' : '') .
          '>Ascending</option><option value="desc"' . ($state->direction eq 'desc' ? ' selected' : '') . '>Descending</option></select></label></div>' .
          _hidden('measure', $state->measure) . join('', map { _hidden('group', $_) } @{$state->groups})
        : '<fieldset><legend>Group by <small>up to three</small></legend><div class="sc-check-grid">' . $groups . '</div></fieldset>' .
          '<label>Measure<select name="measure">' . $measures . '</select></label>' .
          _hidden('order', $state->order) . _hidden('direction', $state->direction) .
          join('', map { _hidden('field', $_) } @{$state->fields});
    return '<aside class="sc-builder"><form id="selecto-query-' . _h($config->id) . '" action="' .
        _h($config->path) . '" method="get" hx-ws:send hx-trigger="change delay:180ms, submit">' .
        _hidden('q', 1) . '<div class="sc-view-tabs" role="radiogroup" aria-label="Result view">' . $views . '</div>' .
        $view_controls . $filter_picker .
        '<div class="sc-control-row"><label>Rows<select name="limit">' . _limit_options($state, $config) . '</select></label>' .
        '<label>Page<input name="page" inputmode="numeric" value="' . _h($state->page) . '"></label></div>' .
        '<button class="sc-button sc-primary" type="submit">Run governed query</button>' .
        '<noscript><p class="sc-note">JavaScript is off; this form still runs as a normal GET.</p></noscript></form></aside>';
}

sub _field_picker ($class, $state, $catalog) {
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my %selected = map { $_ => 1 } @{$state->fields};
    my @available = grep { !$selected{$_->{path}} } @$catalog;
    my $available_items = join '', map {
        '<button class="sc-picker-choice" type="button" data-sc-picker-action="add" ' .
        'data-sc-picker-available-item data-field="' . _h($_->{path}) . '" data-search="' .
        _h(lc($_->{label} . ' ' . $_->{type})) . '"><span><strong>' . _h($_->{label}) .
        '</strong><small>' . _h($_->{type}) . '</small></span><span aria-hidden="true">+</span></button>'
    } @available;
    $available_items ||= '<p class="sc-picker-empty">Every available field is set.</p>';

    my $selected_count = scalar @{$state->fields};
    my $set_items = join '', map {
        my $index = $_;
        my $path = $state->fields->[$index];
        my $field = $by_path{$path};
        my $up_disabled = $index == 0 ? ' disabled' : '';
        my $down_disabled = $index == $selected_count - 1 ? ' disabled' : '';
        my $remove_disabled = $selected_count == 1 ? ' disabled' : '';
        '<article class="sc-picker-set-item" draggable="true" data-sc-picker-set-item data-field="' .
        _h($path) . '"><input type="hidden" name="field" value="' . _h($path) . '">' .
        '<button class="sc-picker-grip" type="button" title="Drag to reorder" aria-label="Drag ' .
        _h($field->{label}) . ' to reorder">⠿</button><span class="sc-picker-set-label"><strong>' .
        _h($field->{label}) . '</strong><small>' . _h($field->{type}) . '</small></span>' .
        '<span class="sc-picker-controls">' .
        '<button type="button" data-sc-picker-action="up" aria-label="Move ' . _h($field->{label}) .
        ' up" title="Move up"' . $up_disabled . '>↑</button>' .
        '<button type="button" data-sc-picker-action="down" aria-label="Move ' . _h($field->{label}) .
        ' down" title="Move down"' . $down_disabled . '>↓</button>' .
        '<button type="button" data-sc-picker-action="remove" aria-label="Remove ' . _h($field->{label}) .
        '" title="Remove"' . $remove_disabled . '>×</button></span></article>'
    } 0 .. $selected_count - 1;
    $set_items ||= '<p class="sc-picker-empty">Choose fields from Available to set the result columns.</p>';

    return '<fieldset class="sc-picker-fieldset"><legend>Columns</legend>' .
        '<div class="sc-list-picker" data-sc-picker-root>' .
        '<section class="sc-picker-pane"><div class="sc-picker-heading"><span>Available</span><span>' .
        scalar(@available) . '</span></div><input class="sc-picker-filter" type="search" ' .
        'data-sc-picker-filter placeholder="Filter available fields" aria-label="Filter available fields">' .
        '<div class="sc-picker-list" data-sc-picker-available>' . $available_items . '</div></section>' .
        '<section class="sc-picker-pane sc-picker-set-pane"><div class="sc-picker-heading"><span>Set</span><span>' .
        $selected_count . '</span></div><p class="sc-picker-hint">Drag or use arrows to reorder columns.</p>' .
        '<div class="sc-picker-list sc-picker-set" data-sc-picker-set aria-label="Set columns">' .
        $set_items . '</div></section></div></fieldset>';
}

sub _filter_picker ($class, $state, $catalog, $max_filters) {
    my %by_path = map { $_->{path} => $_ } @$catalog;
    my %selected = map { $_->{field} => 1 } @{$state->filters};
    my @available = grep { !$selected{$_->{path}} } @$catalog;
    my $at_limit = @{$state->filters} >= $max_filters;
    my $available_items = $at_limit ? '' : join '', map {
        '<button class="sc-picker-choice" type="button" data-sc-filter-action="add" ' .
        'data-sc-filter-available-item data-field="' . _h($_->{path}) . '" data-search="' .
        _h(lc($_->{label} . ' ' . $_->{type})) . '"><span><strong>' . _h($_->{label}) .
        '</strong><small>' . _h($_->{type}) . '</small></span><span aria-hidden="true">+</span></button>'
    } @available;
    $available_items ||= '<p class="sc-picker-empty">' .
        ($at_limit ? 'Maximum of ' . _h($max_filters) . ' filters set.' : 'Every available filter is set.') .
        '</p>';

    my @operators = (
        [eq => 'equals'], [gte => 'at least'], [gt => 'greater than'],
        [in => 'one of (comma-separated)'], [is_null => 'is empty'], [not_null => 'is not empty'],
    );
    my $set_items = join '', map {
        my $filter = $_;
        my $field = $by_path{$filter->{field}};
        my $ops = join '', map {
            '<option value="' . $_->[0] . '"' . ($_->[0] eq $filter->{op} ? ' selected' : '') . '>' .
            _h($_->[1]) . '</option>'
        } @operators;
        my $null_op = $filter->{op} =~ /_null\z/;
        '<article class="sc-filter-set-item' . ($filter->{draft} ? ' is-draft' : '') .
        '" data-sc-filter-set-item data-field="' . _h($filter->{field}) . '">' .
        '<input type="hidden" name="filter_field" value="' . _h($filter->{field}) . '">' .
        '<div class="sc-filter-set-heading"><span><strong>' . _h($field->{label}) . '</strong><small>' .
        _h($field->{type}) . '</small></span><button type="button" data-sc-filter-action="remove" ' .
        'aria-label="Remove ' . _h($field->{label}) . ' filter" title="Remove filter">×</button></div>' .
        '<div class="sc-filter-editor"><label>Operator<select name="filter_op" aria-label="Operator for ' .
        _h($field->{label}) . '">' . $ops . '</select></label><label>Value<input name="filter_value" ' .
        'aria-label="Value for ' . _h($field->{label}) . '" value="' . _h($filter->{value}) . '" ' .
        ($null_op ? 'readonly placeholder="Value not used"' : 'placeholder="Enter a value"') . '></label></div>' .
        ($filter->{draft} ? '<p class="sc-filter-draft-note">Enter a value to apply this filter.</p>' : '') .
        '</article>'
    } @{$state->filters};
    $set_items ||= '<p class="sc-picker-empty">Choose fields from Available to build filters.</p>';

    return '<fieldset class="sc-picker-fieldset"><legend>Filters <small>up to ' . _h($max_filters) .
        '</small></legend><div class="sc-list-picker sc-filter-picker" data-sc-filter-root>' .
        '<section class="sc-picker-pane"><div class="sc-picker-heading"><span>Available</span><span>' .
        ($at_limit ? 0 : scalar(@available)) . '</span></div><input class="sc-picker-filter" type="search" ' .
        'data-sc-filter-search placeholder="Filter available filters" aria-label="Filter available filters">' .
        '<div class="sc-picker-list" data-sc-filter-available>' . $available_items . '</div></section>' .
        '<section class="sc-picker-pane sc-picker-set-pane"><div class="sc-picker-heading"><span>Set</span><span>' .
        scalar(@{$state->filters}) . '</span></div><p class="sc-picker-hint">Set filters are combined with AND.</p>' .
        '<div class="sc-picker-list sc-filter-set" data-sc-filter-set aria-label="Set filters">' .
        $set_items . '</div></section></div></fieldset>';
}

sub _results ($class, $model) {
    return '<div class="sc-empty"><h2>Query unavailable</h2><p>Correct the controls and try again.</p></div>'
        unless $model->{state}->valid && $model->{result};
    my $result = $model->{result};
    my $heading = $model->{state}->view eq 'detail' ? 'Detail results'
        : $model->{state}->view eq 'aggregate' ? 'Aggregate results' : 'Graph results';
    my $meta = '<div class="sc-result-meta"><div><p class="sc-eyebrow">' . _h($result->{adapter_name}) .
        ' adapter</p><h2>' . _h($heading) . '</h2></div><div><strong>' . _h($result->{count}) .
        '</strong> rows · <strong>' . _h($result->{elapsed_ms}) . '</strong> ms</div></div>';
    my $body = $result->{graph} ? $class->_graph($result) : $class->_table($result);
    my $pagination = $class->_pagination($model);
    my $debug = '';
    if ($model->{config}->show_sql && defined $result->{sql}) {
        $debug = '<details class="sc-debug"><summary>Compiled SQL and bound parameters</summary><pre>' .
            _h($result->{sql}) . "\n\n" . _h(join("\n", map { defined($_) ? "$_" : 'NULL' } @{$result->{params}})) .
            '</pre></details>';
    }
    return $meta . $body . $pagination . $debug;
}

sub _table ($class, $result) {
    my $head = join '', map { '<th scope="col">' . _h($_->{label}) . '</th>' } @{$result->{columns}};
    my $rows = join '', map {
        my $record = $_;
        '<tr>' . join('', map { '<td>' . _h(_display($record->{$_->{key}})) . '</td>' } @{$result->{columns}}) . '</tr>'
    } @{$result->{records}};
    $rows ||= '<tr><td class="sc-empty-cell" colspan="' . scalar(@{$result->{columns}}) . '">No rows matched this query.</td></tr>';
    return '<div class="sc-table-wrap"><table><thead><tr>' . $head . '</tr></thead><tbody>' . $rows . '</tbody></table></div>';
}

sub _graph ($class, $result) {
    my $measure = $result->{columns}[-1];
    my @values = map { _number($_->{$measure->{key}}) } @{$result->{records}};
    my $max = 0;
    for my $value (@values) {
        $max = $value if $value > $max;
    }
    $max = 1 unless $max > 0;
    my @dimensions = @{$result->{columns}}[0 .. $#{$result->{columns}} - 1];
    my $bars = join '', map {
        my $index = $_;
        my $record = $result->{records}[$index];
        my $label = join(' · ', map { _display($record->{$_->{key}}) } @dimensions);
        '<li><span class="sc-graph-label">' . _h($label) . '</span><meter min="0" max="' .
        _h($max) . '" value="' . _h($values[$index]) . '"></meter><strong>' .
        _h(_display($record->{$measure->{key}})) . '</strong></li>'
    } 0 .. $#{$result->{records}};
    $bars ||= '<li class="sc-empty-cell">No rows matched this query.</li>';
    return '<div class="sc-chart" role="img" aria-label="' . _h($measure->{label}) .
        ' by selected groups"><ul>' . $bars . '</ul></div>' . $class->_table($result);
}

sub _pagination ($class, $model) {
    my $state = $model->{state};
    my @buttons;
    if ($state->page > 1) {
        push @buttons, '<button class="sc-button sc-secondary" type="submit" name="page" value="' .
            _h($state->page - 1) . '">Previous</button>';
    }
    if ($model->{result}{has_more}) {
        push @buttons, '<button class="sc-button sc-secondary" type="submit" name="page" value="' .
            _h($state->page + 1) . '">Next</button>';
    }
    my $hidden = '';
    my $pairs = $state->query_pairs;
    for (my $index = 0; $index < @$pairs; $index += 2) {
        next if $pairs->[$index] eq 'page';
        $hidden .= _hidden($pairs->[$index], $pairs->[$index + 1]);
    }
    my $controls = @buttons
        ? '<form action="' . _h($model->{config}->path) . '" method="get" hx-ws:send>' .
          $hidden . join('', @buttons) . '</form>'
        : '<span></span>';
    return '<nav class="sc-pagination" aria-label="Results pages"><span>Page ' . _h($state->page) .
        '</span>' . $controls . '</nav>';
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

sub _number ($value) {
    return 0 unless defined($value) && !ref($value) && "$value" =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return 0 + $value;
}

sub _display ($value) { return defined($value) ? "$value" : '—'; }
sub _humanize ($value) { my $text = "$value"; $text =~ s/_/ /g; return ucfirst $text; }
sub _h ($value) { return xml_escape(defined($value) ? "$value" : ''); }

1;
