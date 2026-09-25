package Selecto::Components::Templates::InstanceStore::PostgreSQL;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Time::HiRes qw(time);

our $DEFAULT_TABLE = 'selecto_template_instances';
our $DEFAULT_MAX_INSTANCES_PER_OWNER = 32;
our $MAX_INSTANCES_PER_OWNER_LIMIT = 10_000;

sub new {
    my ($class, %args) = @_;
    die "invalid_database: dbh_provider must be a coderef\n"
        unless ref($args{dbh_provider}) eq 'CODE';

    my $table = $args{table} // $DEFAULT_TABLE;
    my $max_snapshot_bytes = $args{max_snapshot_bytes} // 1_048_576;
    my $max_owner_scope_bytes = $args{max_owner_scope_bytes} // 4_096;
    my $max_ttl_seconds = $args{max_ttl_seconds} // 86_400;
    my $max_effect_lease_seconds = $args{max_effect_lease_seconds} // 60;
    my $cleanup_limit = $args{cleanup_limit} // 1_000;
    my $max_instances_per_owner = $args{max_instances_per_owner}
        // $DEFAULT_MAX_INSTANCES_PER_OWNER;
    my $claims_table = $args{claims_table} // _claims_table_name($table);

    _positive_integer('max_snapshot_bytes', $max_snapshot_bytes, 16_777_216);
    _positive_integer('max_owner_scope_bytes', $max_owner_scope_bytes, 65_536);
    _positive_integer('max_ttl_seconds', $max_ttl_seconds, 2_592_000);
    _positive_integer('max_effect_lease_seconds', $max_effect_lease_seconds, 300);
    _positive_integer('cleanup_limit', $cleanup_limit, 10_000);
    _positive_integer(
        'max_instances_per_owner', $max_instances_per_owner,
        $MAX_INSTANCES_PER_OWNER_LIMIT,
    );

    return bless {
        dbh_provider => $args{dbh_provider},
        table => _qualified_identifier($table),
        index => _quoted_identifier(_index_name($table, '_expires_at_idx')),
        owner_index => _quoted_identifier(_index_name($table, '_owner_created_idx')),
        claims_table => _qualified_identifier($claims_table),
        claims_index => _quoted_identifier(
            _index_name($claims_table, '_lease_expires_at_idx')
        ),
        clock => $args{clock} // sub { time() },
        id_generator => $args{id_generator} // \&_opaque_id,
        claim_token_generator => $args{claim_token_generator} // \&_opaque_id,
        max_snapshot_bytes => 0 + $max_snapshot_bytes,
        max_owner_scope_bytes => 0 + $max_owner_scope_bytes,
        max_ttl_seconds => 0 + $max_ttl_seconds,
        max_effect_lease_seconds => 0 + $max_effect_lease_seconds,
        cleanup_limit => 0 + $cleanup_limit,
        max_instances_per_owner => 0 + $max_instances_per_owner,
        json => JSON::PP->new->canonical(1)->ascii(1)->allow_nonref(1),
    }, $class;
}

sub max_instances_per_owner { return $_[0]{max_instances_per_owner} }

