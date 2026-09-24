package Selecto::Components::Templates::PageCursor;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use JSON::PP ();
use Mojo::Util qw(secure_compare);
use Time::HiRes qw(time);

my $DEFAULT_TTL_SECONDS = 900;
my $MAX_PAGES = 10_000;
my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(1);

=head1 NAME

Selecto::Components::Templates::PageCursor - Opaque cursors for server-held collection pages

=head1 DESCRIPTION

The token reveals only its expiry and a keyed digest. Resolution checks the
current server-held page positions after the host supplies fresh tenant and
authorization scope. Browser input never becomes a trusted seek tuple.

=cut

sub issue {
    my ($class, %args) = @_;
    my $prepared = _prepare(\%args);
    return $prepared unless $prepared->{status} eq 'ok';
    my $expires_at = $prepared->{now} + $prepared->{ttl};
    my @pages = map {
        my $page = $_;
        my $position = _position($page);
        {
            collection_path => _clone_data($page->{collection_path}),
            parent_path => _clone_data($page->{parent_path}),
            has_more => $page->{has_more},
            token => $page->{has_more}
                ? _token($prepared->{context}, $position, $expires_at,
                    $args{secret}) : undef,
        }
    } @{$prepared->{pages}};
    return {status => 'ok', pages => \@pages};
}

sub resolve {
    my ($class, %args) = @_;
    my $prepared = _prepare(\%args);
    return $prepared unless $prepared->{status} eq 'ok';
    my $supplied = $args{token};
    return _invalid() unless defined($supplied) && !ref($supplied)
        && length($supplied) <= 128
        && $supplied =~ /\Apc1\.([1-9][0-9]{0,11})\.[0-9a-f]{64}\z/;
    my $expires_at = 0 + $1;
    return _invalid() unless $expires_at >= $prepared->{now}
        && $expires_at <= $prepared->{now} + $prepared->{ttl};

    for my $page (@{$prepared->{pages}}) {
        next unless $page->{has_more};
        my $position = _position($page);
        my $expected = _token($prepared->{context}, $position, $expires_at,
            $args{secret});
        return {status => 'ok', position => _clone_data($position)}
            if secure_compare($expected, $supplied);
    }
    return _invalid();
}

