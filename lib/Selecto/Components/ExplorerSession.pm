package Selecto::Components::ExplorerSession;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(decode_json encode_json);
use JSON::PP ();
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
    my $json = eval { encode_json($result) };
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
