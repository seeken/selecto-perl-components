package Selecto::Components::DateShortcut;

use 5.034;
use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timegm);

my @CHOICES = (
    { group => 'Days', id => 'today', label => 'Today' },
    { group => 'Days', id => 'yesterday', label => 'Yesterday' },
    { group => 'Days', id => 'tomorrow', label => 'Tomorrow' },
    { group => 'Weeks', id => 'this_week', label => 'This Week' },
    { group => 'Weeks', id => 'last_week', label => 'Last Week' },
    { group => 'Weeks', id => 'next_week', label => 'Next Week' },
    { group => 'Months', id => 'this_month', label => 'This Month' },
    { group => 'Months', id => 'last_month', label => 'Last Month' },
    { group => 'Months', id => 'next_month', label => 'Next Month' },
    { group => 'Months', id => 'mtd', label => 'Month to Date' },
    { group => 'Quarters', id => 'this_quarter', label => 'This Quarter' },
    { group => 'Quarters', id => 'last_quarter', label => 'Last Quarter' },
    { group => 'Quarters', id => 'next_quarter', label => 'Next Quarter' },
    { group => 'Quarters', id => 'qtd', label => 'Quarter to Date' },
    { group => 'Years', id => 'this_year', label => 'This Year' },
    { group => 'Years', id => 'last_year', label => 'Last Year' },
    { group => 'Years', id => 'next_year', label => 'Next Year' },
    { group => 'Years', id => 'ytd', label => 'Year to Date' },
    { group => 'Relative periods', id => 'last_7_days', label => 'Last 7 Days' },
    { group => 'Relative periods', id => 'last_30_days', label => 'Last 30 Days' },
    { group => 'Relative periods', id => 'last_90_days', label => 'Last 90 Days' },
    { group => 'Relative periods', id => 'next_7_days', label => 'Next 7 Days' },
    { group => 'Relative periods', id => 'next_30_days', label => 'Next 30 Days' },
);

my %KNOWN = map { $_->{id} => 1 } @CHOICES;

sub choices {
    return [map { { %$_ } } @CHOICES];
}

sub valid {
    my ($class, $shortcut) = @_;
    return defined($shortcut) && !ref($shortcut) && $KNOWN{"$shortcut"} ? 1 : 0;
}

sub valid_date {
    my ($class, $date) = @_;
    return 0 unless defined($date) && !ref($date) && "$date" =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
    my ($year, $month, $day) = ($1, $2, $3);
    my $epoch = eval { timegm(0, 0, 12, $day, $month - 1, $year) };
    return 0 unless defined($epoch);
    return strftime('%Y-%m-%d', gmtime($epoch)) eq "$date" ? 1 : 0;
}

sub bounds {
    my ($class, $shortcut, $today) = @_;
    die "date shortcut is not available\n" unless $class->valid($shortcut);
    $today //= strftime('%Y-%m-%d', localtime);
    die "today must be an ISO date\n" unless $class->valid_date($today);

    my ($year, $month) = "$today" =~ /\A(\d{4})-(\d{2})/;
    my $tomorrow = _add_days($today, 1);
    my $month_start = sprintf('%04d-%02d-01', $year, $month);
    my $quarter_month = int(($month - 1) / 3) * 3 + 1;
    my $quarter_start = sprintf('%04d-%02d-01', $year, $quarter_month);
    my $year_start = sprintf('%04d-01-01', $year);
    my $weekday = (gmtime(_epoch($today)))[6];
    my $monday_offset = ($weekday + 6) % 7;
    my $week_start = _add_days($today, -$monday_offset);

    return ($today, $tomorrow) if $shortcut eq 'today';
    return (_add_days($today, -1), $today) if $shortcut eq 'yesterday';
    return ($tomorrow, _add_days($today, 2)) if $shortcut eq 'tomorrow';
    return ($week_start, _add_days($week_start, 7)) if $shortcut eq 'this_week';
    return (_add_days($week_start, -7), $week_start) if $shortcut eq 'last_week';
    return (_add_days($week_start, 7), _add_days($week_start, 14)) if $shortcut eq 'next_week';
    return ($month_start, _add_months($month_start, 1)) if $shortcut eq 'this_month';
    return (_add_months($month_start, -1), $month_start) if $shortcut eq 'last_month';
    return (_add_months($month_start, 1), _add_months($month_start, 2)) if $shortcut eq 'next_month';
    return ($month_start, $tomorrow) if $shortcut eq 'mtd';
    return ($quarter_start, _add_months($quarter_start, 3)) if $shortcut eq 'this_quarter';
    return (_add_months($quarter_start, -3), $quarter_start) if $shortcut eq 'last_quarter';
    return (_add_months($quarter_start, 3), _add_months($quarter_start, 6))
        if $shortcut eq 'next_quarter';
    return ($quarter_start, $tomorrow) if $shortcut eq 'qtd';
    return ($year_start, sprintf('%04d-01-01', $year + 1)) if $shortcut eq 'this_year';
    return (sprintf('%04d-01-01', $year - 1), $year_start) if $shortcut eq 'last_year';
    return (sprintf('%04d-01-01', $year + 1), sprintf('%04d-01-01', $year + 2))
        if $shortcut eq 'next_year';
    return ($year_start, $tomorrow) if $shortcut eq 'ytd';
    return (_add_days($today, -6), $tomorrow) if $shortcut eq 'last_7_days';
    return (_add_days($today, -29), $tomorrow) if $shortcut eq 'last_30_days';
    return (_add_days($today, -89), $tomorrow) if $shortcut eq 'last_90_days';
    return ($tomorrow, _add_days($today, 8)) if $shortcut eq 'next_7_days';
    return ($tomorrow, _add_days($today, 31)) if $shortcut eq 'next_30_days';
    die "date shortcut is not available\n";
}

sub _epoch {
    my ($date) = @_;
    my ($year, $month, $day) = "$date" =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
    return timegm(0, 0, 12, $day, $month - 1, $year);
}

sub _add_days {
    my ($date, $days) = @_;
    return strftime('%Y-%m-%d', gmtime(_epoch($date) + $days * 86_400));
}

sub _add_months {
    my ($date, $months) = @_;
    my ($year, $month) = "$date" =~ /\A(\d{4})-(\d{2})/;
    my $offset = $year * 12 + ($month - 1) + $months;
    my $target_year = int($offset / 12);
    my $target_month = $offset % 12 + 1;
    return sprintf('%04d-%02d-01', $target_year, $target_month);
}

1;
