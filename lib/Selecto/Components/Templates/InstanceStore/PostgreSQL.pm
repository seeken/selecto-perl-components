package Selecto::Components::Templates::InstanceStore::PostgreSQL;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Time::HiRes qw(time);

our $DEFAULT_TABLE = 'selecto_template_instances';

sub new {
    my ($class, %args) = @_;
    die "invalid_database: dbh_provider must be a coderef\n"
        unless ref($args{dbh_provider}) eq 'CODE';

    my $table = $args{table} // $DEFAULT_TABLE;
    my $max_snapshot_bytes = $args{max_snapshot_bytes} // 1_048_576;
    my $max_owner_scope_bytes = $args{max_owner_scope_bytes} // 4_096;
    my $max_ttl_seconds = $args{max_ttl_seconds} // 86_400;
    my $cleanup_limit = $args{cleanup_limit} // 1_000;

    _positive_integer('max_snapshot_bytes', $max_snapshot_bytes, 16_777_216);
    _positive_integer('max_owner_scope_bytes', $max_owner_scope_bytes, 65_536);
    _positive_integer('max_ttl_seconds', $max_ttl_seconds, 2_592_000);
    _positive_integer('cleanup_limit', $cleanup_limit, 10_000);

    return bless {
        dbh_provider => $args{dbh_provider},
        table => _qualified_identifier($table),
        index => _quoted_identifier(_index_name($table)),
        clock => $args{clock} // sub { time() },
        id_generator => $args{id_generator} // \&_opaque_id,
        max_snapshot_bytes => 0 + $max_snapshot_bytes,
        max_owner_scope_bytes => 0 + $max_owner_scope_bytes,
        max_ttl_seconds => 0 + $max_ttl_seconds,
        cleanup_limit => 0 + $cleanup_limit,
        json => JSON::PP->new->canonical(1)->ascii(1)->allow_nonref(1),
    }, $class;
}

sub schema_sql {
    my ($self) = @_;
    my $table = $self->{table};
    my $index = $self->{index};
    return (
        qq{CREATE TABLE IF NOT EXISTS $table (
            instance_id text PRIMARY KEY,
            owner_scope_digest text NOT NULL,
            release_id text NOT NULL,
            snapshot jsonb NOT NULL,
            revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
            expires_at timestamptz NOT NULL,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
        )},
        qq{CREATE INDEX IF NOT EXISTS $index ON $table (expires_at)},
    );
}

sub install_schema {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    $dbh->do($_) for $self->schema_sql;
    return 1;
}

sub new_instance_id {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $sql = qq{SELECT 1 FROM $self->{table} WHERE instance_id = ?};

    for (1 .. 8) {
        my $id = $self->{id_generator}->();
        next unless _valid_scalar($id, 256);
        return "$id" unless $dbh->selectrow_array($sql, undef, "$id");
    }
    die "instance_id_unavailable: could not allocate a unique template instance ID\n";
}

sub create {
    my ($self, %args) = @_;
    my $scope_digest = $self->_scope_digest($args{owner_scope});
    my $release = $args{release};
    my $snapshot = $args{initial_snapshot};
    my $expires_at = $args{expires_at};
    my $instance_id = $args{instance_id} // $self->new_instance_id;
    my $now = $self->{clock}->();

    die "invalid_instance: template instance fields are invalid\n"
        unless _valid_scalar($release, 256)
        && _valid_scalar($instance_id, 256)
        && defined($expires_at) && !ref($expires_at)
        && "$expires_at" =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/
        && $expires_at > $now
        && $expires_at <= $now + $self->{max_ttl_seconds};
    die "invalid_snapshot: snapshot identity does not match the stored instance\n"
        unless _snapshot_matches($snapshot, $instance_id, $release);

    my $snapshot_json = $self->_snapshot_json($snapshot);
    my $sql = qq{
        INSERT INTO $self->{table}
            (instance_id, owner_scope_digest, release_id, snapshot, revision, expires_at)
        VALUES (?, ?, ?, ?::jsonb, 0, to_timestamp(?))
    };
    $self->_dbh->do(
        $sql, undef, "$instance_id", $scope_digest, "$release", $snapshot_json,
        0 + $expires_at,
    );
    return "$instance_id";
}

