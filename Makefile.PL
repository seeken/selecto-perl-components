use 5.034;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Selecto::Components',
    VERSION_FROM     => 'lib/Selecto/Components.pm',
    ABSTRACT_FROM    => 'lib/Selecto/Components.pm',
    AUTHOR           => 'Chris Rohlfs',
    LICENSE          => 'artistic_1',
    MIN_PERL_VERSION => '5.034',
    PM => {
        'lib/Selecto/Components.pm' => '$(INST_LIB)/Selecto/Components.pm',
        'lib/Selecto/Components/APIConsole.pm' => '$(INST_LIB)/Selecto/Components/APIConsole.pm',
        'lib/Selecto/Components/Actions.pm' => '$(INST_LIB)/Selecto/Components/Actions.pm',
        'lib/Selecto/Components/BucketParser.pm' => '$(INST_LIB)/Selecto/Components/BucketParser.pm',
        'lib/Selecto/Components/Config.pm' => '$(INST_LIB)/Selecto/Components/Config.pm',
        'lib/Selecto/Components/DateShortcut.pm' => '$(INST_LIB)/Selecto/Components/DateShortcut.pm',
        'lib/Selecto/Components/Explorer.pm' => '$(INST_LIB)/Selecto/Components/Explorer.pm',
        'lib/Selecto/Components/QueryBuilder.pm' => '$(INST_LIB)/Selecto/Components/QueryBuilder.pm',
        'lib/Selecto/Components/QueryLibrary.pm' => '$(INST_LIB)/Selecto/Components/QueryLibrary.pm',
        'lib/Selecto/Components/Renderer.pm' => '$(INST_LIB)/Selecto/Components/Renderer.pm',
        'lib/Selecto/Components/Renderer/Builder.pm' => '$(INST_LIB)/Selecto/Components/Renderer/Builder.pm',
        'lib/Selecto/Components/Renderer/Debug.pm' => '$(INST_LIB)/Selecto/Components/Renderer/Debug.pm',
        'lib/Selecto/Components/Renderer/Markup.pm' => '$(INST_LIB)/Selecto/Components/Renderer/Markup.pm',
        'lib/Selecto/Components/Renderer/Results.pm' => '$(INST_LIB)/Selecto/Components/Renderer/Results.pm',
        'lib/Selecto/Components/State.pm' => '$(INST_LIB)/Selecto/Components/State.pm',
        'lib/Selecto/Components/Util.pm' => '$(INST_LIB)/Selecto/Components/Util.pm',
        'public/selecto-components/chart.umd.min.js' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/chart.umd.min.js',
        'public/selecto-components/api-console.css' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/api-console.css',
        'public/selecto-components/api-console.js' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/api-console.js',
        'public/selecto-components/htmx.min.js' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/htmx.min.js',
        'public/selecto-components/hx-ws.min.js' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/hx-ws.min.js',
        'public/selecto-components/selecto-components.css' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/selecto-components.css',
        'public/selecto-components/selecto-components.js' => '$(INST_LIB)/auto/share/dist/Selecto-Components/public/selecto-components/selecto-components.js',
    },
    PREREQ_PM        => {
        'Excel::Writer::XLSX' => '1.10',
        'JSON::PP'    => '4.06',
        'Mojolicious' => '9.40',
        'Selecto'     => '0.2.0',
        'Time::HiRes' => 0,
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/seeken/selecto-perl-components.git',
                web  => 'https://github.com/seeken/selecto-perl-components',
            },
        },
        x_license => 'Artistic-1.0',
    },
);
