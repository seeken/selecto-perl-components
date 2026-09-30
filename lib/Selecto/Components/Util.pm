package Selecto::Components::Util;

use 5.034;
use strict;
use warnings;
use Exporter 'import';
use Mojo::Util qw(xml_escape);

our @EXPORT_OK = qw(humanize html_escape trim);

sub html_escape {
    my ($value) = @_;
    return xml_escape(defined($value) ? "$value" : '');
}

sub humanize {
    my ($value) = @_;
    my $text = defined($value) ? "$value" : '';
    $text =~ s/[._-]+/ /g;
    $text =~ s/\b([a-z])/uc($1)/eg;
    return $text;
}

sub trim {
    my ($value) = @_;
    $value = defined($value) && !ref($value) ? "$value" : '';
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

1;

__END__

=head1 NAME

Selecto::Components::Util - Small string helpers shared by Selecto::Components modules

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

It exports C<html_escape>, C<humanize> and C<trim> on request.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
