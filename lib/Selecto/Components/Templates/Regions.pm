package Selecto::Components::Templates::Regions;

use 5.034;
use strict;
use warnings;

sub for_event {
    my ($class, $manifest, $event_name) = @_;
    return [] unless ref($manifest) eq 'HASH' && ref($manifest->{events}) eq 'ARRAY';
    my ($event) = grep {
        ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} eq $event_name
    } @{$manifest->{events}};
    return [] unless $event && ref($event->{actions}) eq 'ARRAY';
    my %changed;
    for my $action (@{$event->{actions}}) {
        next unless ref($action) eq 'HASH';
        $changed{"state:$action->{state}"} = 1
            if ($action->{kind} // '') eq 'set_state' && defined($action->{state});
        $changed{"source:$action->{source}"} = 1
            if ($action->{kind} // '') eq 'reload_source' && defined($action->{source});
    }
    $changed{"event:$_->{name}"} = 1 for grep {
        ref($_) eq 'HASH' && defined($_->{name}) && !ref($_->{name})
    } @{$manifest->{events}};
    return _matching($manifest, \%changed);
}

sub for_source {
    my ($class, $manifest, $source_id) = @_;
    return [] unless defined($source_id) && !ref($source_id);
    my %changed = ("source:$source_id" => 1);
    if (ref($manifest) eq 'HASH' && ref($manifest->{events}) eq 'ARRAY') {
        $changed{"event:$_->{name}"} = 1 for grep {
            ref($_) eq 'HASH' && defined($_->{name}) && !ref($_->{name})
        } @{$manifest->{events}};
    }
    return _matching($manifest, \%changed);
}

sub _matching {
    my ($manifest, $changed) = @_;
    my $nodes = ref($manifest) eq 'HASH' && ref($manifest->{view}) eq 'HASH'
        ? $manifest->{view}{nodes} : undef;
    return [] unless ref($nodes) eq 'ARRAY' && %$changed;
    return [map { "$_->{node_id}" } grep {
        my %dependencies;
        _dependencies($_, \%dependencies);
        scalar grep { $changed->{$_} } keys %dependencies;
    } @$nodes];
}

sub _dependencies {
    my ($value, $dependencies) = @_;
    if (ref($value) eq 'ARRAY') {
        _dependencies($_, $dependencies) for @$value;
        return;
    }
    return unless ref($value) eq 'HASH';
    if (ref($value->{events}) eq 'HASH') {
        for my $event (values %{$value->{events}}) {
            $dependencies->{"event:$event"} = 1
                if defined($event) && !ref($event);
        }
    }
    if (defined($value->{expression}) && !ref($value->{expression})) {
        my $expression = $value->{expression};
        $dependencies->{"state:$1"} = 1
            if $expression =~ /(?:\A|\()state\.([A-Za-z_][A-Za-z0-9_]*)/;
        $dependencies->{"source:$1"} = 1
            if $expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.rows\z/;
        $dependencies->{"source:$1"} = 1
            if ($value->{kind} // '') eq 'binding'
            && ($value->{type} // '') eq 'source'
            && $expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/;
    }
    _dependencies($_, $dependencies) for values %$value;
}

1;
