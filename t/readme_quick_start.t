use strict;
use warnings;
use Test::More;
use File::Spec ();
use File::Temp ();
use FindBin ();

# The README's quick start is the first thing a reader runs: it must start and
# render its page as written.
eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is not installed';

my $readme = File::Spec->catfile($FindBin::Bin, '..', 'README.md');
open my $fh, '<', $readme or die "cannot read README.md: $!";
my $text = do { local $/; <$fh> };
close $fh;
my ($app) = $text =~ /^## Quick start\n.*?^```perl\n(.*?)^```/ms;
ok(defined $app, 'the README has a quick start') or do { done_testing; exit };

my $file = File::Temp->new(SUFFIX => '.pl');
print {$file} $app;
close $file;
my $output = do {
    local $ENV{MOJO_LOG_LEVEL} = 'fatal';
    my @inc = map { "-I$_" } grep { !ref } @INC;
    open my $run, '-|', $^X, @inc, $file->filename, 'get', '/explore/products' or die "cannot run the quick start: $!";
    local $/;
    my $out = <$run>;
    close $run;
    is($? >> 8, 0, 'the quick start runs');
    $out // '';
};
like($output, qr/Chai/, 'and renders its products');
like($output, qr/Beverages/, 'grouped by category');

done_testing;