sub load {
    my ($self, %args) = @_;
    my $scope_digest = $self->_scope_digest($args{owner_scope});
    my $instance_id = $args{instance_id};
    return {status => 'not_found'} unless _valid_scalar($instance_id, 256);

    my $dbh = $self->_dbh;
    my $record = $dbh->selectrow_hashref(qq{
        SELECT release_id, snapshot::text AS snapshot, revision,
               extract(epoch FROM expires_at) AS expires_at,
               CASE WHEN expires_at <= clock_timestamp() THEN 1 ELSE 0 END AS expired
          FROM $self->{table}
         WHERE instance_id = ? AND owner_scope_digest = ?
    }, undef, "$instance_id", $scope_digest);
    return {status => 'not_found'} unless $record;

    if ($record->{expired}) {
        $dbh->do(qq{
            DELETE FROM $self->{table}
             WHERE instance_id = ? AND owner_scope_digest = ?
               AND expires_at <= clock_timestamp()
        }, undef, "$instance_id", $scope_digest);
        return {status => 'expired'};
    }

    return {
        status => 'ok',
        release => "$record->{release_id}",
        snapshot => $self->{json}->decode($record->{snapshot}),
        revision => 0 + $record->{revision},
        expires_at => 0 + $record->{expires_at},
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
        && "$args{revision}" =~ /\A[0-9]+\z/
        && $args{revision} == $loaded->{revision};

    my $snapshot = $args{next_snapshot};
    return {status => 'invalid_snapshot'}
        unless _snapshot_matches($snapshot, $args{instance_id}, $loaded->{release});
    my $snapshot_json = $self->_snapshot_json($snapshot);
    my $scope_digest = $self->_scope_digest($args{owner_scope});

    my $updated = $self->_dbh->selectrow_hashref(qq{
        UPDATE $self->{table}
           SET snapshot = ?::jsonb,
               revision = revision + 1,
               updated_at = clock_timestamp()
         WHERE instance_id = ?
           AND owner_scope_digest = ?
           AND release_id = ?
           AND revision = ?
           AND expires_at > clock_timestamp()
     RETURNING revision
    }, undef, $snapshot_json, "$args{instance_id}", $scope_digest,
        $loaded->{release}, 0 + $args{revision});
    return {status => 'ok', revision => 0 + $updated->{revision}} if $updated;

    my $current = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $current unless $current->{status} eq 'ok';
    return {status => 'conflict', revision => $current->{revision}};
}

sub dispose {
    my ($self, %args) = @_;
    my $scope_digest = $self->_scope_digest($args{owner_scope});
    my $instance_id = $args{instance_id};
    return {status => 'not_found'} unless _valid_scalar($instance_id, 256);

    my $deleted = $self->_dbh->selectrow_hashref(qq{
        DELETE FROM $self->{table}
         WHERE instance_id = ?
           AND owner_scope_digest = ?
           AND expires_at > clock_timestamp()
     RETURNING instance_id
    }, undef, "$instance_id", $scope_digest);
    return {status => 'ok'} if $deleted;
    return $self->load(owner_scope => $args{owner_scope}, instance_id => $instance_id);
}

sub cleanup_expired {
    my ($self, %args) = @_;
    my $limit = $args{limit} // $self->{cleanup_limit};
    _positive_integer('cleanup limit', $limit, $self->{cleanup_limit});

    my $statement = $self->_dbh->prepare(qq{
        WITH doomed AS (
            SELECT instance_id
              FROM $self->{table}
             WHERE expires_at <= clock_timestamp()
             ORDER BY expires_at, instance_id
             LIMIT ?
        )
        DELETE FROM $self->{table} AS instances
         USING doomed
         WHERE instances.instance_id = doomed.instance_id
     RETURNING instances.instance_id
    });
    $statement->execute(0 + $limit);
    my $rows = $statement->fetchall_arrayref;
    return scalar(@$rows);
}

sub _dbh {
    my ($self) = @_;
    my $dbh = $self->{dbh_provider}->();
    die "instance_store_unavailable: database handle is unavailable\n"
        unless ref($dbh) && $dbh->can('do') && $dbh->can('prepare')
        && $dbh->can('selectrow_array') && $dbh->can('selectrow_hashref');
    return $dbh;
}

sub _scope_digest {
    my ($self, $owner_scope) = @_;
    die "invalid_owner_scope: template owner scope must be a non-empty object\n"
        unless ref($owner_scope) eq 'HASH' && keys(%$owner_scope);
    my $json = eval { $self->{json}->encode($owner_scope) };
    die "invalid_owner_scope: template owner scope must be canonical JSON data\n" if $@;
    die "invalid_owner_scope: template owner scope exceeds the storage budget\n"
        if length($json) > $self->{max_owner_scope_bytes};
    return sha256_hex($json);
}

sub _snapshot_json {
    my ($self, $snapshot) = @_;
    die "invalid_snapshot: template snapshot must be an object\n"
        unless ref($snapshot) eq 'HASH';
    my $json = eval { $self->{json}->encode($snapshot) };
    die "invalid_snapshot: template snapshot must be canonical JSON data\n" if $@;
    die "snapshot_too_large: template snapshot exceeds the storage budget\n"
        if length($json) > $self->{max_snapshot_bytes};
    return $json;
}

sub _snapshot_matches {
    my ($snapshot, $instance_id, $release) = @_;
    return ref($snapshot) eq 'HASH'
        && defined($snapshot->{instance_id}) && !ref($snapshot->{instance_id})
        && "$snapshot->{instance_id}" eq "$instance_id"
        && defined($snapshot->{release_id}) && !ref($snapshot->{release_id})
        && "$snapshot->{release_id}" eq "$release";
}

sub _qualified_identifier {
    my ($value) = @_;
    die "invalid_table: PostgreSQL instance-store table is invalid\n"
        unless defined($value) && !ref($value);
    my @parts = split /\./, "$value", -1;
    die "invalid_table: PostgreSQL instance-store table is invalid\n"
        unless @parts >= 1 && @parts <= 2
        && !grep { $_ !~ /\A[a-z_][a-z0-9_]*\z/ || length($_) > 63 } @parts;
    return join '.', map { _quoted_identifier($_) } @parts;
}

sub _quoted_identifier {
    my ($value) = @_;
    return qq{"$value"};
}

sub _index_name {
    my ($table) = @_;
    my ($name) = "$table" =~ /([^.]+)\z/;
    my $suffix = '_expires_at_idx';
    $name = substr($name, 0, 63 - length($suffix));
    return $name . $suffix;
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

=head1 NAME

Selecto::Components::Templates::InstanceStore::PostgreSQL - shared template runtime state

=head1 DESCRIPTION

Stores bounded template snapshots in PostgreSQL for request handling across workers.
Owner scope is canonicalized and stored only as a SHA-256 digest. Revision updates
use one conditional C<UPDATE>, so stale writers receive a conflict without replacing
newer state. Expiry uses the database clock and cleanup is explicitly bounded.

The host owns connection pooling and schema migration. C<dbh_provider> must return a
DBI-compatible PostgreSQL handle for the current worker. C<install_schema> is a
development/test convenience; production hosts should apply C<schema_sql> through
their migration system.

=cut

1;
