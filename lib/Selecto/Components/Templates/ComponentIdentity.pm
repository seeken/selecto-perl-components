package Selecto::Components::Templates::ComponentIdentity;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);

sub descriptor {
    my ($class, %args) = @_;
    my $manifest = $args{manifest};
    my $snapshot = $args{snapshot};
    my $component_id = $args{component_id};
    my $event = $args{event};
    die "invalid_event_component: template event component is invalid\n"
        unless _valid_context($manifest, $snapshot, $component_id, $event);
    my $form_revision = $snapshot->{state_revision};
    return {
        component_id => "$component_id",
        component_lifetime => _lifetime(
            $snapshot, $component_id, $form_revision,
        ),
        form_revision => 0 + $form_revision,
    };
}

sub validate {
    my ($class, %args) = @_;
    my $manifest = $args{manifest};
    my $snapshot = $args{snapshot};
    my $component_id = $args{component_id};
    my $event = $args{event};
    return {
        status => 'error', code => 'invalid_event_component',
        message => 'Template event component is invalid.',
    } unless _valid_context($manifest, $snapshot, $component_id, $event);
    my $form_revision = $args{form_revision};
    return {
        status => 'conflict', code => 'stale_form_revision',
        message => 'Template form is stale. Reload and try again.',
    } unless defined($form_revision) && !ref($form_revision)
        && "$form_revision" =~ /\A[0-9]+\z/
        && defined($args{state_revision}) && !ref($args{state_revision})
        && "$args{state_revision}" =~ /\A[0-9]+\z/
        && $form_revision == $args{state_revision};
    my $expected = _lifetime($snapshot, $component_id, $form_revision);
    return {
        status => 'conflict', code => 'stale_component_lifetime',
        message => 'Template component is stale. Reload and try again.',
    } unless defined($args{component_lifetime})
        && !ref($args{component_lifetime})
        && "$args{component_lifetime}" eq $expected;
    return {
        status => 'ok', component_id => "$component_id",
        component_lifetime => $expected,
        form_revision => 0 + $form_revision,
    };
}

sub _valid_context {
    my ($manifest, $snapshot, $component_id, $event) = @_;
    return 0 unless ref($manifest) eq 'HASH'
        && ref($manifest->{view}) eq 'HASH'
        && ref($manifest->{view}{nodes}) eq 'ARRAY'
        && ref($snapshot) eq 'HASH'
        && _scalar($snapshot->{instance_id}, 256)
        && _scalar($snapshot->{release_id}, 256)
        && defined($snapshot->{state_revision}) && !ref($snapshot->{state_revision})
        && "$snapshot->{state_revision}" =~ /\A[0-9]+\z/
        && _component_id($component_id) && _scalar($event, 128);
    return _declares_event($manifest->{view}{nodes}, $component_id, $event);
}

sub _declares_event {
    my ($nodes, $component_id, $event) = @_;
    for my $node (@$nodes) {
        next unless ref($node) eq 'HASH';
        if (($node->{kind} // '') eq 'component'
            && ($node->{node_id} // '') eq $component_id
            && ref($node->{events}) eq 'HASH'
            && grep { defined($_) && !ref($_) && $_ eq $event }
                values %{$node->{events}}) {
            return 1;
        }
        for my $key (qw(children then else)) {
            return 1 if ref($node->{$key}) eq 'ARRAY'
                && _declares_event($node->{$key}, $component_id, $event);
        }
    }
    return 0;
}

sub _lifetime {
    my ($snapshot, $component_id, $form_revision) = @_;
    my @sources = map {
        my $source = $snapshot->{sources}{$_};
        my $generation = ref($source) eq 'HASH'
            && defined($source->{generation}) && !ref($source->{generation})
            ? $source->{generation} : '';
        my $status = ref($source) eq 'HASH'
            && defined($source->{status}) && !ref($source->{status})
            ? $source->{status} : '';
        ($_ , $generation, $status)
    } sort keys %{ref($snapshot->{sources}) eq 'HASH' ? $snapshot->{sources} : {}};
    return sha256_hex(join "\0",
        'selecto.template.component-lifetime.v1',
        $snapshot->{instance_id}, $snapshot->{release_id},
        $component_id, $form_revision, @sources,
    );
}

sub _component_id {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && "$value" =~ /\A[A-Za-z0-9_.:-]{1,512}\z/;
}

sub _scalar {
    my ($value, $max) = @_;
    return defined($value) && !ref($value) && length("$value")
        && length("$value") <= $max;
}

1;
