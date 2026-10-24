requires 'perl', '5.034';
requires 'Excel::Writer::XLSX', '1.10';
requires 'Digest::SHA';
requires 'JSON::PP', '4.06';
requires 'Cpanel::JSON::XS', '>= 4.38, < 4.80';  # 4.80 reorders canonical keys outside the BMP (breaks ER005 and fingerprints)
requires 'Mojolicious', '9.49';
recommends 'DBI';
recommends 'DBD::SQLite';
requires 'Selecto', '0.2.2';
requires 'Time::HiRes';

on configure => sub {
    requires 'ExtUtils::MakeMaker', '6.64';
};

on test => sub {
    requires 'Test::More';
    requires 'URI::Escape';
    # Canned page HTTP tests run against in-memory SQLite and skip without it.
    requires 'DBD::SQLite', '1.64';
};
