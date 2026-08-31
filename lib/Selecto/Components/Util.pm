package Selecto::Components::Util;

use 5.034;
use strict;
use warnings;
use Exporter 'import';
use Mojo::Util qw(xml_escape);

our @EXPORT_OK = qw(humanize html_escape trim);

sub html_escape {
    my ($value) = @_;
    return xml_escape(defined($value) ? "$value" : '');
}

sub humanize {
    my ($value) = @_;
    my $text = defined($value) ? "$value" : '';
    $text =~ s/[._-]+/ /g;
    $text =~ s/\b([a-z])/uc($1)/eg;
    return $text;
}

sub trim {
    my ($value) = @_;
    $value = defined($value) && !ref($value) ? "$value" : '';
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

1;
