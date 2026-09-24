package Selecto::Components::Templates::RootCursor;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use JSON::PP ();
use Mojo::Util qw(secure_compare);
use Selecto::Templates ();
use Time::HiRes qw(time);

my $DEFAULT_TTL_SECONDS = 900;
my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(1);

=head1 NAME

Selecto::Components::Templates::RootCursor - Opaque tokens for server-held root pages

=head1 DESCRIPTION

The host supplies fresh tenant and authorization scope on every call. A token
reveals only expiry and a keyed digest; browser data never becomes a trusted
ordering tuple until it matches the current server-held page.

=cut

sub issue {
    my ($class, %args) = @_;
    my $prepared = _prepare(\%args);
    return $prepared unless $prepared->{status} eq 'ok';
    my $page = $prepared->{page};
    my $expires_at = $prepared->{now} + $prepared->{ttl};
    return {
        status => 'ok', has_more => $page->{has_more},
        token => $page->{has_more}
            ? _token($prepared->{context}, _position($page), $expires_at,
                $args{secret}) : undef,
    };
}

sub resolve {
    my ($class, %args) = @_;
    my $prepared = _prepare(\%args);
    return $prepared unless $prepared->{status} eq 'ok';
    return _invalid() unless $prepared->{page}{has_more};
    my $supplied = $args{token};
    return _invalid() unless defined($supplied) && !ref($supplied)
        && length($supplied) <= 128
        && $supplied =~ /\Arc1\.([1-9][0-9]{0,11})\.[0-9a-f]{64}\z/;
    my $expires_at = 0 + $1;
    return _invalid() unless $expires_at >= $prepared->{now}
        && $expires_at <= $prepared->{now} + $prepared->{ttl};
    my $position = _position($prepared->{page});
    my $expected = _token($prepared->{context}, $position, $expires_at,
        $args{secret});
    return _invalid() unless secure_compare($expected, $supplied);
    return {status => 'ok', position => _clone($position)};
}

sub _prepare {
    my ($args) = @_;
    my ($snapshot, $source_id, $source_plan, $scope, $secret) =
        @{$args}{qw(snapshot source_id source_plan scope secret)};
    return _invalid() unless ref($snapshot) eq 'HASH'
        && _non_empty($snapshot->{instance_id})
        && _non_empty($snapshot->{release_id})
        && _non_empty($snapshot->{template_fingerprint})
        && _non_empty($source_id)
        && ref($source_plan) eq 'HASH'
        && ($source_plan->{id} // '') eq $source_id
        && ref($scope) eq 'HASH'
        && ref($snapshot->{sources}) eq 'HASH'
        && defined($secret) && !ref($secret) && length($secret) >= 32;
    return _invalid() if grep { !_non_empty($scope->{$_}) }
        qw(tenant_id principal_id authorization_revision membership_revision);

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
        && _valid_page($source_plan, $snapshot->{state}, $result->{rows}, $result->{root_page});

    my $source_digest = eval { sha256_hex($JSON->encode($source_plan)) };
    return _invalid() if $@;
    my $bindings_digest = eval {
        sha256_hex($JSON->encode({
            input => $snapshot->{inputs}, state => $snapshot->{state},
        }))
    };
    return _invalid() if $@;
    my $config_digest = eval {
        sha256_hex($JSON->encode($result->{root_page}{config}))
    };
    return _invalid() if $@;
    return {
        status => 'ok', now => 0 + $now, ttl => 0 + $ttl,
        page => $result->{root_page},
        context => {
            schema => 'selecto.template.root-cursor.v1',
            instance_id => "$snapshot->{instance_id}",
            release_id => "$snapshot->{release_id}",
            template_fingerprint => "$snapshot->{template_fingerprint}",
            source_id => "$source_id",
            source_fingerprint => "sha256:$source_digest",
            config_fingerprint => "sha256:$config_digest",
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
    my ($source, $state, $rows, $page) = @_;
    return 0 unless ref($page) eq 'HASH';
    return 0 unless join(',', sort keys %$page) eq 'after_values,config,has_more';
    return 0 unless ref($page->{config}) eq 'HASH';
    return 0 unless JSON::PP::is_bool($page->{has_more});
    return 0 unless ref($source->{query}) eq 'HASH';
    my $config = $page->{config};
    my $query = $source->{query};
    my $orders = $query->{order_by};
    my $primary_key = $config->{primary_key};
    return 0 unless defined($primary_key) && !ref($primary_key);
    return 0 unless ref($query->{select}) eq 'ARRAY';
    return 0 unless scalar(grep { $_ eq $primary_key } @{$query->{select}});
    return 0 unless defined($query->{limit}) && !ref($query->{limit})
        && "$query->{limit}" =~ /\A[1-9][0-9]*\z/;
    return 0 unless defined($config->{page_size}) && !ref($config->{page_size})
        && $config->{page_size} == $query->{limit};
    return 0 if exists($query->{page});

    my $dynamic = $query->{ordering_choice};
    if (defined($dynamic)) {
        return 0 unless ref($dynamic) eq 'HASH'
            && ref($dynamic->{binding}) eq 'HASH'
            && ref($dynamic->{choices}) eq 'ARRAY'
            && ref($state) eq 'HASH'
            && ($dynamic->{binding}{expression} // '') =~ /\Astate\.([A-Za-z_][A-Za-z0-9_]*)\z/
            && defined($state->{$1}) && !ref($state->{$1})
            && grep { defined($_) && !ref($_) && $_ eq $state->{$1} }
                @{$dynamic->{choices}};
        $orders = $config->{order_by};
    }
    return 0 unless ref($orders) eq 'ARRAY' && @$orders;

    my @expected = @$orders;
    push @expected, {field => "$primary_key", direction => 'asc'}
        unless grep { ref($_) eq 'HASH' && ($_->{field} // '') eq $primary_key } @$orders;
    return 0 unless ref($config->{order_by}) eq 'ARRAY'
        && _same(\@expected, $config->{order_by});
    for my $order (@expected) {
        return 0 unless ref($order) eq 'HASH'
            && defined($order->{field}) && !ref($order->{field})
            && grep { $_ eq $order->{field} } @{$query->{select}};
    }
    my $projected = Selecto::Templates->project_root_cursor_page($config, $rows);
    return 0 if $projected->{status};
    return 0 if $page->{has_more} && @$rows != $config->{page_size};
    return !defined($page->{after_values}) unless $page->{has_more};
    return 0 unless ref($page->{after_values}) eq 'ARRAY' && @$rows;
    my $last = $rows->[-1];
    my $position = Selecto::Templates->root_cursor_position($config, $last);
    return 0 if $position->{status} ne 'ok';
    return _same($position->{after_values}, $page->{after_values});
}

sub _position { return {after_values => $_[0]->{after_values}}; }
sub _clone { return $JSON->decode($JSON->encode($_[0])); }
sub _same {
    my ($left, $right) = @_;
    my $equal = eval { $JSON->encode($left) eq $JSON->encode($right) };
    return $@ ? 0 : $equal;
}
sub _token {
    my ($context, $position, $expires_at, $secret) = @_;
    my $payload = $JSON->encode({
        context => $context, position => $position, expires_at => $expires_at,
    });
    return 'rc1.' . $expires_at . '.' . hmac_sha256_hex($payload, $secret);
}
sub _non_empty {
    my ($value) = @_;
    return defined($value) && !ref($value) && length("$value");
}
sub _invalid {
    return {
        status => 'error',
        schema => 'selecto.template.page-cursor-diagnostic.v1',
        code => 'invalid_root_cursor',
        message => 'root page cursor is invalid',
    };
}

1;
