package Selecto::Components::AssetManifest;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(asset_revision);
my $ASSET_REVISION = '0.1.0-d4a91bc6e201';

sub asset_revision { return $ASSET_REVISION; }

1;
