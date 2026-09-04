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
        $stats->{adapter},
    );
    $queries .= _debug_query(
        'selecto-debug-count-' . $id,
        'Generated count query',
        $debug->{count_query},
        $stats->{adapter},
    ) if ref($debug->{count_query}) eq 'HASH';
    return '<details class="sc-debug-panel" data-sc-debug-panel><summary>' .
        '<span><small>Sandbox tooling</small><strong>Query Debug</strong></span>' .
        '<span>' . _h(_debug_ms($stats->{total_ms})) . ' total</span></summary>' .
        '<div class="sc-debug-body"><div class="sc-debug-stats">' . $cards . '</div>' .
        '<p class="sc-debug-metadata">' . _h($metadata) . '</p>' .
        '<p class="sc-debug-metadata" data-sc-client-performance></p>' .
        $queries . '</div></details>';
}

sub _debug_query ($id, $title, $query, $adapter = undef) {
    return '' unless ref($query) eq 'HASH' && defined($query->{sql});
    my $parameters = $query->{params} // [];
    my $parameter_list = @$parameters ? '<ol class="sc-debug-params">' . join('', map {
        my $index = $_;
        '<li><span>$' . ($index + 1) . '</span><code>' .
            _h(_debug_parameter($parameters->[$index])) . '</code></li>'
    } 0 .. $#$parameters) . '</ol>' : '<p class="sc-debug-no-params">No bound parameters.</p>';
    my $copy_id = $id . '-standalone';
    my $readable_sql = _readable_sql($query->{sql}, $adapter);
    my $standalone_sql = _interpolate_sql($readable_sql, $parameters, $adapter);
    return '<article class="sc-debug-query"><header><h4>' . _h($title) . '</h4>' .
        '<button class="sc-button sc-secondary" type="button" data-sc-debug-copy="' .
        _h($id) . '" data-sc-debug-copy-source="' . _h($copy_id) . '">Copy SQL</button></header>' .
        '<pre id="' . _h($id) . '"><code class="sc-sql">' .
        _highlight_sql($readable_sql) . '</code></pre>' .
        '<pre id="' . _h($copy_id) . '" hidden aria-hidden="true">' .
        _h(_format_sql($standalone_sql)) . '</pre>' .
        '<div class="sc-debug-parameter-block"><h5>Bound parameters</h5>' .
        $parameter_list . '</div></article>';
}

sub _interpolate_sql ($sql, $parameters, $adapter = undef) {
    return "$sql" unless ref($parameters) eq 'ARRAY' && @$parameters;
    my $dialect = lc($adapter // '');
    my $position = 0;
    return _map_sql_tokens($sql, sub ($token, $kind) {
        if ($kind eq 'postgresql_parameter' && $dialect eq 'postgresql') {
            my ($index) = $token =~ /\A\$(\d+)\z/;
            return $index && $index <= @$parameters
                ? _sql_literal($parameters->[$index - 1], $dialect) : $token;
        }
        if ($kind eq 'question_parameter' && $dialect =~ /\A(?:mysql|mariadb|mssql|sqlite|duckdb)\z/) {
            return $position < @$parameters
                ? _sql_literal($parameters->[$position++], $dialect) : $token;
        }
        return $token;
    });
}

sub _readable_sql ($sql, $adapter = undef) {
    return "$sql" unless lc($adapter // '') eq 'postgresql';
    my %reserved = map { $_ => 1 } qw(
        all analyse analyze and any array as asc asymmetric authorization binary
        both case cast check collate collation column concurrently constraint create cross
        current_catalog current_date current_role current_time current_timestamp
        current_schema current_user default deferrable desc distinct do else end except false
        fetch for foreign freeze from full grant group having ilike in initially
        inner intersect into is isnull join lateral leading left like limit localtime
        localtimestamp natural not notnull null nulls offset on only or order outer
        overlaps placing primary references returning right select session_user
        similar some symmetric table then to trailing true union unique user using
        tablesample variadic verbose when where window with
    );
    return _map_sql_tokens($sql, sub ($token, $kind) {
        return $token unless $kind eq 'quoted_identifier';
        my $identifier = substr($token, 1, length($token) - 2);
        $identifier =~ s/""/"/g;
        return $identifier
            if $identifier =~ /\A[a-z_][a-z0-9_\$]*\z/ && !$reserved{$identifier};
        return $token;
    });
}

sub _map_sql_tokens ($sql, $mapper) {
    my $source = "$sql";
    my $output = '';
    pos($source) = 0;
    while ((pos($source) // 0) < length($source)) {
        if ($source =~ /\G(--[^\n]*(?:\n|\z))/gc) {
            my $token = $1;
            $output .= $mapper->($token, 'comment');
        } elsif ($source =~ m{\G(/\*.*?\*/)}gcs) {
            my $token = $1;
            $output .= $mapper->($token, 'comment');
        } elsif ($source =~ /\G('(?:''|[^'])*')/gcs) {
            my $token = $1;
            $output .= $mapper->($token, 'string');
        } elsif ($source =~ /\G("(?:""|[^"])*")/gcs) {
            my $token = $1;
            $output .= $mapper->($token, 'quoted_identifier');
        } elsif ($source =~ /\G(\$\d+)/gc) {
            my $token = $1;
            $output .= $mapper->($token, 'postgresql_parameter');
        } elsif ($source =~ /\G(\?)/gc) {
            my $token = $1;
            $output .= $mapper->($token, 'question_parameter');
        } elsif ($source =~ /\G(.)/gcs) {
            $output .= $1;
        } else {
            last;
        }
    }
    return $output;
}

sub _sql_literal ($value, $adapter) {
    return 'NULL' unless defined $value;
    my $text = ref($value) ? encode_json($value) : "$value";
    $text =~ s/'/''/g;
    if ($adapter eq 'postgresql') {
        $text =~ s/\\/\\\\/g;
        $text =~ s/\x00/\\000/g;
        $text =~ s/\r/\\r/g;
        $text =~ s/\n/\\n/g;
        $text =~ s/\t/\\t/g;
        return "E'$text'";
    }
    return "N'$text'" if $adapter eq 'mssql';
    return "'$text'";
}

sub _format_sql ($sql) {
    my @protected;
    my $formatted = _map_sql_tokens($sql, sub ($token, $kind) {
        return $token unless $kind eq 'string' || $kind eq 'quoted_identifier' || $kind eq 'comment';
        my $index = @protected;
        push @protected, $token;
        return "\x1e$index\x1f";
    });
    $formatted =~ s/\s+/ /g;
    $formatted = _break_top_level_commas($formatted);
    $formatted = _mark_subqueries($formatted);
    $formatted =~ s/\s+(FROM|(?:LEFT|RIGHT|FULL|INNER|CROSS) JOIN|WHERE|GROUP BY|ORDER BY|HAVING|LIMIT|OFFSET)\s+/\n$1 /gi;
    $formatted =~ s/\s+(AND|OR)\s+/\n  $1 /gi;
    $formatted =~ s/\s+ON\s+/\n  ON /gi;
    $formatted =~ s/[ \t]*\n[ \t]*/\n/g;
    $formatted = _indent_subqueries($formatted);
    $formatted =~ s/\x1e(\d+)\x1f/$protected[$1]/ge;
    return $formatted;
}

sub _mark_subqueries ($sql) {
    my $source = "$sql";
    my $output = '';
    my @parentheses;
    for (my $index = 0; $index < length($source); $index++) {
        my $character = substr($source, $index, 1);
        if ($character eq '(') {
            my $remaining = substr($source, $index + 1);
            my $subquery = $remaining =~ /\A\s*(?:SELECT|WITH)\b/i ? 1 : 0;
            push @parentheses, $subquery;
            $output .= $subquery ? "(\n\x1d+" : '(';
        } elsif ($character eq ')') {
            my $subquery = @parentheses ? pop(@parentheses) : 0;
            $output .= $subquery ? "\n\x1d-)" : ')';
        } else {
            $output .= $character;
        }
    }
    return $output;
}

sub _indent_subqueries ($sql) {
    my $depth = 0;
    my @lines;
    for my $line (split /\n/, "$sql") {
        while ($line =~ s/\A\x1d-//) { $depth-- if $depth }
        while ($line =~ s/\A\x1d\+//) { $depth++ }
        my $comma_continuation = $line =~ s/\A\x1c// ? 1 : 0;
        $line =~ s/\A\s+//;
        $line =~ s/\s+\z//;
        next unless length $line;
        my $continuation = $comma_continuation || $line =~ /\A(?:AND|OR|ON)\b/i ? 1 : 0;
        push @lines, ('  ' x $depth) . ('  ' x $continuation) . $line;
    }
    return join "\n", @lines;
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
            $formatted .= "\n\x1c";
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
    my $relation_info = _relation_colors($sql);
    my $relations = $relation_info->{by_name};
    my @relation_slots = @{$relation_info->{slots}};
    my $expect_relation = 0;
    my $source = _format_sql($sql);
    my $html = '';
    pos($source) = 0;
    while ((pos($source) // 0) < length($source)) {
        if ($source =~ /\G(--[^\n]*|\/\*.*?\*\/)/gcs) {
            my $token = $1;
            $html .= '<span class="sc-sql-comment">' . _h($token) . '</span>';
        }
        elsif ($source =~ /\G('(?:''|[^'])*')/gcs) {
            my $token = $1;
            $html .= '<span class="sc-sql-string">' . _h($token) . '</span>';
        }
        elsif ($source =~ /\G("(?:""|[^"])*")/gcs) {
            my $identifier = $1;
            my $plain = substr($identifier, 1, length($identifier) - 2);
            $plain =~ s/""/"/g;
            if ($expect_relation && @relation_slots) {
                $html .= _relation_span($identifier, shift @relation_slots);
                $expect_relation = 0;
            } else {
                $html .= exists($relations->{$plain})
                ? _relation_span($identifier, $relations->{$plain})
                : '<span class="sc-sql-identifier">' . _h($identifier) . '</span>';
            }
        }
        elsif ($source =~ /\G(\$\d+)/gc) {
            my $token = $1;
            $html .= '<span class="sc-sql-parameter">' . _h($token) . '</span>';
        }
        elsif ($source =~ /\G(\b\d+(?:\.\d+)?\b)/gc) {
            my $token = $1;
            $html .= '<span class="sc-sql-number">' . _h($token) . '</span>';
        }
        elsif ($source =~ /\G(\b([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\b)/gc) {
            my ($qualified, $relation) = ($1, $2);
            if ($expect_relation && @relation_slots) {
                $html .= _relation_span($qualified, shift @relation_slots);
                $expect_relation = 0;
            } else {
                $html .= exists($relations->{$relation})
                    ? _relation_span($qualified, $relations->{$relation}) : _h($qualified);
            }
        }
        elsif ($source =~ /\G(\b[A-Za-z_][A-Za-z0-9_]*\b)/gc) {
            my $word = $1;
            if ($expect_relation && @relation_slots && !$keyword{uc $word}
                && uc($word) ne 'LATERAL' && uc($word) ne 'ONLY') {
                $html .= _relation_span($word, shift @relation_slots);
                $expect_relation = 0;
            } else {
                $html .= exists($relations->{$word})
                    ? _relation_span($word, $relations->{$word})
                    : $keyword{uc $word}
                    ? '<span class="sc-sql-keyword">' . _h($word) . '</span>'
                    : _h($word);
            }
            $expect_relation = 1 if uc($word) eq 'FROM' || uc($word) eq 'JOIN';
        }
        elsif ($source =~ /\G(.)/gcs) {
            $html .= _h($1);
        } else {
            last;
        }
    }
    return $html;
}

sub _relation_colors ($sql) {
    my %colors;
    my @slots;
    my $next = 0;
    my $source = "$sql";
    while ($source =~ /\b(?:FROM|JOIN)\s+
        ((?:"(?:""|[^"])+"|[A-Za-z_][A-Za-z0-9_]*)(?:\.(?:"(?:""|[^"])+"|[A-Za-z_][A-Za-z0-9_]*))?)
        \s+AS\s+("(?:""|[^"])+"|[A-Za-z_][A-Za-z0-9_]*)/gix) {
        my ($relation, $alias) = ($1, $2);
        for ($relation, $alias) {
            s/"((?:""|[^"])*)"/$1/g;
            s/""/"/g;
        }
        my ($table) = $relation =~ /([^.]+)\z/;
        my $color = ++$next;
        push @slots, $color;
        $colors{$alias} = $color;
    }
    return {by_name => \%colors, slots => \@slots};
}

sub _relation_span ($text, $color) {
    my $style = '';
    if ($color > 8) {
        my $hue = (29 + ($color - 1) * 137) % 360;
        $style = ' style="--sc-sql-relation-color:hsl(' . $hue . ' 78% 72%)"';
    }
    return '<span class="sc-sql-relation sc-sql-relation-' . int($color) . '"' . $style . '>' .
        _h($text) . '</span>';
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