sub schema_sql {
    my ($self) = @_;
    my $table = $self->{table};
    my $index = $self->{index};
    my $owner_index = $self->{owner_index};
    my $claims_table = $self->{claims_table};
    my $claims_index = $self->{claims_index};
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
        qq{CREATE INDEX IF NOT EXISTS $owner_index
            ON $table (owner_scope_digest, created_at)},
        qq{CREATE TABLE IF NOT EXISTS $claims_table (
            instance_id text NOT NULL REFERENCES $table (instance_id) ON DELETE CASCADE,
            source_id text NOT NULL,
            generation bigint NOT NULL CHECK (generation > 0),
            effect_id text NOT NULL,
            claim_token text NOT NULL,
            lease_expires_at timestamptz NOT NULL,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            PRIMARY KEY (instance_id, source_id, generation)
        )},
        qq{CREATE INDEX IF NOT EXISTS $claims_index
            ON $claims_table (lease_expires_at)},
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
    my $max_instances = $args{max_instances_per_owner}
        // $self->{max_instances_per_owner};
    _positive_integer(
        'max_instances_per_owner', $max_instances,
        $MAX_INSTANCES_PER_OWNER_LIMIT,
    );
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
    my $dbh = $self->_dbh;
    $self->_in_transaction($dbh, sub {
        # Serialize mounts for one owner so concurrent requests cannot
        # overshoot the per-owner cap. Other owners are unaffected.
        $dbh->do(
            q{SELECT pg_advisory_xact_lock(hashtextextended(?, 0))},
            undef, "selecto_template_owner:$scope_digest",
        );
        $dbh->do(qq{
            INSERT INTO $self->{table}
                (instance_id, owner_scope_digest, release_id, snapshot, revision, expires_at)
            VALUES (?, ?, ?, ?::jsonb, 0, to_timestamp(?))
        }, undef, "$instance_id", $scope_digest, "$release", $snapshot_json,
            0 + $expires_at);
        # Drop this owner's expired rows and its oldest live rows beyond the cap.
        # Effect claims cascade with their instance.
        $dbh->do(qq{
            WITH eviction_clock AS (
                SELECT clock_timestamp() AS ts
            ), others AS (
                SELECT instances.instance_id,
                       instances.expires_at <= eviction_clock.ts AS expired,
                       row_number() OVER (
                           PARTITION BY instances.expires_at <= eviction_clock.ts
                           ORDER BY instances.created_at DESC,
                                    instances.instance_id DESC
                       ) AS live_rank
                  FROM $self->{table} AS instances, eviction_clock
                 WHERE instances.owner_scope_digest = ?
                   AND instances.instance_id <> ?
            )
            DELETE FROM $self->{table} AS instances
             USING others
             WHERE instances.instance_id = others.instance_id
               AND instances.owner_scope_digest = ?
               AND (others.expired OR others.live_rank > ?)
        }, undef, $scope_digest, "$instance_id", $scope_digest,
            $max_instances - 1);
    });
    return "$instance_id";
}

