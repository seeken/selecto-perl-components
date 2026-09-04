use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Components::DateShortcut ();

ok(Selecto::Components::DateShortcut->valid('this_year'), 'known shortcut is accepted');
ok(!Selecto::Components::DateShortcut->valid('drop_table'), 'unknown shortcut is rejected');
ok(Selecto::Components::DateShortcut->valid_date('2024-02-29'), 'valid leap date is accepted');
ok(!Selecto::Components::DateShortcut->valid_date('2023-02-29'), 'invalid calendar date is rejected');

is_deeply(
    [Selecto::Components::DateShortcut->bounds('this_year', '2026-08-15')],
    ['2026-01-01', '2027-01-01'],
    'This Year produces a half-open calendar-year range',
);
is_deeply(
    [Selecto::Components::DateShortcut->bounds('this_week', '2026-08-15')],
    ['2026-08-10', '2026-08-17'],
    'This Week starts on Monday and ends exclusively the next Monday',
);
is_deeply(
    [Selecto::Components::DateShortcut->bounds('last_30_days', '2026-08-15')],
    ['2026-07-17', '2026-08-16'],
    'rolling period includes today and contains thirty dates',
);

is_deeply(
    Selecto::Components::DateShortcut->plan('mtd_all_years', '2026-08-15'),
    {kind => 'recurring_month_day', start => '08-01', end => '08-15'},
    'Month to Date across all years uses recurring month/day bounds',
);
is_deeply(
    Selecto::Components::DateShortcut->plan('qtd_all_years', '2026-08-15'),
    {kind => 'recurring_month_day', start => '07-01', end => '08-15'},
    'Quarter to Date across all years starts at the current quarter boundary',
);
is_deeply(
    Selecto::Components::DateShortcut->plan('ytd_all_years', '2024-03-01'),
    {kind => 'recurring_month_day', start => '01-01', end => '03-01'},
    'Year to Date across all years includes leap day when applicable',
);
eval { Selecto::Components::DateShortcut->bounds('ytd_all_years', '2026-08-15') };
like $@, qr/does not have absolute bounds/,
    'recurring shortcuts cannot be mistaken for an absolute date range';

done_testing;
