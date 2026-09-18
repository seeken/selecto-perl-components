package Selecto::Components::QueryAssistant::Store::SQLite;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(decode_json encode_json);
use Storable qw(dclone);
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    require DBI;
    my $dbh = $args{dbh};
    if (!$dbh) {
        die "SQLite draft store path is required\n"
            unless defined($args{path}) && !ref($args{path}) && length($args{path});
        $dbh = DBI->connect(
            "dbi:SQLite:dbname=$args{path}", '', '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_use_immediate_transaction => 1},
        );
    }
    my $self = bless {
        dbh => $dbh,
        idle_ttl => $args{idle_ttl} // 1800,
        maximum_lifetime => $args{maximum_lifetime} // 7200,
        max_drafts_per_owner => $args{max_drafts_per_owner} // 10,
        max_payload_bytes => $args{max_payload_bytes} // 65_536,
    }, $class;
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS selecto_query_drafts (
            id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL,
            created_at REAL NOT NULL,
            touched_at REAL NOT NULL,
            payload TEXT NOT NULL
        )
    });
    return $self;
}

sub create {
    my ($self, $record) = @_;
    die "draft record must be an object\n" unless ref($record) eq 'HASH';
    $self->_expire;
    my $owned = 0;
    my $rows = $self->{dbh}->selectcol_arrayref('SELECT payload FROM selecto_query_drafts');
    for my $payload (@$rows) {
        my $existing = eval { decode_json($payload) } // {};
        $owned++ if ($existing->{owner} // '') eq ($record->{owner} // '');
    }
    die "draft quota exceeded\n" if $owned >= $self->{max_drafts_per_owner};
    my $now = time;
    my $id = sha256_hex(join(':', $$, $now, rand(), {}));
    my $stored = dclone($record);
    @$stored{qw(id revision created_at touched_at)} = ($id, 0, $now, $now);
    return {ok => 0, code => 'limit_exceeded'}
        if length(encode_json($stored)) > $self->{max_payload_bytes};
    $self->{dbh}->do(
        'INSERT INTO selecto_query_drafts (id, revision, created_at, touched_at, payload) VALUES (?, ?, ?, ?, ?)',
        undef, $id, 0, $now, $now, encode_json($stored),
    );
    return dclone($stored);
}

sub get {
    my ($self, $id) = @_;
    $self->_expire;
    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT revision, created_at, touched_at, payload FROM selecto_query_drafts WHERE id = ?',
        undef, $id,
    ) or return undef;
    my $now = time;
    $self->{dbh}->do('UPDATE selecto_query_drafts SET touched_at = ? WHERE id = ?', undef, $now, $id);
    my $record = decode_json($row->{payload});
    @$record{qw(id revision created_at touched_at)} = ($id, 0 + $row->{revision}, 0 + $row->{created_at}, $now);
    return $record;
}

sub compare_and_swap {
    my ($self, $id, $revision, $replacement) = @_;
    $self->_expire;
    my $now = time;
    my $stored = dclone($replacement);
    $stored->{id} = $id;
    $stored->{revision} = $revision + 1;
    $stored->{touched_at} = $now;
    die "draft payload is too large\n"
        if length(encode_json($stored)) > $self->{max_payload_bytes};
    my $rows = $self->{dbh}->do(
        'UPDATE selecto_query_drafts SET revision = ?, touched_at = ?, payload = ? WHERE id = ? AND revision = ?',
        undef, $revision + 1, $now, encode_json($stored), $id, $revision,
    );
    return {ok => 1, record => $stored} if defined($rows) && 0 + $rows == 1;
    my ($current) = $self->{dbh}->selectrow_array(
        'SELECT revision FROM selecto_query_drafts WHERE id = ?', undef, $id,
    );
    return {ok => 0, code => 'draft_expired'} unless defined $current;
    return {ok => 0, code => 'revision_conflict', current_revision => 0 + $current};
}

sub _expire {
    my ($self) = @_;
    my $now = time;
    $self->{dbh}->do(
        'DELETE FROM selecto_query_drafts WHERE touched_at < ? OR created_at < ?',
        undef, $now - $self->{idle_ttl}, $now - $self->{maximum_lifetime},
    );
}

1;