sub _in_transaction {
    my ($self, $dbh, $work) = @_;
    # A host that already manages a transaction (AutoCommit off) keeps control
    # of commit/rollback; the statements simply join that transaction.
    return $work->() unless $dbh->{AutoCommit};
    $dbh->begin_work;
    my @result;
    my $ok = eval { @result = $work->(); $dbh->commit; 1 };
    unless ($ok) {
        my $error = $@ || 'instance_store_unavailable: transaction failed';
        eval { $dbh->rollback };
        die $error;
    }
    return wantarray ? @result : $result[0];
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

sub claim_effect {
    my ($self, %args) = @_;
    my $validated = $self->_claim_args(\%args);
    return $validated unless $validated->{status} eq 'ok';

    my $scope_digest = $self->_scope_digest($args{owner_scope});
    my $claim_token = $self->{claim_token_generator}->();
    die "claim_token_unavailable: could not allocate a template effect claim token\n"
        unless _valid_scalar($claim_token, 256);

    my $claimed = $self->_dbh->selectrow_hashref(qq{
        INSERT INTO $self->{claims_table} AS claims
            (instance_id, source_id, generation, effect_id, claim_token,
             lease_expires_at)
        SELECT instances.instance_id, ?, ?, ?, ?,
               LEAST(
                   instances.expires_at,
                   clock_timestamp() + (? * interval '1 second')
               )
          FROM $self->{table} AS instances
         WHERE instances.instance_id = ?
           AND instances.owner_scope_digest = ?
           AND instances.expires_at > clock_timestamp()
           AND jsonb_extract_path_text(
                   instances.snapshot, 'sources', ?, 'generation'
               ) = ?
           AND jsonb_extract_path_text(
                   instances.snapshot, 'sources', ?, 'status'
               ) = 'loading'
        ON CONFLICT (instance_id, source_id, generation) DO UPDATE
                SET effect_id = EXCLUDED.effect_id,
                    claim_token = EXCLUDED.claim_token,
                    lease_expires_at = EXCLUDED.lease_expires_at,
                    updated_at = clock_timestamp()
              WHERE claims.lease_expires_at <= clock_timestamp()
        RETURNING claim_token,
                  extract(epoch FROM lease_expires_at) AS lease_expires_at
    }, undef,
        "$args{source}", 0 + $args{generation}, "$args{effect_id}", "$claim_token",
        $validated->{lease_seconds}, "$args{instance_id}", $scope_digest,
        "$args{source}", "$args{generation}", "$args{source}");
    return {
        status => 'claimed',
        claim_token => "$claimed->{claim_token}",
        lease_expires_at => 0 + $claimed->{lease_expires_at},
    } if $claimed;

    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    return {status => 'stale'}
        unless _effect_is_current($loaded->{snapshot}, \%args);

    my $current = $self->_dbh->selectrow_hashref(qq{
        SELECT extract(epoch FROM claims.lease_expires_at) AS lease_expires_at
          FROM $self->{claims_table} AS claims
          JOIN $self->{table} AS instances
            ON instances.instance_id = claims.instance_id
         WHERE claims.instance_id = ?
           AND claims.source_id = ?
           AND claims.generation = ?
           AND instances.owner_scope_digest = ?
           AND claims.lease_expires_at > clock_timestamp()
    }, undef, "$args{instance_id}", "$args{source}", 0 + $args{generation},
        $scope_digest);
    return {
        status => 'busy',
        lease_expires_at => 0 + $current->{lease_expires_at},
    } if $current;
    return {status => 'busy'};
}

sub claim_page_effect {
    my ($self, %args) = @_;
    my $validated = $self->_claim_args(\%args);
    return $validated unless $validated->{status} eq 'ok';
    return {status => 'invalid_effect'}
        unless _valid_scalar($args{page_source}, 256)
        && defined($args{page}) && !ref($args{page})
        && "$args{page}" =~ /\A[1-9][0-9]*\z/
        && "$args{source}" eq "$args{page_source}:page:$args{page}";

    my $scope_digest = $self->_scope_digest($args{owner_scope});
    my $claim_token = $self->{claim_token_generator}->();
    die "claim_token_unavailable: could not allocate a template effect claim token\n"
        unless _valid_scalar($claim_token, 256);

    my $claimed = $self->_dbh->selectrow_hashref(qq{
        INSERT INTO $self->{claims_table} AS claims
            (instance_id, source_id, generation, effect_id, claim_token,
             lease_expires_at)
        SELECT instances.instance_id, ?, ?, ?, ?,
               LEAST(
                   instances.expires_at,
                   clock_timestamp() + (? * interval '1 second')
               )
          FROM $self->{table} AS instances
         WHERE instances.instance_id = ?
           AND instances.owner_scope_digest = ?
           AND instances.expires_at > clock_timestamp()
           AND jsonb_extract_path_text(
                   instances.snapshot, 'sources', ?, 'generation'
               ) = ?
           AND jsonb_extract_path_text(
                   instances.snapshot, 'sources', ?, 'page'
               ) = ?
           AND jsonb_extract_path_text(
                   instances.snapshot, 'sources', ?, 'status'
               ) = 'ready'
        ON CONFLICT (instance_id, source_id, generation) DO UPDATE
                SET effect_id = EXCLUDED.effect_id,
                    claim_token = EXCLUDED.claim_token,
                    lease_expires_at = EXCLUDED.lease_expires_at,
                    updated_at = clock_timestamp()
              WHERE claims.lease_expires_at <= clock_timestamp()
        RETURNING claim_token,
                  extract(epoch FROM lease_expires_at) AS lease_expires_at
    }, undef,
        "$args{source}", 0 + $args{generation}, "$args{effect_id}", "$claim_token",
        $validated->{lease_seconds}, "$args{instance_id}", $scope_digest,
        "$args{page_source}", "$args{generation}",
        "$args{page_source}", "$args{page}", "$args{page_source}");
    return {
        status => 'claimed',
        claim_token => "$claimed->{claim_token}",
        lease_expires_at => 0 + $claimed->{lease_expires_at},
    } if $claimed;

    my $loaded = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    return {status => 'stale'}
        unless _page_is_current($loaded->{snapshot}, \%args);
    return {status => 'busy'};
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
    my $snapshot = $args{next_snapshot};
    return {status => 'invalid_snapshot'}
        unless _snapshot_matches($snapshot, $args{instance_id}, $loaded->{release});
    my $snapshot_json = $self->_snapshot_json($snapshot);
    my $scope_digest = $self->_scope_digest($args{owner_scope});

    my $updated = $self->_dbh->selectrow_hashref(qq{
        WITH updated AS (
            UPDATE $self->{table} AS instances
               SET snapshot = ?::jsonb,
                   revision = instances.revision + 1,
                   updated_at = clock_timestamp()
              FROM $self->{claims_table} AS claims
             WHERE instances.instance_id = ?
               AND instances.owner_scope_digest = ?
               AND instances.release_id = ?
               AND instances.revision = ?
               AND instances.expires_at > clock_timestamp()
               AND claims.instance_id = instances.instance_id
               AND claims.source_id = ?
               AND claims.generation = ?
               AND claims.effect_id = ?
               AND claims.claim_token = ?
               AND claims.lease_expires_at > clock_timestamp()
         RETURNING instances.instance_id, instances.revision
        ), deleted AS (
            DELETE FROM $self->{claims_table} AS claims
             USING updated
             WHERE claims.instance_id = updated.instance_id
               AND claims.source_id = ?
               AND claims.generation = ?
               AND claims.claim_token = ?
         RETURNING claims.instance_id
        )
        SELECT revision FROM updated
    }, undef,
        $snapshot_json, "$args{instance_id}", $scope_digest, $loaded->{release},
        0 + $args{revision}, "$args{source}", 0 + $args{generation},
        "$args{effect_id}", "$args{claim_token}", "$args{source}",
        0 + $args{generation}, "$args{claim_token}");
    return {status => 'ok', revision => 0 + $updated->{revision}} if $updated;

    my $current_claim = $self->_dbh->selectrow_hashref(qq{
        SELECT 1
          FROM $self->{claims_table} AS claims
          JOIN $self->{table} AS instances
            ON instances.instance_id = claims.instance_id
         WHERE claims.instance_id = ?
           AND claims.source_id = ?
           AND claims.generation = ?
           AND claims.effect_id = ?
           AND claims.claim_token = ?
           AND claims.lease_expires_at > clock_timestamp()
           AND instances.owner_scope_digest = ?
           AND instances.expires_at > clock_timestamp()
    }, undef,
        "$args{instance_id}", "$args{source}", 0 + $args{generation},
        "$args{effect_id}", "$args{claim_token}", $scope_digest);
    return {status => 'claim_lost'} unless $current_claim;

    my $current = $self->load(
        owner_scope => $args{owner_scope},
        instance_id => $args{instance_id},
    );
    return $current unless $current->{status} eq 'ok';
    return {status => 'conflict', revision => $current->{revision}};
}

sub release_effect_claim {
    my ($self, %args) = @_;
    return {status => 'invalid_claim'}
        unless _valid_claim_identity(\%args)
        && _valid_scalar($args{claim_token}, 256);
    my $scope_digest = $self->_scope_digest($args{owner_scope});
    my $released = $self->_dbh->selectrow_hashref(qq{
        DELETE FROM $self->{claims_table} AS claims
         USING $self->{table} AS instances
         WHERE claims.instance_id = instances.instance_id
           AND claims.instance_id = ?
           AND claims.source_id = ?
           AND claims.generation = ?
           AND claims.effect_id = ?
           AND claims.claim_token = ?
           AND instances.owner_scope_digest = ?
     RETURNING claims.instance_id
    }, undef,
        "$args{instance_id}", "$args{source}", 0 + $args{generation},
        "$args{effect_id}", "$args{claim_token}", $scope_digest);
    return {status => 'ok'} if $released;
    return {status => 'claim_lost'};
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

sub cleanup_expired_claims {
    my ($self, %args) = @_;
    my $limit = $args{limit} // $self->{cleanup_limit};
    _positive_integer('claim cleanup limit', $limit, $self->{cleanup_limit});

    my $statement = $self->_dbh->prepare(qq{
        WITH doomed AS (
            SELECT instance_id, source_id, generation
              FROM $self->{claims_table}
             WHERE lease_expires_at <= clock_timestamp()
             ORDER BY lease_expires_at, instance_id, source_id, generation
             LIMIT ?
        )
        DELETE FROM $self->{claims_table} AS claims
         USING doomed
         WHERE claims.instance_id = doomed.instance_id
           AND claims.source_id = doomed.source_id
           AND claims.generation = doomed.generation
     RETURNING claims.instance_id
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

sub _page_is_current {
    my ($snapshot, $args) = @_;
    my $source = ref($snapshot->{sources}) eq 'HASH'
        ? $snapshot->{sources}{$args->{page_source}} : undef;
    return ref($source) eq 'HASH'
        && defined($source->{generation}) && !ref($source->{generation})
        && $source->{generation} == $args->{generation}
        && defined($source->{page}) && !ref($source->{page})
        && "$source->{page}" eq "$args->{page}"
        && ($source->{status} // '') eq 'ready';
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

sub _claims_table_name {
    my ($table) = @_;
    my @parts = split /\./, "$table", -1;
    my $name = pop @parts;
    my $suffix = '_effect_claims';
    $name =~ s/_instances\z//;
    $name = substr($name, 0, 63 - length($suffix)) . $suffix;
    return join '.', @parts, $name;
}

sub _index_name {
    my ($table, $suffix) = @_;
    my ($name) = "$table" =~ /([^.]+)\z/;
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
