requires 'perl', '5.034';
requires 'Excel::Writer::XLSX', '1.10';
requires 'Digest::SHA';
requires 'JSON::PP', '4.06';
requires 'Mojolicious', '9.49';
requires 'Selecto', '0.2.0';
requires 'Selecto::Templates', '0.001000';

on test => sub {
    requires 'Test::More';
};
