package Selecto::Components::ExplorerSession;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(decode_json encode_json);
use JSON::PP ();
use Selecto::Components::ResponseBudget ();
use Selecto::Limits ();
use Time::HiRes qw(time);

# One object per socket. Never retain controllers, engines, domain authorization
# closures or database handles here. Result values are serialized for isolation.
has ttl => 30;
has max_bytes => 2_097_152;
has max_entries => 8;
has clock => sub { sub { time } };
has revision => 0;
has input => undef;
has entries => sub { {} };
has order => sub { [] };
has bytes => 0;
has scope => undef;
has domain => undef;

sub validate_options ($class, $options) {
    die "websocket_session_options must be an object\n" unless ref($options) eq 'HASH';
    my %bounds = (ttl => [0, 300], max_bytes => [0, 8_388_608], max_entries => [1, 32]);
    for my $key (keys %$options) {
        my $range = $bounds{$key} or die "Unknown Explorer session option: $key\n";
        my $value = $options->{$key};
        die "Invalid Explorer session limit: $key\n"
            unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/
                && $value >= $range->[0] && $value <= $range->[1];
    }
}

sub clear_results ($self) {
    $self->entries({});
    $self->order([]);
    $self->bytes(0);
}

sub bind_scope ($self, $scope) {
    die "Explorer session scope must be a scalar\n" if !defined($scope) || ref($scope);
    if (!defined($self->scope) || $self->scope ne $scope) {
        $self->clear_results;
        $self->input(undef);
        $self->scope($scope);
    }
}

sub bind_domain ($self, $fingerprint) {
    if (!defined($self->domain) || $self->domain ne $fingerprint) {
        $self->clear_results;
        $self->domain($fingerprint);
    }
}

sub prepare ($self, $input, $patch = undef, $refresh = 0) {
    if (defined $patch) {
        die "Invalid Explorer state patch\n"
            unless ref($patch) eq 'HASH' && ref($patch->{set}) eq 'HASH'
                && ref($patch->{remove}) eq 'ARRAY'
                && defined($patch->{revision}) && !ref($patch->{revision})
                && "$patch->{revision}" =~ /\A\d{1,12}\z/;
        return undef unless defined($self->input) && $patch->{revision} == $self->revision;
        $input = {%{$self->input}, %{$patch->{set}}};
        for my $key (@{$patch->{remove}}) {
            die "Invalid Explorer state key\n" if !defined($key) || ref($key);
            delete $input->{$key};
        }
    }
    my $encoded = encode_json($input);
    die "Explorer state is too large\n" if length($encoded) > 131_072;
    # Re-running the identical view is an explicit request for fresh data.
    # Paging and presentation changes can reuse exact SQL within the short TTL.
    my $json = JSON::PP->new->canonical;
    my %comparable = %$input;
    delete @comparable{qw(render_scope reuse_count query_signature)};
    my %previous = %{$self->input // {}};
    delete @previous{qw(render_scope reuse_count query_signature)};
    $self->clear_results if $refresh || (defined($self->input)
        && !$input->{reuse_count}
        && $json->encode(\%comparable) eq $json->encode(\%previous));
    return decode_json($encoded);
}

sub commit ($self, $input) {
    $self->input(decode_json(encode_json($input)));
    $self->revision($self->revision + 1);
    return $self->revision;
}

sub fetch ($self, $key) {
    my $entry = $self->entries->{$key} or return undef;
    if ($self->clock->() - $entry->{created_at} >= $self->ttl) {
        $self->_remove($key);
        return undef;
    }
    return {created_at => $entry->{created_at}, result => decode_json($entry->{json})};
}

sub store ($self, $key, $result) {
    return unless $self->ttl && $self->max_bytes;
    my $json = eval { Selecto::Components::ResponseBudget->json($result,
        Selecto::Limits->new->tightened(max_response_bytes => $self->max_bytes)) };
    return unless defined $json;
    $self->_remove($key);
    my $size = length($json);
    return if $size > $self->max_bytes;
    while (@{$self->order} && ($self->bytes + $size > $self->max_bytes
        || @{$self->order} >= $self->max_entries)) {
        $self->_remove($self->order->[0]);
    }
    $self->entries->{$key} = {json => $json, created_at => $self->clock->()};
    push @{$self->order}, $key;
    $self->bytes($self->bytes + $size);
}

sub _remove ($self, $key) {
    my $entry = delete $self->entries->{$key} or return;
    $self->bytes($self->bytes - length($entry->{json}));
    $self->order([grep { $_ ne $key } @{$self->order}]);
}

1;

__END__

=head1 NAME

Selecto::Components::ExplorerSession - Per-WebSocket form state and bounded result cache

=head1 SYNOPSIS

    # Configured through the plugin (or per explorer):
    websocket_session_options => {ttl => 30, max_bytes => 2_097_152, max_entries => 8},

    # Also usable as an Explorer result cache, for example for dashboard tiles:
    my $cache = Selecto::Components::ExplorerSession->new(ttl => 60);
    my $model = $explorer->model($c, $input, {result_cache => $cache, cache_namespace => $trusted_source_and_policy_namespace});

=head1 DESCRIPTION

Each Explorer WebSocket connection has one session. It keeps the last
accepted form snapshot and a revision, so the browser can send
C<< selecto_session => {revision, set, remove} >> patches instead of whole
forms. It also keeps a small cache of raw query results, keyed by
L<Selecto::Components::Explorer/result_cache_key> (trusted namespace, domain, adapter, SQL, columns and
bound values). Presentation changes, paging and going back to an earlier page
can therefore reuse data within a short TTL.

The session never holds controllers, engines, database handles or
authorization closures. Every message still obtains a fresh engine,
validates the state and compiles the SQL before a cached result can be used.
Cached values are serialized, so rendering cannot change them. The cache is
cleared when the domain fingerprint or the C<websocket_context> scope
changes, when the user re-runs the identical query, when the browser sends
C<selecto_refresh>, and when the connection closes. It is not a durable store.
See F<docs/explorer-sessions.md> for the protocol.

=head1 ATTRIBUTES

=over 4

=item ttl

Seconds a cached result stays fresh. The default is 30 and the range is 0 to
300; 0 disables result caching but keeps revisioned form state.

=item max_bytes

The total size of serialized results. The default is 2 MiB and the maximum
8 MiB. An oversized result is served but not kept.

=item max_entries

The number of cached data and count results. The default is 8 and the range
is 1 to 32.

=back

=head1 METHODS

=head2 validate_options

    Selecto::Components::ExplorerSession->validate_options(\%options);

Dies unless the hash contains only valid C<ttl>, C<max_bytes> and
C<max_entries> values.

=head2 fetch, store, bind_domain

The result-cache interface that L<Selecto::Components::Explorer/model>
expects: C<fetch($key)> returns C<< {result, created_at} >> or C<undef>, and
C<store($key, $result)> saves a result. C<bind_domain($fingerprint)> clears
the cache when the domain changes.

=head2 bind_scope, prepare, commit, clear_results

Used by the WebSocket route. C<bind_scope> resets the session when the
security scope changes. C<prepare> applies a revisioned patch, and returns
C<undef> when the revision is stale (the browser then resyncs). C<commit>
records an accepted state and advances the revision.

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::Components::Explorer>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
