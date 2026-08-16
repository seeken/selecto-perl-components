requires 'perl', '5.034';
requires 'JSON::PP', '4.06';
requires 'Mojolicious', '9.40';
requires 'Selecto', '0.2.0';

on test => sub {
    requires 'Test::More';
};
