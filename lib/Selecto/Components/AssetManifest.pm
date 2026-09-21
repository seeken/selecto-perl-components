package Selecto::Components::AssetManifest;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(asset_revision);
my $ASSET_REVISION = '0.1.0-79f4a4dc6bf1';

sub asset_revision { return $ASSET_REVISION; }

1;
