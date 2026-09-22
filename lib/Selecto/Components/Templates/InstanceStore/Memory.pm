package Selecto::Components::Templates::InstanceStore::Memory;

use 5.034;
use strict;
use warnings;

use JSON::PP ();
use Storable qw(dclone);
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    my $max_snapshot_bytes = $args{max_snapshot_bytes} // 1_048_576;
    my $max_owner_scope_bytes = $args{max_owner_scope_bytes} // 4_096;
    my $max_ttl_seconds = $args{max_ttl_seconds} // 86_400;
    my $max_effect_lease_seconds = $args{max_effect_lease_seconds} // 60;
    _positive_integer('max_snapshot_bytes', $max_snapshot_bytes, 16_777_216);
    _positive_integer('max_owner_scope_bytes', $max_owner_scope_bytes, 65_536);
    _positive_integer('max_ttl_seconds', $max_ttl_seconds, 2_592_000);
    _positive_integer('max_effect_lease_seconds', $max_effect_lease_seconds, 300);
    return bless {
        clock => $args{clock} // sub { time() },
        id_generator => $args{id_generator} // \&_opaque_id,
        claim_token_generator => $args{claim_token_generator} // \&_opaque_id,
        max_snapshot_bytes => 0 + $max_snapshot_bytes,
        max_owner_scope_bytes => 0 + $max_owner_scope_bytes,
        max_ttl_seconds => 0 + $max_ttl_seconds,
        max_effect_lease_seconds => 0 + $max_effect_lease_seconds,
        json => JSON::PP->new->canonical(1)->ascii(1)->allow_nonref(1),
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
    my $scope_key = $self->_scope_key($args{owner_scope});
    my $release = $args{release};
    my $snapshot = $args{initial_snapshot};
    my $expires_at = $args{expires_at};
    my $instance_id = $args{instance_id} // $self->new_instance_id;

    my $now = $self->{clock}->();
    die "invalid_instance: template instance fields are invalid\n"
        unless _valid_scalar($release, 256)
        && ref($snapshot) eq 'HASH'
        && defined($expires_at) && !ref($expires_at)
        && "$expires_at" =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/
        && $expires_at > $now
        && $expires_at <= $now + $self->{max_ttl_seconds}
        && _valid_scalar($instance_id, 256);
    die "instance_exists: template instance ID already exists\n"
        if exists $self->{instances}{$instance_id};
    die "invalid_snapshot: snapshot identity does not match the stored instance\n"
        unless _snapshot_matches($snapshot, $instance_id, $release);
    $self->_validate_snapshot($snapshot);

    $self->{instances}{$instance_id} = {
        owner_scope => $scope_key,
        release => "$release",
        snapshot => dclone($snapshot),
        revision => 0,
        expires_at => 0 + $expires_at,
        effect_claims => {},
    };
    return "$instance_id";
}

sub load {
    my ($self, %args) = @_;
    my $scope_key = $self->_scope_key($args{owner_scope});
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
    $self->_validate_snapshot($snapshot);

    my $record = $self->{instances}{$args{instance_id}};
    $record->{snapshot} = dclone($snapshot);
    $record->{revision}++;
    return {status => 'ok', revision => $record->{revision}};
}

sub claim_effect {
    my ($self, %args) = @_;
    my $validated = $self->_claim_args(\%args);
    return $validated unless $validated->{status} eq 'ok';

    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    return {status => 'stale'}
        unless _effect_is_current($loaded->{snapshot}, \%args);

    my $record = $self->{instances}{$args{instance_id}};
    my $key = _claim_key($args{source}, $args{generation});
    my $now = $self->{clock}->();
    _prune_expired_claims($record, $now);
    my $current = $record->{effect_claims}{$key};
    return {
        status => 'busy',
        lease_expires_at => $current->{lease_expires_at},
    } if $current && $current->{lease_expires_at} > $now;

    my $claim_token = $self->{claim_token_generator}->();
    die "claim_token_unavailable: could not allocate a template effect claim token\n"
        unless _valid_scalar($claim_token, 256);
    my $lease_expires_at = $now + $validated->{lease_seconds};
    $lease_expires_at = $record->{expires_at}
        if $lease_expires_at > $record->{expires_at};
    $record->{effect_claims}{$key} = {
        effect_id => "$args{effect_id}",
        claim_token => "$claim_token",
        lease_expires_at => $lease_expires_at,
    };
    return {
        status => 'claimed',
        claim_token => "$claim_token",
        lease_expires_at => $lease_expires_at,
    };
}

