use 5.034;
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use FindBin qw($Bin);
use File::Spec;

sub token_hash { sha256_hex('selecto-denylist-v1:' . $_[0]) }

my ($framework_name) = split /::/, 'Mojo::Base';
my $framework_description = lc "the standard $framework_name content class";

sub violations {
    my ($text, $hashes, $file) = @_;
    my @found;
    my $line = 0;
    for my $value (split /\n/, lc($text)) {
        ++$line;
        # Only the framework's GitHub namespace and this exact framework
        # description are exempt. Other URLs and standalone names still scan.
        $value =~ s{\bhttps://github\.com/mojolicious/[a-z0-9_./?\#%&=:+~-]+}{framework_reference}g;
        $value =~ s/\Q$framework_description\E/the standard framework content class/g;
        my %seen;
        for my $token ($value =~ /[a-z0-9_.:-]+/g) {
            $token =~ s/^[.:-]+|[.:-]+$//g;
            # Package separators stay intact; dotted and hyphenated words
            # also contribute their individual pieces.
            for my $piece ($token, split /[.\-\/]/, $token) {
                $piece =~ s/^[.:-]+|[.:-]+$//g;
                next unless length $piece;
                my $hash = token_hash($piece);
                push @found, "$file:$line:$hash" if $hashes->{$hash} && !$seen{$hash}++;
            }
        }
    }
    return @found;
}

my $planted = 'invented_guard_probe';
my %probe = (token_hash($planted) => 1);
is_deeply [violations("safe\nINVENTED_GUARD_PROBE", \%probe, 'memory')],
    ['memory:2:' . token_hash($planted)], 'in-memory planted token is caught';
is scalar(violations("prefix.$planted suffix-$planted /$planted/", \%probe, 'memory')),
    1, 'dotted, hyphenated and path pieces are checked without duplicate diagnostics';
is scalar(violations("${planted}::Base ${planted}_suffix", \%probe, 'memory')),
    0, 'package separators and underscore tokens remain intact';
is scalar(violations("dir/$planted.pm", \%probe, 'path')), 1, 'file paths are checked';

my $css_prefix = 'inventedstyle';
my %css_probe = (token_hash($css_prefix) => 1);
for my $case (
        ["--$css_prefix-name: red", 'custom property'],
        [".$css_prefix-name {}", 'class name'],
        ["var(--$css_prefix-name)", 'variable reference']) {
    is_deeply [violations($case->[0], \%css_probe, 'memory')],
        ['memory:1:' . token_hash($css_prefix)], "invented prefix is caught in a CSS $case->[1]";
}

my $framework_token = lc $framework_name;
my %framework_probe = (token_hash($framework_token) => 1);
is scalar(violations("https://github.com/mojolicious/$framework_token/blob/main/Changes",
        \%framework_probe, 'memory')), 0, 'framework repository URL is allowed';
is scalar(violations("the standard $framework_name content class", \%framework_probe, 'memory')),
    0, 'exact framework content-class description is allowed';
for my $text ("https://github.com/another/$framework_token",
        "https://github.com/mojolicious.example/$framework_token",
        "https://elsewhere.example/mojolicious/$framework_token", $framework_token,
        "https://github.com/mojolicious/project $framework_token") {
    is scalar(violations($text, \%framework_probe, 'memory')), 1,
        'framework exception does not hide unrelated tokens or URLs';
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $hash_file = 't/data/denylist.sha256';
open my $input, '<', File::Spec->catfile($root, $hash_file) or die "Cannot read hashes: $!";
chomp(my @hashes = <$input>);
close $input or die "Cannot close hashes: $!";
ok @hashes && !grep(!/\A[0-9a-f]{64}\z/, @hashes), 'committed hashes are lowercase SHA-256';
my %hashes = map { $_ => 1 } @hashes;
is scalar(keys %hashes), scalar(@hashes), 'hashes contain no duplicates';

SKIP: {
    # Release tarballs have no Git metadata. Self-tests above still run there.
    skip 'repository scan requires a Git checkout', 1 unless -e "$root/.git";
    open my $git, '-|', 'git', '-C', $root, 'ls-files', '-z' or die "Cannot list tracked files: $!";
    my @files = split /\0/, do { local $/; <$git> };
    close $git or die "git ls-files failed";
    my @found;
    for my $file (@files) {
        next if $file eq $hash_file;
        push @found, violations($file, \%hashes, $file);
        open my $source, '<:raw', File::Spec->catfile($root, $file) or die "Cannot read $file: $!";
        my $content = do { local $/; <$source> } // '';
        close $source or die "Cannot close $file: $!";
        next if $content =~ /\0/;
        push @found, violations($content, \%hashes, $file);
    }
    is_deeply \@found, [], 'tracked text and paths contain no denied tokens'
        or do {
            diag "Denied tokens (file:line:SHA-256):\n" . join("\n", @found);
            diag 'Generated Console assets require an upstream rebuild and re-sync.'
                if grep { m{\Apublic/selecto-api-console/} } @found;
        };
}

done_testing;
