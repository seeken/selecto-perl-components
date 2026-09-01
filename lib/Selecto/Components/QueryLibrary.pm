package Selecto::Components::QueryLibrary;

use Mojo::Base -base, -signatures;
use Selecto::Components::Util qw(humanize);
use Selecto::QueryLibrary ();

sub entries ($class, $domain, $registry, $config = undef) {
    my $definitions = Selecto::QueryLibrary->definitions($domain, $registry);
    my @entries = map {
        my $id = "$_";
        my $spec = $definitions->{$_};
        {
            id => $id,
            label => _localized(
                $config, $domain, "query_library.$registry.$id.label",
                _label($id, $spec),
                {kind => 'query_library', registry => $registry, id => $id, attribute => 'label'},
            ),
            description => _localized(
                $config, $domain, "query_library.$registry.$id.description",
                _text($spec->{description}),
                {kind => 'query_library', registry => $registry, id => $id, attribute => 'description'},
            ),
            capability => _text($spec->{capability}),
        }
    } grep { ref($definitions->{$_}) eq 'HASH' } keys %$definitions;
    return [sort {
        lc($a->{label}) cmp lc($b->{label}) || $a->{id} cmp $b->{id}
    } @entries];
}

sub active_segment_entries ($class, $domain, $view, $segments = [], $config = undef) {
    my @ids;
    push @ids, @{$class->view_segment_ids($domain, $view)}
        if defined($view) && !ref($view) && length("$view");
    push @ids, @$segments;
    my %seen;
    @ids = grep { !$seen{"$_"}++ } @ids;

    my %by_id = map { $_->{id} => $_ } @{$class->entries($domain, 'segments', $config)};
    return [map { $by_id{"$_"} } grep { exists($by_id{"$_"}) } @ids];
}

sub view_segment_ids ($class, $domain, $view) {
    return [] unless defined($view) && !ref($view) && length("$view");
    return Selecto::QueryLibrary->view_segments($domain, $view);
}

sub parameter_entries ($class, $domain, $view, $segments = [], $config = undef) {
    my $specs = Selecto::QueryLibrary->parameter_specs(
        $domain,
        (defined($view) && !ref($view) && length("$view") ? (view => $view) : ()),
        segments => $segments,
    );
    my @entries = map {
        my $id = "$_";
        my $spec = $specs->{$_};
        {
            id => $id,
            label => _localized(
                $config, $domain, "query_library.parameters.$id.label",
                _label($id, $spec),
                {kind => 'query_library_parameter', id => $id, attribute => 'label'},
            ),
            type => lc(_text($spec->{type}) || 'string'),
            required => ($spec->{required} // !exists($spec->{default})) ? 1 : 0,
            default => $spec->{default},
            description => _localized(
                $config, $domain, "query_library.parameters.$id.description",
                _text($spec->{description}),
                {kind => 'query_library_parameter', id => $id, attribute => 'description'},
            ),
        }
    } grep { ref($specs->{$_}) eq 'HASH' } keys %$specs;
    return [sort {
        lc($a->{label}) cmp lc($b->{label}) || $a->{id} cmp $b->{id}
    } @entries];
}

sub input_type ($class, $type) {
    $type = lc(_text($type));
    return 'number' if $type =~ /\A(?:integer|float|decimal)\z/;
    return 'date' if $type eq 'date';
    return 'datetime-local' if $type =~ /datetime/;
    return 'checkbox' if $type eq 'boolean';
    return 'text';
}

sub _label ($id, $spec) {
    return _text($spec->{label}) || _humanize($id);
}

sub _localized ($config, $domain, $semantic, $default, $context) {
    return $default unless ref($config) && eval { $config->can('localize') };
    return $config->localize($domain, $semantic, $default, $context);
}

sub _text ($value) {
    return '' unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

sub _humanize ($value) { return humanize($value); }

1;