sub commit_claimed_effect {
    my ($self, %args) = @_;
    return {status => 'invalid_claim'}
        unless _valid_claim_identity(\%args)
        && defined($args{revision}) && !ref($args{revision})
        && "$args{revision}" =~ /\A[0-9]+\z/
        && _valid_scalar($args{claim_token}, 256);

    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    my $record = $self->{instances}{$args{instance_id}};
    my $key = _claim_key($args{source}, $args{generation});
    my $claim = $record->{effect_claims}{$key};
    return {status => 'claim_lost'}
        unless $claim
        && $claim->{claim_token} eq "$args{claim_token}"
        && $claim->{lease_expires_at} > $self->{clock}->();
    return {status => 'conflict', revision => $loaded->{revision}}
        unless $args{revision} == $loaded->{revision};

    my $snapshot = $args{next_snapshot};
    return {status => 'invalid_snapshot'}
        unless ref($snapshot) eq 'HASH'
        && _snapshot_matches($snapshot, $args{instance_id}, $loaded->{release});
    $self->_validate_snapshot($snapshot);
    $record->{snapshot} = dclone($snapshot);
    $record->{revision}++;
    delete $record->{effect_claims}{$key};
    return {status => 'ok', revision => $record->{revision}};
}

sub release_effect_claim {
    my ($self, %args) = @_;
    return {status => 'invalid_claim'}
        unless _valid_claim_identity(\%args)
        && _valid_scalar($args{claim_token}, 256);
    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';

    my $record = $self->{instances}{$args{instance_id}};
    my $key = _claim_key($args{source}, $args{generation});
    my $claim = $record->{effect_claims}{$key};
    return {status => 'claim_lost'}
        unless $claim && $claim->{claim_token} eq "$args{claim_token}";
    delete $record->{effect_claims}{$key};
    return {status => 'ok'};
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

sub _claim_args {
    my ($self, $args) = @_;
    return {status => 'invalid_effect'} unless _valid_claim_identity($args);
    my $lease_seconds = $args->{lease_seconds} // $self->{max_effect_lease_seconds};
    return {status => 'invalid_lease'}
        unless defined($lease_seconds) && !ref($lease_seconds)
        && "$lease_seconds" =~ /\A[1-9][0-9]*\z/
        && $lease_seconds <= $self->{max_effect_lease_seconds};
    return {status => 'ok', lease_seconds => 0 + $lease_seconds};
}

sub _valid_claim_identity {
    my ($args) = @_;
    return _valid_scalar($args->{instance_id}, 256)
        && _valid_scalar($args->{source}, 256)
        && defined($args->{generation}) && !ref($args->{generation})
        && "$args->{generation}" =~ /\A[1-9][0-9]*\z/
        && _valid_scalar($args->{effect_id}, 768)
        && "$args->{effect_id}" eq
            "$args->{instance_id}:source:$args->{source}:$args->{generation}";
}

sub _effect_is_current {
    my ($snapshot, $args) = @_;
    my $source = ref($snapshot->{sources}) eq 'HASH'
        ? $snapshot->{sources}{$args->{source}} : undef;
    return ref($source) eq 'HASH'
        && defined($source->{generation}) && !ref($source->{generation})
        && $source->{generation} == $args->{generation}
        && ($source->{status} // '') eq 'loading';
}

sub _claim_key { return "$_[0]\0$_[1]" }

sub _prune_expired_claims {
    my ($record, $now) = @_;
    for my $key (keys %{$record->{effect_claims}}) {
        delete $record->{effect_claims}{$key}
            if $record->{effect_claims}{$key}{lease_expires_at} <= $now;
    }
}

sub _scope_key {
    my ($self, $owner_scope) = @_;
    die "invalid_owner_scope: template owner scope must be a non-empty object\n"
        unless ref($owner_scope) eq 'HASH' && keys(%$owner_scope);
    my $json = eval { $self->{json}->encode($owner_scope) };
    die "invalid_owner_scope: template owner scope must be canonical JSON data\n" if $@;
    die "invalid_owner_scope: template owner scope exceeds the storage budget\n"
        if length($json) > $self->{max_owner_scope_bytes};
    return $json;
}

sub _validate_snapshot {
    my ($self, $snapshot) = @_;
    die "invalid_snapshot: template snapshot must be an object\n"
        unless ref($snapshot) eq 'HASH';
    my $json = eval { $self->{json}->encode($snapshot) };
    die "invalid_snapshot: template snapshot must be canonical JSON data\n" if $@;
    die "snapshot_too_large: template snapshot exceeds the storage budget\n"
        if length($json) > $self->{max_snapshot_bytes};
}

sub _snapshot_matches {
    my ($snapshot, $instance_id, $release) = @_;
    return defined($snapshot->{instance_id}) && !ref($snapshot->{instance_id})
        && "$snapshot->{instance_id}" eq "$instance_id"
        && defined($snapshot->{release_id}) && !ref($snapshot->{release_id})
        && "$snapshot->{release_id}" eq "$release";
}

sub _valid_scalar {
    my ($value, $max_bytes) = @_;
    return defined($value) && !ref($value) && length("$value")
        && length("$value") <= $max_bytes;
}

sub _positive_integer {
    my ($name, $value, $maximum) = @_;
    die "invalid_limit: $name must be an integer between 1 and $maximum\n"
        unless defined($value) && !ref($value) && "$value" =~ /\A[1-9][0-9]*\z/
        && $value <= $maximum;
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