sub _prepare {
    my ($args) = @_;
    my ($snapshot, $source_id, $source_plan, $scope, $secret) =
        @{$args}{qw(snapshot source_id source_plan scope secret)};
    return _invalid() unless ref($snapshot) eq 'HASH'
        && _non_empty($source_id)
        && ref($source_plan) eq 'HASH'
        && ($source_plan->{id} // '') eq $source_id
        && _paged_source($source_plan)
        && ref($scope) eq 'HASH'
        && _non_empty($scope->{tenant_id})
        && _non_empty($scope->{principal_id})
        && _non_empty($scope->{authorization_revision})
        && _non_empty($scope->{membership_revision})
        && _non_empty($snapshot->{instance_id})
        && _non_empty($snapshot->{release_id})
        && _non_empty($snapshot->{template_fingerprint})
        && ref($snapshot->{sources}) eq 'HASH'
        && defined($secret) && !ref($secret) && length($secret) >= 32;
    my $now = defined($args->{now}) ? $args->{now} : int(time());
    my $ttl = defined($args->{ttl_seconds})
        ? $args->{ttl_seconds} : $DEFAULT_TTL_SECONDS;
    return _invalid() unless defined($now) && !ref($now)
        && "$now" =~ /\A(?:0|[1-9][0-9]*)\z/
        && defined($ttl) && !ref($ttl)
        && "$ttl" =~ /\A[1-9][0-9]*\z/
        && $ttl <= $DEFAULT_TTL_SECONDS;
    my $source = $snapshot->{sources}{$source_id};
    return _invalid() unless ref($source) eq 'HASH'
        && ($source->{status} // '') eq 'ready'
        && defined($source->{generation}) && !ref($source->{generation})
        && "$source->{generation}" =~ /\A[1-9][0-9]*\z/;
    my $result = $source->{result};
    return _invalid() unless ref($result) eq 'HASH'
        && ref($result->{rows}) eq 'ARRAY'
        && ref($result->{pages}) eq 'ARRAY'
        && @{$result->{pages}}
        && @{$result->{pages}} <= $MAX_PAGES
        && !grep { !_valid_page($_) || !_declared_page($source_plan, $_) }
            @{$result->{pages}};

    my $source_digest = eval { sha256_hex($JSON->encode($source_plan)) };
    return _invalid() if $@;
    my $bindings_digest = eval {
        sha256_hex($JSON->encode({
            input => $snapshot->{inputs}, state => $snapshot->{state},
        }))
    };
    return _invalid() if $@;
    return {
        status => 'ok', now => 0 + $now, ttl => 0 + $ttl,
        pages => $result->{pages},
        context => {
            schema => 'selecto.template.page-cursor.v1',
            instance_id => "$snapshot->{instance_id}",
            release_id => "$snapshot->{release_id}",
            template_fingerprint => "$snapshot->{template_fingerprint}",
            source_id => "$source_id",
            source_fingerprint => "sha256:$source_digest",
            generation => 0 + $source->{generation},
            tenant_id => "$scope->{tenant_id}",
            principal_id => "$scope->{principal_id}",
            authorization_revision => "$scope->{authorization_revision}",
            membership_revision => "$scope->{membership_revision}",
            bindings_fingerprint => "sha256:$bindings_digest",
        },
    };
}

sub _valid_page {
    my ($page) = @_;
    return 0 unless ref($page) eq 'HASH'
        && join(',', sort keys %$page)
            eq 'after_values,collection_path,has_more,parent_path'
        && ref($page->{collection_path}) eq 'ARRAY'
        && @{$page->{collection_path}}
        && ref($page->{parent_path}) eq 'ARRAY'
        && @{$page->{parent_path}} == @{$page->{collection_path}}
        && JSON::PP::is_bool($page->{has_more})
        && !grep { !_non_empty($_) } @{$page->{collection_path}}
        && !grep { !_key($_) } @{$page->{parent_path}};
    return !defined($page->{after_values}) unless $page->{has_more};
    return ref($page->{after_values}) eq 'ARRAY'
        && @{$page->{after_values}}
        && !grep { defined($_) && ref($_) } @{$page->{after_values}}
        && _key($page->{after_values}[-1]);
}

sub _paged_source {
    my ($source) = @_;
    return 0 unless ref($source->{query}) eq 'HASH';
    return _paged_collections($source->{query}{collections});
}

sub _paged_collections {
    my ($collections) = @_;
    return 0 unless ref($collections) eq 'ARRAY';
    for my $collection (@$collections) {
        next unless ref($collection) eq 'HASH';
        return 1 if defined($collection->{page_size})
            && !ref($collection->{page_size})
            && "$collection->{page_size}" =~ /\A[1-9][0-9]*\z/;
        return 1 if _paged_collections($collection->{collections});
    }
    return 0;
}

sub _declared_page {
    my ($source, $page) = @_;
    my $collections = $source->{query}{collections};
    my $path = $page->{collection_path};
    for my $index (0 .. $#$path) {
        my $id = $path->[$index];
        return 0 unless ref($collections) eq 'ARRAY';
        my @matching = grep {
            ref($_) eq 'HASH' && defined($_->{id}) && $_->{id} eq $id
        } @$collections;
        return 0 unless @matching == 1;
        my $collection = $matching[0];
        $collections = $collection->{collections};
        if ($index == $#$path) {
            return defined($collection->{page_size})
                && !ref($collection->{page_size})
                && "$collection->{page_size}" =~ /\A[1-9][0-9]*\z/;
        }
    }
    return 0;
}

sub _position {
    my ($page) = @_;
    return {
        collection_path => $page->{collection_path},
        parent_path => $page->{parent_path},
        after_values => $page->{after_values},
    };
}

sub _clone_data {
    my ($value) = @_;
    return $JSON->decode($JSON->encode($value));
}

sub _token {
    my ($context, $position, $expires_at, $secret) = @_;
    my $payload = $JSON->encode({
        context => $context, position => $position, expires_at => $expires_at,
    });
    return 'pc1.' . $expires_at . '.' . hmac_sha256_hex($payload, $secret);
}

sub _non_empty {
    my ($value) = @_;
    return defined($value) && !ref($value) && length("$value");
}

sub _key {
    my ($value) = @_;
    return _non_empty($value);
}

sub _invalid {
    return {
        status => 'error',
        schema => 'selecto.template.page-cursor-diagnostic.v1',
        code => 'invalid_page_cursor',
        message => 'collection page cursor is invalid',
    };
}

1;
