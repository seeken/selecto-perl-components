package Selecto::Components::QueryAssistant::Store;
use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);
use Storable qw(dclone);
use Time::HiRes qw(time);

# In-memory quotas are per process. Multi-worker hosts must use a shared store.
sub _options {
    my ($class, %args) = @_;
    my %defaults = (idle_ttl => 1800, maximum_lifetime => 7200,
        max_drafts_per_owner => 10, max_payload_bytes => 65_536,
        max_total_drafts => 1000, max_total_bytes => 16_777_216,
        max_owner_bytes => 655_360, max_creates_per_minute => 100);
    for my $key (keys %defaults) {
        $defaults{$key} = $args{$key} if exists $args{$key};
        die "invalid draft store $key\n" unless defined($defaults{$key}) && !ref($defaults{$key})
            && "$defaults{$key}" =~ /\A[1-9][0-9]{0,11}\z/;
    }
    return \%defaults;
}
sub new {
    my ($class, %args) = @_;
    return bless {%{$class->_options(%args)}, records => {}, bytes => {}, owner_counts => {},
        owner_bytes => {}, total_bytes => 0, rate_start => time, rate_count => 0}, $class;
}
sub _encoded {
    my ($self, $record) = @_;
    die "draft owner must be a bounded scalar\n" if !defined($record->{owner}) || ref($record->{owner}) || length($record->{owner}) > 256;
    my $json = encode_json($record);
    die "draft payload is too large\n" if length($json) > $self->{max_payload_bytes};
    return $json;
}
sub create {
    my ($self, $record) = @_;
    die "draft record must be an object\n" unless ref($record) eq 'HASH';
    $self->_expire;
    my $now = time;
    if ($now - $self->{rate_start} >= 60) { $self->{rate_start} = $now; $self->{rate_count} = 0 }
    die "draft creation rate exceeded\n" if $self->{rate_count} >= $self->{max_creates_per_minute};
    my $id = sha256_hex(join(':', $$, $now, rand(), {}));
    my $stored = dclone($record);
    @$stored{qw(id revision created_at touched_at)} = ($id, 0, $now, $now);
    my $bytes = length($self->_encoded($stored));
    my $owner = $stored->{owner};
    die "draft quota exceeded\n" if keys(%{$self->{records}}) >= $self->{max_total_drafts}
        || ($self->{owner_counts}{$owner} // 0) >= $self->{max_drafts_per_owner}
        || $self->{total_bytes} + $bytes > $self->{max_total_bytes}
        || ($self->{owner_bytes}{$owner} // 0) + $bytes > $self->{max_owner_bytes};
    delete $self->{last_touch}{$id};
    $self->{records}{$id} = $stored;
    $self->{bytes}{$id} = $bytes;
    $self->{owner_counts}{$owner}++;
    $self->{owner_bytes}{$owner} += $bytes;
    $self->{total_bytes} += $bytes;
    $self->{rate_count}++;
    return dclone($stored);
}
sub get {
    my ($self, $id) = @_;
    $self->_expire;
    my $record = $self->{records}{$id} or return undef;
    $self->{last_touch}{$id} = time;
    my $copy = dclone($record);
    $copy->{touched_at} = $self->{last_touch}{$id};
    return $copy;
}
sub compare_and_swap {
    my ($self, $id, $revision, $replacement) = @_;
    $self->_expire;
    my $record = $self->{records}{$id} or return {ok => 0, code => 'draft_expired'};
    return {ok => 0, code => 'revision_conflict', current_revision => $record->{revision}}
        unless defined($revision) && $revision == $record->{revision};
    return {ok => 0, code => 'invalid_owner'} unless ref($replacement) eq 'HASH'
        && ($replacement->{owner} // '') eq $record->{owner};
    my $stored = dclone($replacement);
    @$stored{qw(id revision created_at touched_at)} = ($id, $revision + 1, $record->{created_at}, time);
    my $bytes = eval { length($self->_encoded($stored)) };
    return {ok => 0, code => 'limit_exceeded'} if $@;
    my $delta = $bytes - $self->{bytes}{$id};
    my $owner = $record->{owner};
    return {ok => 0, code => 'limit_exceeded'} if $self->{total_bytes} + $delta > $self->{max_total_bytes}
        || $self->{owner_bytes}{$owner} + $delta > $self->{max_owner_bytes};
    delete $self->{last_touch}{$id};
    $self->{records}{$id} = $stored;
    $self->{bytes}{$id} = $bytes;
    $self->{total_bytes} += $delta;
    $self->{owner_bytes}{$owner} += $delta;
    return {ok => 1, record => dclone($stored)};
}
sub _expire {
    my ($self) = @_;
    my $now = time;
    for my $id (keys %{$self->{records}}) {
        my $record = $self->{records}{$id};
        next unless $now - ($self->{last_touch}{$id} // $record->{touched_at}) > $self->{idle_ttl}
            || $now - $record->{created_at} > $self->{maximum_lifetime};
        my $owner = $record->{owner};
        my $bytes = delete $self->{bytes}{$id};
        $self->{total_bytes} -= $bytes;
        $self->{owner_bytes}{$owner} -= $bytes;
        delete $self->{owner_bytes}{$owner} unless $self->{owner_bytes}{$owner};
        delete $self->{owner_counts}{$owner} unless --$self->{owner_counts}{$owner};
        delete $self->{records}{$id};
        delete $self->{last_touch}{$id};
    }
}
1;
