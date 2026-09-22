package Selecto::Components::Templates::InstanceStore::Memory;

use 5.034;
use strict;
use warnings;

use JSON::PP ();
use Storable qw(dclone);
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    return bless {
        clock => $args{clock} // sub { time() },
        id_generator => $args{id_generator} // \&_opaque_id,
        instances => {},
    }, $class;
}

sub new_instance_id {
    my ($self) = @_;
    for (1 .. 8) {
        my $id = $self->{id_generator}->();
        next unless defined($id) && !ref($id) && length($id);
        return "$id" unless exists $self->{instances}{$id};
    }
    die "instance_id_unavailable: could not allocate a unique template instance ID\n";
}

sub create {
    my ($self, %args) = @_;
    my $scope_key = _scope_key($args{owner_scope});
    my $release = $args{release};
    my $snapshot = $args{initial_snapshot};
    my $expires_at = $args{expires_at};
    my $instance_id = $args{instance_id} // $self->new_instance_id;

    die "invalid_instance: template instance fields are invalid\n"
        unless defined($release) && !ref($release) && length("$release")
        && ref($snapshot) eq 'HASH'
        && defined($expires_at) && !ref($expires_at) && $expires_at > $self->{clock}->()
        && defined($instance_id) && !ref($instance_id) && length("$instance_id");
    die "instance_exists: template instance ID already exists\n"
        if exists $self->{instances}{$instance_id};
    die "invalid_snapshot: snapshot identity does not match the stored instance\n"
        unless _snapshot_matches($snapshot, $instance_id, $release);

    $self->{instances}{$instance_id} = {
        owner_scope => $scope_key,
        release => "$release",
        snapshot => dclone($snapshot),
        revision => 0,
        expires_at => 0 + $expires_at,
    };
    return "$instance_id";
}

sub load {
    my ($self, %args) = @_;
    my $scope_key = _scope_key($args{owner_scope});
    my $instance_id = $args{instance_id};
    return {status => 'not_found'}
        unless defined($instance_id) && !ref($instance_id)
        && exists $self->{instances}{$instance_id};

    my $record = $self->{instances}{$instance_id};
    return {status => 'not_found'} unless $record->{owner_scope} eq $scope_key;
    if ($record->{expires_at} <= $self->{clock}->()) {
        delete $self->{instances}{$instance_id};
        return {status => 'expired'};
    }

    return {
        status => 'ok',
        release => $record->{release},
        snapshot => dclone($record->{snapshot}),
        revision => $record->{revision},
        expires_at => $record->{expires_at},
    };
}

sub compare_and_set {
    my ($self, %args) = @_;
    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    return {status => 'conflict', revision => $loaded->{revision}}
        unless defined($args{revision}) && !ref($args{revision})
        && $args{revision} =~ /\A[0-9]+\z/
        && $args{revision} == $loaded->{revision};

    my $snapshot = $args{next_snapshot};
    return {status => 'invalid_snapshot'}
        unless ref($snapshot) eq 'HASH'
        && _snapshot_matches($snapshot, $args{instance_id}, $loaded->{release});

    my $record = $self->{instances}{$args{instance_id}};
    $record->{snapshot} = dclone($snapshot);
    $record->{revision}++;
    return {status => 'ok', revision => $record->{revision}};
}

sub dispose {
    my ($self, %args) = @_;
    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    delete $self->{instances}{$args{instance_id}};
    return {status => 'ok'};
}

sub _scope_key {
    my ($owner_scope) = @_;
    die "invalid_owner_scope: template owner scope must be a non-empty object\n"
        unless ref($owner_scope) eq 'HASH' && keys(%$owner_scope);
    return JSON::PP->new->canonical(1)->allow_nonref(1)->encode($owner_scope);
}

sub _snapshot_matches {
    my ($snapshot, $instance_id, $release) = @_;
    return defined($snapshot->{instance_id}) && !ref($snapshot->{instance_id})
        && "$snapshot->{instance_id}" eq "$instance_id"
        && defined($snapshot->{release_id}) && !ref($snapshot->{release_id})
        && "$snapshot->{release_id}" eq "$release";
}

sub _opaque_id {
    open my $random, '<:raw', '/dev/urandom'
        or die "instance_id_unavailable: secure random source is unavailable\n";
    my $bytes = '';
    my $read = read($random, $bytes, 32);
    close $random;
    die "instance_id_unavailable: secure random source is unavailable\n"
        unless defined($read) && $read == 32;
    return unpack('H*', $bytes);
}

1;
