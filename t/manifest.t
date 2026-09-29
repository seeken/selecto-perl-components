use 5.034;
use strict;
use warnings;
use Test::More;
use File::Find ();
use ExtUtils::Manifest ();

# Makefile.PL installs whatever is on disk under lib/ and public/, but the
# release tarball carries only what MANIFEST lists. A file missing from
# MANIFEST therefore installs from a checkout and silently vanishes from a
# CPAN install, as Dashboard.pm once did.
my $manifest = ExtUtils::Manifest::maniread();
my @shipped;
File::Find::find({no_chdir => 1, wanted => sub {
    push @shipped, $_ if -f $_ && !m{(?:\A|/)\.} && (m{\A(?:lib|public)/} || m{\At/.+\.t\z});
}}, grep { -d } qw(lib public t));

ok(scalar(@shipped), 'found distribution files on disk');
my @missing = sort grep { !exists $manifest->{$_} } @shipped;
is_deeply(\@missing, [], 'every module, asset, and test is listed in MANIFEST')
    or diag("missing from MANIFEST:\n" . join("\n", map { "  $_" } @missing));

done_testing;
