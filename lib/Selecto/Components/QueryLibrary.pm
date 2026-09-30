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
            ($spec->{picker_hidden} ? (picker_hidden => 1) : ()),
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

sub segment_picker_groups ($class, $domain, $config = undef) {
    return [map {
        my $group = $_;
        +{
            %$group,
            label => _localized(
                $config, $domain, "query_library.segment_picker_groups.$group->{id}.label",
                $group->{label},
                {kind => 'segment_picker_group', id => $group->{id}, attribute => 'label'},
            ),
            description => _localized(
                $config, $domain, "query_library.segment_picker_groups.$group->{id}.description",
                $group->{description},
                {kind => 'segment_picker_group', id => $group->{id}, attribute => 'description'},
            ),
            off_label => _localized(
                $config, $domain, "query_library.segment_picker_groups.$group->{id}.off_label",
                $group->{off_label},
                {kind => 'segment_picker_group', id => $group->{id}, attribute => 'off_label'},
            ),
            choices => [map {
                +{%$_, label => _localized(
                    $config, $domain,
                    "query_library.segment_picker_groups.$group->{id}.choices.$_->{segment}.label",
                    $_->{label},
                    {kind => 'segment_picker_choice', id => $_->{segment}, group => $group->{id}, attribute => 'label'},
                )}
            } @{$group->{choices}}],
        }
    } @{Selecto::QueryLibrary->segment_picker_groups($domain)}];
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

__END__

=head1 NAME

Selecto::Components::QueryLibrary - Present a domain's query library in the Explorer

=head1 SYNOPSIS

    use Selecto::Components::QueryLibrary;

    my $views    = Selecto::Components::QueryLibrary->entries($domain, 'views', $config);
    my $segments = Selecto::Components::QueryLibrary->active_segment_entries(
        $domain, 'low_stock_products', ['premium'], $config);
    my $params   = Selecto::Components::QueryLibrary->parameter_entries(
        $domain, 'low_stock_products', [], $config);

=head1 DESCRIPTION

A canonical domain may declare a C<query_library> of named C<views>,
C<segments>, C<projections>, C<orderings> and typed C<parameters> (see
L<Selecto::QueryLibrary>). The Explorer shows named views in its View tab,
and segments and parameters in its Filters tab. They take part in canonical
URL state as C<query_library_view>, repeated C<query_library_segment>, and
C<query_library_param_name>/C<query_library_param_value> pairs.

Selecting a named view seeds the Detail columns and ordering once, and they
remain editable afterwards. Segments constrain the query alongside the visual
filters. They count as applied filters and are shown as summaries that
cannot be removed individually. C<< picker_hidden => 1 >> keeps an old
segment valid for saved links while hiding it from new selections.
C<segment_picker_groups> renders mutually exclusive segments as radio groups
with an Off choice. A segment's C<capability> is shown as metadata only; it is
not an authorization decision. Parameter values are type-checked by Selecto
and compiled as bound values.

This class turns that metadata into sorted, localized entries for the UI.

=head1 METHODS

All methods are class methods. C<$config> is optional. When it is given,
labels and descriptions are localized through it.

=head2 entries

    my $entries = Selecto::Components::QueryLibrary->entries($domain, $registry, $config);

Returns the C<$registry> (C<views>, C<segments>, ...) as
C<< [{id, label, description, capability, picker_hidden}] >>, sorted by label.

=head2 active_segment_entries

    my $entries = Selecto::Components::QueryLibrary->active_segment_entries(
        $domain, $view_id, \@segment_ids, $config);

The segments that apply: the named view's own segments, followed by the
extra segments.

=head2 segment_picker_groups

    my $groups = Selecto::Components::QueryLibrary->segment_picker_groups($domain, $config);

=head2 view_segment_ids

    my $ids = Selecto::Components::QueryLibrary->view_segment_ids($domain, $view_id);

=head2 parameter_entries

    my $params = Selecto::Components::QueryLibrary->parameter_entries(
        $domain, $view_id, \@segment_ids, $config);

The parameters that the view and segments need, as
C<< [{id, label, type, required, default, description}] >>.

=head2 input_type

    my $html_type = Selecto::Components::QueryLibrary->input_type('integer');   # 'number'

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::QueryLibrary>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
