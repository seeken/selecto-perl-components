package Selecto::Components::QueryAssistant::Store::SQLite;
use 5.034;
use strict;
use warnings;
use parent 'Selecto::Components::QueryAssistant::Store';
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(decode_json encode_json);
use Storable qw(dclone);
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    require DBI;
    my $dbh = $args{dbh};
    if (!$dbh) {
        die "SQLite draft store path is required\n" unless defined($args{path}) && !ref($args{path}) && length($args{path});
        $dbh = DBI->connect("dbi:SQLite:dbname=$args{path}", '', '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_use_immediate_transaction => 1});
    }
    my $self = bless {%{$class->_options(%args)}, dbh => $dbh}, $class;
    $dbh->do('CREATE TABLE IF NOT EXISTS selecto_query_drafts (id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
        created_at REAL NOT NULL, touched_at REAL NOT NULL, payload TEXT NOT NULL)');
    $dbh->do('CREATE TABLE IF NOT EXISTS selecto_query_draft_totals (id INTEGER PRIMARY KEY CHECK(id=1),
        records INTEGER NOT NULL, bytes INTEGER NOT NULL, rate_start REAL NOT NULL, rate_count INTEGER NOT NULL)');
    $dbh->do('INSERT OR IGNORE INTO selecto_query_draft_totals VALUES (1,0,0,0,0)');
    $self->_txn(sub {
        my %columns = map { $_->{name} => 1 } @{$dbh->selectall_arrayref('PRAGMA table_info(selecto_query_drafts)', {Slice => {}})};
        # Legacy backfill runs once, at migration, one payload at a time.
        unless ($columns{owner}) {
            $dbh->do("ALTER TABLE selecto_query_drafts ADD COLUMN owner TEXT NOT NULL DEFAULT ''");
            $dbh->do('ALTER TABLE selecto_query_drafts ADD COLUMN payload_bytes INTEGER NOT NULL DEFAULT 0');
            $dbh->do('ALTER TABLE selecto_query_drafts ADD COLUMN expires_at REAL NOT NULL DEFAULT 0');
            my $rows = $dbh->prepare('SELECT id,payload,created_at,touched_at FROM selecto_query_drafts');
            $rows->execute;
            while (my $row = $rows->fetchrow_hashref) {
                my $record = decode_json($row->{payload});
                $dbh->do('UPDATE selecto_query_drafts SET owner=?, payload_bytes=length(CAST(payload AS BLOB)), expires_at=? WHERE id=?',
                    undef, $record->{owner} // '', $self->_expiry($row->{created_at}, $row->{touched_at}), $row->{id});
            }
            $rows->finish;
            $dbh->do('UPDATE selecto_query_draft_totals SET records=(SELECT count(*) FROM selecto_query_drafts), bytes=(SELECT coalesce(sum(payload_bytes),0) FROM selecto_query_drafts) WHERE id=1');
        }
        $dbh->do('CREATE INDEX IF NOT EXISTS selecto_query_drafts_owner ON selecto_query_drafts(owner,payload_bytes)');
        $dbh->do('CREATE INDEX IF NOT EXISTS selecto_query_drafts_expiry ON selecto_query_drafts(expires_at)');
        $dbh->do('CREATE TRIGGER IF NOT EXISTS selecto_drafts_insert AFTER INSERT ON selecto_query_drafts BEGIN UPDATE selecto_query_draft_totals SET records=records+1,bytes=bytes+NEW.payload_bytes WHERE id=1; END');
        $dbh->do('CREATE TRIGGER IF NOT EXISTS selecto_drafts_update AFTER UPDATE OF payload_bytes ON selecto_query_drafts BEGIN UPDATE selecto_query_draft_totals SET bytes=bytes+NEW.payload_bytes-OLD.payload_bytes WHERE id=1; END');
        $dbh->do('CREATE TRIGGER IF NOT EXISTS selecto_drafts_delete AFTER DELETE ON selecto_query_drafts BEGIN UPDATE selecto_query_draft_totals SET records=records-1,bytes=bytes-OLD.payload_bytes WHERE id=1; END');
    });
    return $self;
}
sub _txn {
    my ($self, $code) = @_;
    my $dbh = $self->{dbh};
    my $own = $dbh->{AutoCommit};
    my ($result, $error);
    eval {
        local $dbh->{sqlite_use_immediate_transaction} = 1;
        $own ? $dbh->begin_work : $dbh->do('SAVEPOINT selecto_draft_budget');
        # Acquire the write lock even inside a caller-owned deferred transaction.
        $dbh->do('UPDATE selecto_query_draft_totals SET records=records WHERE id=1');
        $result = $code->();
        $own ? $dbh->commit : $dbh->do('RELEASE SAVEPOINT selecto_draft_budget');
        1;
    } or $error = $@ || 'draft store transaction failed';
    if ($error) {
        eval { if ($own) { $dbh->rollback unless $dbh->{AutoCommit} }
            else { $dbh->do('ROLLBACK TO SAVEPOINT selecto_draft_budget'); $dbh->do('RELEASE SAVEPOINT selecto_draft_budget') } };
        die $error;
    }
    return $result;
}
sub _expiry {
    my ($self, $created, $touched) = @_;
    my $idle = $touched + $self->{idle_ttl};
    my $maximum = $created + $self->{maximum_lifetime};
    return $idle < $maximum ? $idle : $maximum;
}
sub _expire {
    my ($self) = @_;
    $self->{dbh}->do('DELETE FROM selecto_query_drafts WHERE id IN (SELECT id FROM selecto_query_drafts WHERE expires_at < ? ORDER BY expires_at LIMIT 1000)', undef, time);
}
sub _room {
    my ($self, $owner, $bytes, $records) = @_;
    my $dbh = $self->{dbh};
    my ($count, $total) = $dbh->selectrow_array('SELECT records,bytes FROM selecto_query_draft_totals WHERE id=1');
    my ($owned, $owner_bytes) = $dbh->selectrow_array('SELECT count(*),coalesce(sum(payload_bytes),0) FROM selecto_query_drafts WHERE owner=?', undef, $owner);
    return $count + $records <= $self->{max_total_drafts} && $total + $bytes <= $self->{max_total_bytes}
        && $owned + $records <= $self->{max_drafts_per_owner} && $owner_bytes + $bytes <= $self->{max_owner_bytes};
}
sub create {
    my ($self, $record) = @_;
    die "draft record must be an object\n" unless ref($record) eq 'HASH';
    return $self->_txn(sub {
        $self->_expire;
        my $now = time;
        my $dbh = $self->{dbh};
        $dbh->do('UPDATE selecto_query_draft_totals SET rate_start=?,rate_count=0 WHERE id=1 AND rate_start<=?', undef, $now, $now-60);
        my ($rate) = $dbh->selectrow_array('SELECT rate_count FROM selecto_query_draft_totals WHERE id=1');
        die "draft creation rate exceeded\n" if $rate >= $self->{max_creates_per_minute};
        my $id = sha256_hex(join(':', $$, $now, rand(), {}));
        my $stored = dclone($record);
        @$stored{qw(id revision created_at touched_at)} = ($id, 0, $now, $now);
        my $json = $self->_encoded($stored);
        die "draft quota exceeded\n" unless $self->_room($stored->{owner}, length($json), 1);
        $dbh->do('INSERT INTO selecto_query_drafts (id,revision,created_at,touched_at,payload,owner,payload_bytes,expires_at) VALUES (?,?,?,?,?,?,?,?)',
            undef, $id, 0, $now, $now, $json, $stored->{owner}, length($json), $self->_expiry($now,$now));
        $dbh->do('UPDATE selecto_query_draft_totals SET rate_count=rate_count+1 WHERE id=1');
        return dclone($stored);
    });
}
sub get {
    my ($self, $id) = @_;
    return $self->_txn(sub {
        $self->_expire;
        my $row = $self->{dbh}->selectrow_hashref('SELECT revision,created_at,payload FROM selecto_query_drafts WHERE id=? AND expires_at>=?', undef, $id, time) or return undef;
        my $now = time;
        $self->{dbh}->do('UPDATE selecto_query_drafts SET touched_at=?,expires_at=? WHERE id=?', undef, $now, $self->_expiry($row->{created_at},$now), $id);
        my $record = decode_json($row->{payload});
        @$record{qw(id revision created_at touched_at)} = ($id, 0+$row->{revision}, 0+$row->{created_at}, $now);
        return $record;
    });
}
sub compare_and_swap {
    my ($self, $id, $revision, $replacement) = @_;
    return $self->_txn(sub {
        $self->_expire;
        my $dbh = $self->{dbh};
        my $old = $dbh->selectrow_hashref('SELECT owner,revision,created_at,payload_bytes FROM selecto_query_drafts WHERE id=? AND expires_at>=?', undef, $id, time)
            or return {ok => 0, code => 'draft_expired'};
        return {ok => 0, code => 'revision_conflict', current_revision => 0+$old->{revision}}
            unless defined($revision) && $revision == $old->{revision};
        return {ok => 0, code => 'invalid_owner'} unless ref($replacement) eq 'HASH' && ($replacement->{owner} // '') eq $old->{owner};
        my $stored = dclone($replacement);
        my $now = time;
        @$stored{qw(id revision created_at touched_at)} = ($id, $revision+1, $old->{created_at}, $now);
        my $json = eval { $self->_encoded($stored) };
        return {ok => 0, code => 'limit_exceeded'} if $@ || !$self->_room($old->{owner}, length($json)-$old->{payload_bytes}, 0);
        $dbh->do('UPDATE selecto_query_drafts SET revision=?,touched_at=?,payload=?,payload_bytes=?,expires_at=? WHERE id=? AND revision=?',
            undef, $revision+1, $now, $json, length($json), $self->_expiry($old->{created_at},$now), $id, $revision);
        return {ok => 1, record => $stored};
    });
}
1;
