package Selecto::Components::Renderer::Debug;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Selecto::Components::Renderer::Markup;

sub _debug_panel ($class, $result, $model) {
    return '' unless $model->{config}->show_sql && ref($result->{debug}) eq 'HASH';
    my $debug = $result->{debug};
    my $stats = $debug->{stats} // {};
    my @cards = (
        ['Total query time', _debug_ms($stats->{total_ms})],
        ['Data execution', _debug_ms($stats->{data_query_ms})],
        ['Count execution', $stats->{count_cache_hit}
            ? 'cached' : _debug_ms($stats->{count_query_ms})],
        ['Compilation', _debug_ms($stats->{compile_ms})],
        ['Domain and state', _debug_ms($stats->{setup_ms})],
        ['Query construction', _debug_ms($stats->{build_ms})],
        ['Result processing', _debug_ms($stats->{transform_ms})],
        ['Action and saved-query setup', _debug_ms($stats->{decorate_ms})],
        ['Server model total', _debug_ms($stats->{model_ms})],
        ['Rows returned', _debug_number($stats->{returned_rows})],
        ['Rows matched', _debug_number($stats->{matched_rows})],
    );
    my $cards = join '', map {
        '<article class="sc-debug-stat"><span>' . _h($_->[0]) . '</span><strong>' .
            _h($_->[1]) . '</strong></article>'
    } @cards;
    my $metadata = join ' · ', (
        'Adapter: ' . _debug_text($stats->{adapter}),
        'View: ' . _debug_text($stats->{view}),
        'Page: ' . _debug_number($stats->{page}) . ' of ' .
            _debug_number($stats->{total_pages}),
        'Page size: ' . _debug_number($stats->{page_size}),
    );
    my $id = $model->{config}->id;
    my $queries = _debug_query(
        'selecto-debug-data-' . $id,
        'Generated data query',
        $debug->{data_query},
    );
    $queries .= _debug_query(
        'selecto-debug-count-' . $id,
        'Generated count query',
        $debug->{count_query},
    ) if ref($debug->{count_query}) eq 'HASH';
    return '<details class="sc-debug-panel" data-sc-debug-panel open><summary>' .
        '<span><small>Sandbox tooling</small><strong>Query Debug</strong></span>' .
        '<span>' . _h(_debug_ms($stats->{total_ms})) . ' total</span></summary>' .
        '<div class="sc-debug-body"><div class="sc-debug-stats">' . $cards . '</div>' .
        '<p class="sc-debug-metadata">' . _h($metadata) . '</p>' .
        '<p class="sc-debug-metadata" data-sc-client-performance></p>' .
        $queries . '</div></details>';
}

