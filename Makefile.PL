use 5.034;
use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::Find ();

# Every module under lib/ and every asset under public/ is installed, public/
# into the dist share directory. The map is built from disk rather than listed
# by hand so a new file cannot be left out; t/manifest.t keeps MANIFEST, and
# with it the release tarball, in step.
my %pm;
File::Find::find({no_chdir => 1, wanted => sub {
    return unless -f $_ && !m{(?:\A|/)\.};
    if (m{\Alib/(.+\.pm)\z}) {
        $pm{$_} = "\$(INST_LIB)/$1";
    } elsif (m{\Apublic/}) {
        $pm{$_} = "\$(INST_LIB)/auto/share/dist/Selecto-Components/$_";
    }
}}, 'lib', 'public');

WriteMakefile(
    NAME             => 'Selecto::Components',
    VERSION_FROM     => 'lib/Selecto/Components.pm',
    ABSTRACT_FROM    => 'lib/Selecto/Components.pm',
    AUTHOR           => 'Chris Rohlfs <seeken@gmail.com>',
    LICENSE          => 'artistic_2',
    MIN_PERL_VERSION => '5.034',
    PM => \%pm,
    PREREQ_PM        => {
        'Excel::Writer::XLSX' => '1.10',
        'Digest::SHA' => 0,
        'JSON::PP'    => '4.06',
        'Mojolicious' => '9.49',
        'Selecto'     => '0.2.0',
        'Time::HiRes' => 0,
    },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '6.64',
    },
    TEST_REQUIRES => {
        'DBD::SQLite' => '1.64',
        'Test::More'  => 0,
        'URI::Escape' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        prereqs => {
            runtime => {
                recommends => {
                    DBI => 0,
                    'DBD::SQLite' => 0,
                },
            },
        },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/seeken/selecto-perl-components.git',
                web  => 'https://github.com/seeken/selecto-perl-components',
            },
            bugtracker => {
                web => 'https://github.com/seeken/selecto-perl-components/issues',
            },
        },
        no_index => {
            directory => [qw(t examples)],
        },
    },
);
