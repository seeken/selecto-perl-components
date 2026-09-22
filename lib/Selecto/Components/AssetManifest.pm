package Selecto::Components::AssetManifest;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(asset_revision);
my $ASSET_REVISION = '0.1.0-2a3e7dbdec4f';

sub asset_revision { return $ASSET_REVISION; }

1;