sub _debug_query ($id, $title, $query) {
    return '' unless ref($query) eq 'HASH' && defined($query->{sql});
    my $parameters = $query->{params} // [];
    my $parameter_list = @$parameters ? '<ol class="sc-debug-params">' . join('', map {
        my $index = $_;
        '<li><span>$' . ($index + 1) . '</span><code>' .
            _h(_debug_parameter($parameters->[$index])) . '</code></li>'
    } 0 .. $#$parameters) . '</ol>' : '<p class="sc-debug-no-params">No bound parameters.</p>';
    return '<article class="sc-debug-query"><header><h4>' . _h($title) . '</h4>' .
        '<button class="sc-button sc-secondary" type="button" data-sc-debug-copy="' .
        _h($id) . '">Copy SQL</button></header><pre id="' . _h($id) .
        '"><code class="sc-sql">' . _highlight_sql($query->{sql}) . '</code></pre>' .
        '<div class="sc-debug-parameter-block"><h5>Bound parameters</h5>' .
        $parameter_list . '</div></article>';
}

sub _format_sql ($sql) {
    my $formatted = "$sql";
    $formatted =~ s/\s+/ /g;
    $formatted = _break_top_level_commas($formatted);
    $formatted =~ s/\s+(FROM|(?:LEFT|RIGHT|FULL|INNER|CROSS) JOIN|WHERE|GROUP BY|ORDER BY|HAVING|LIMIT|OFFSET)\s+/\n$1 /gi;
    $formatted =~ s/\s+(AND|OR)\s+/\n  $1 /gi;
    $formatted =~ s/\s+ON\s+/\n  ON /gi;
    return $formatted;
}

sub _break_top_level_commas ($sql) {
    my ($depth, $single_quote, $double_quote) = (0, 0, 0);
    my $formatted = '';
    for (my $index = 0; $index < length($sql); $index++) {
        my $character = substr($sql, $index, 1);
        my $next = $index + 1 < length($sql) ? substr($sql, $index + 1, 1) : '';
        $formatted .= $character;
        if ($single_quote) {
            if ($character eq q{'}) {
                if ($next eq q{'}) {
                    $formatted .= $next;
                    $index++;
                } else {
                    $single_quote = 0;
                }
            }
            next;
        }
        if ($double_quote) {
            if ($character eq q{"}) {
                if ($next eq q{"}) {
                    $formatted .= $next;
                    $index++;
                } else {
                    $double_quote = 0;
                }
            }
            next;
        }
        if ($character eq q{'}) {
            $single_quote = 1;
        } elsif ($character eq q{"}) {
            $double_quote = 1;
        } elsif ($character eq '(') {
            $depth++;
        } elsif ($character eq ')') {
            $depth-- if $depth;
        } elsif ($character eq ',' && !$depth) {
            $index++ while $index + 1 < length($sql)
                && substr($sql, $index + 1, 1) =~ /\s/;
            $formatted .= "\n  ";
        }
    }
    return $formatted;
}

sub _highlight_sql ($sql) {
    my %keyword = map { $_ => 1 } qw(
        ALL AND AS ASC BETWEEN BY CASE CROSS DESC DISTINCT ELSE END EXISTS
        FALSE FETCH FIRST FROM FULL GROUP HAVING IN INNER INTERSECT IS JOIN
        LEFT LIKE LIMIT NOT NULL NULLS OFFSET ON OR ORDER OUTER RIGHT SELECT
        THEN TRUE UNION USING WHEN WHERE WITH
    );
    my $source = _format_sql($sql);
    my $html = '';
    while (length $source) {
        if ($source =~ s/\A(--[^\n]*|\/\*.*?\*\/)//s) {
            $html .= '<span class="sc-sql-comment">' . _h($1) . '</span>';
        }
        elsif ($source =~ s/\A('(?:''|[^'])*')//s) {
            $html .= '<span class="sc-sql-string">' . _h($1) . '</span>';
        }
        elsif ($source =~ s/\A("(?:""|[^"])*")//s) {
            $html .= '<span class="sc-sql-identifier">' . _h($1) . '</span>';
        }
        elsif ($source =~ s/\A(\$\d+)//) {
            $html .= '<span class="sc-sql-parameter">' . _h($1) . '</span>';
        }
        elsif ($source =~ s/\A(\b\d+(?:\.\d+)?\b)//) {
            $html .= '<span class="sc-sql-number">' . _h($1) . '</span>';
        }
        elsif ($source =~ s/\A(\b[A-Za-z_][A-Za-z0-9_]*\b)//) {
            my $word = $1;
            $html .= $keyword{uc $word}
                ? '<span class="sc-sql-keyword">' . _h($word) . '</span>'
                : _h($word);
        }
        else {
            $source =~ s/\A(.)//s;
            $html .= _h($1);
        }
    }
    return $html;
}

sub _debug_parameter ($value) {
    return 'NULL' unless defined($value);
    return encode_json($value) if ref($value);
    my $encoded = encode_json("$value");
    return $encoded;
}

sub _debug_ms ($value) {
    return '—' unless defined($value) && !ref($value);
    return "$value ms";
}

sub _debug_number ($value) {
    return '—' unless defined($value) && !ref($value);
    my $number = "$value";
    1 while $number =~ s/\A(-?\d+)(\d{3})/$1,$2/;
    return $number;
}

sub _debug_text ($value) {
    return '—' unless defined($value) && !ref($value) && length("$value");
    return "$value";
}

1;
