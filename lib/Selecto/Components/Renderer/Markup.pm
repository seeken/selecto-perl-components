package Selecto::Components::Renderer::Markup;

use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Mojo::Util qw(url_escape);
use Selecto::Components::Util qw(humanize html_escape);

our @EXPORT = qw(
    _h
    _humanize
    _hidden
    _display
    _display_group
    _html_display
    _object_link
    _number
    _numeric
    _selection_hidden
    _measure_selection_hidden
    _limit_options
    _format_url
);

sub _humanize ($value) { return humanize($value); }
sub _h ($value) { return html_escape($value); }
sub _hidden ($name, $value) {
    return '<input type="hidden" name="' . _h($name) . '" value="' . _h($value) . '">';
}
sub _display ($value) { return defined($value) ? "$value" : '—'; }
sub _display_group ($value) { return defined($value) ? "$value" : '[NULL]'; }
sub _html_display ($column, $value, $group = 0) {
    my $display = $group ? _display_group($value) : _display($value);
    return _h($display) unless ($column->{html_format} // '') eq 'vin_last_six';
    return _h($display) unless defined($value) && !ref($value)
        && "$value" =~ /\A[A-Za-z0-9]{17}\z/;
    my $prefix = substr("$value", 0, 11);
    my $suffix = substr("$value", 11, 6);
    return _h($prefix) . '<strong class="sc-vin-suffix">' . _h($suffix) . '</strong>';
}
sub _object_link ($column, $record, $label_html) {
    my $id = $record->{$column->{link_key}};
    return $label_html unless defined($id) && !ref($id) && length("$id");
    my $href = $column->{link}{url_template};
    my $escaped_id = url_escape("$id");
    $href =~ s/\{\{id\}\}/$escaped_id/g;
    return '<a class="sc-object-link" href="' . _h($href) . '">' . $label_html . '</a>';
}
sub _number ($value) {
    return 0 unless defined($value) && !ref($value) && "$value" =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return 0 + $value;
}

sub _numeric ($value) {
    return defined($value) && !ref($value) &&
        "$value" =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/ ? 1 : 0;
}
sub _selection_hidden ($kind, $values, $configs, $config_list = undef) {
    return join '', map {
        my $index = $_;
        my $field = $values->[$index];
        my $config = ref($config_list) eq 'ARRAY' ? ($config_list->[$index] // {})
            : ($configs->{$field} // {});
        _hidden($kind, $field) .
            _hidden($kind . '_alias', $config->{alias} // '') .
            _hidden($kind . '_format', $config->{format} // '') .
            ($kind eq 'group'
                ? _hidden('group_bucket_ranges', $config->{bucket_ranges} // '') .
                  _hidden('group_prefix_length', $config->{prefix_length} // 2) .
                  _hidden('group_exclude_articles', $config->{exclude_articles} ? 1 : 0)
                : '')
    } 0 .. $#$values;
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
sub _limit_options ($state, $config) {
    my %seen;
    my @limits = sort { $a <=> $b } grep { $_ <= $config->max_limit && !$seen{$_}++ }
        (10, 25, 50, 100, $config->default_limit, $state->limit);
    return join '', map {
        '<option value="' . $_ . '"' . ($_ == $state->limit ? ' selected' : '') . '>' . $_ . '</option>'
    } @limits;
}
sub _format_url ($canonical_url, $format) {
    my $separator = $canonical_url =~ /\?/ ? '&' : '?';
    return $canonical_url . $separator . 'format=' . $format;
}

1;
