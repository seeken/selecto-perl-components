package Selecto::Components::QueryAssistant::Store;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);
use Storable qw(dclone);
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    return bless {
        records => {},
        idle_ttl => $args{idle_ttl} // 1800,
        maximum_lifetime => $args{maximum_lifetime} // 7200,
        max_drafts_per_owner => $args{max_drafts_per_owner} // 10,
        max_payload_bytes => $args{max_payload_bytes} // 65_536,
    }, $class;
}

sub create {
    my ($self, $record) = @_;
    die "draft record must be an object\n" unless ref($record) eq 'HASH';
    $self->_expire;
    my $owner = $record->{owner} // '';
    my $owned = grep { ($self->{records}{$_}{owner} // '') eq $owner } keys %{$self->{records}};
    die "draft quota exceeded\n" if $owned >= $self->{max_drafts_per_owner};
    die "draft payload is too large\n" if length(encode_json($record)) > $self->{max_payload_bytes};
    my $now = time;
    my $id = sha256_hex(join(':', $$, $now, rand(), {}, keys %{$self->{records}}));
    my $stored = dclone($record);
    @$stored{qw(id revision created_at touched_at)} = ($id, 0, $now, $now);
    $self->{records}{$id} = $stored;
    return dclone($stored);
}

sub get {
    my ($self, $id) = @_;
    $self->_expire;
    my $record = $self->{records}{$id} or return undef;
    $record->{touched_at} = time;
    return dclone($record);
}

sub compare_and_swap {
    my ($self, $id, $revision, $replacement) = @_;
    $self->_expire;
    my $record = $self->{records}{$id} or return {ok => 0, code => 'draft_expired'};
    return {ok => 0, code => 'revision_conflict', current_revision => $record->{revision}}
        unless defined($revision) && $revision == $record->{revision};
    my $stored = dclone($replacement);
    return {ok => 0, code => 'limit_exceeded'}
        if length(encode_json($stored)) > $self->{max_payload_bytes};
    $stored->{id} = $id;
    $stored->{revision} = $record->{revision} + 1;
    $stored->{created_at} = $record->{created_at};
    $stored->{touched_at} = time;
    $self->{records}{$id} = $stored;
    return {ok => 1, record => dclone($stored)};
}

sub _expire {
    my ($self) = @_;
    my $now = time;
    delete @{$self->{records}}{grep {
        my $record = $self->{records}{$_};
        $now - ($record->{touched_at} // 0) > $self->{idle_ttl}
            || $now - ($record->{created_at} // 0) > $self->{maximum_lifetime}
    } keys %{$self->{records}}};
}

1;
