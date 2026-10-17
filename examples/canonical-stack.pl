#!/usr/bin/env perl
use 5.034;
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CanonicalStack;

my $app = CanonicalStack->new;
if (@ARGV && $ARGV[0] eq 'setup') {
    $app->setup_database;
    print "Owned canonical stack fixture created.\n";
    exit 0;
}
$app->start;
