package Selecto::Components::GroupValue;

use Mojo::Base -base, -signatures;

# Presentation only. Result records and selection/drilldown identities stay raw.
sub boolean_key ($class, $value) {
    return undef unless defined($value) && !ref($value);
    return 'true' if "$value" =~ /\A(?:1|true|t)\z/i;
    return 'false' if "$value" =~ /\A(?:0|false|f|)\z/i;
    return undef;
}

sub labels ($class, $config, $domain, $field) {
    my $display = $domain->field_metadata($field)->{display};
    $display = {} unless ref($display) eq 'HASH';
    return {map {
        my $key = $_;
        my $default = defined($display->{$key}) && !ref($display->{$key})
            ? "$display->{$key}" : $key eq 'true' ? 'Yes' : 'No';
        $key => $config->localize($domain, "fields.$field.display.$key", $default);
    } qw(true false)};
}

sub display ($class, $column, $value) {
    return $value unless ref($column) eq 'HASH' && $column->{boolean_labels};
    my $key = $class->boolean_key($value);
    return defined($key) ? $column->{boolean_labels}{$key} : $value;
}

1;

__END__

=head1 NAME

Selecto::Components::GroupValue - Presentation labels for raw group values

=head1 DESCRIPTION

Internal group presentation shared by HTML, graphs and spreadsheet exports.
Boolean labels come from field C<display.true> and C<display.false> metadata
and the existing semantic i18n dictionary. Raw group values stay unchanged.

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
