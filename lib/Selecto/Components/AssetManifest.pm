package Selecto::Components::AssetManifest;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(asset_revision);
my $ASSET_REVISION = '0.1.0-b1dd8264a01f';

sub asset_revision { return $ASSET_REVISION; }

1;

__END__

=head1 NAME

Selecto::Components::AssetManifest - Cache-busting revision of the packaged browser assets

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
