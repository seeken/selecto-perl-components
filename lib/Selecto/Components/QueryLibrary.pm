package Selecto::Components::QueryLibrary;

use Mojo::Base -base, -signatures;
use Selecto::QueryLibrary ();

sub entries ($class, $domain, $registry) {
    my $definitions = Selecto::QueryLibrary->definitions($domain, $registry);
    my @entries = map {
        my $id = "$_";
        my $spec = $definitions->{$_};
        {
            id => $id,
            label => _label($id, $spec),
            description => _text($spec->{description}),
            capability => _text($spec->{capability}),
        }
    } grep { ref($definitions->{$_}) eq 'HASH' } keys %$definitions;
    return [sort {
        lc($a->{label}) cmp lc($b->{label}) || $a->{id} cmp $b->{id}
    } @entries];
}

sub active_segment_entries ($class, $domain, $view, $segments = []) {
    my @ids;
    push @ids, @{$class->view_segment_ids($domain, $view)}
        if defined($view) && !ref($view) && length("$view");
    push @ids, @$segments;
    my %seen;
    @ids = grep { !$seen{"$_"}++ } @ids;

    my %by_id = map { $_->{id} => $_ } @{$class->entries($domain, 'segments')};
    return [map { $by_id{"$_"} } grep { exists($by_id{"$_"}) } @ids];
}

sub view_segment_ids ($class, $domain, $view) {
    return [] unless defined($view) && !ref($view) && length("$view");
    return Selecto::QueryLibrary->view_segments($domain, $view);
}

sub parameter_entries ($class, $domain, $view, $segments = []) {
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
            label => _label($id, $spec),
            type => lc(_text($spec->{type}) || 'string'),
            required => ($spec->{required} // !exists($spec->{default})) ? 1 : 0,
            default => $spec->{default},
            description => _text($spec->{description}),
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

sub _text ($value) {
    return '' unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

sub _humanize ($value) {
    my $label = "$value";
    $label =~ s/[._-]+/ /g;
    $label =~ s/\b([a-z])/\U$1/g;
    return $label;
}

1;
