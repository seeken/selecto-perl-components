package Selecto::Components::Canonical;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use POSIX qw(strftime);
use Selecto::API::Explorer ();
use Selecto::API::RemoteQuery ();
use Selecto::Components::WebSocketPolicy ();

# Register on the same host route bridge and use the exact explorer factory.
# Host callbacks own authentication and publication identity on every request.
sub register ($class, $routes, $config, $mounted_path) {
    for my $operation (qw(canonical_authorizer canonical_publication)) {
        die "$operation must be a host callback\n" unless ref($config->$operation) eq 'CODE';
    }
    my $respond = sub ($controller, $kind) {
        $controller->res->headers->cache_control('no-store, private');
        my $authorized = eval { $config->canonical_authorizer->($controller) };
        return _error($controller, 401, 'authentication_required') unless !$@ && defined($authorized)
            && !ref($authorized) && "$authorized" eq '1';
        if ($controller->req->method eq 'POST') {
            my $token = $controller->req->headers->header('X-CSRF-Token') // '';
            return _error($controller, 403, 'operation_forbidden') unless
                length($token) && Selecto::Components::WebSocketPolicy::valid_csrf($controller, $token)
                    && Selecto::Components::WebSocketPolicy::same_origin($controller);
        }
        my $response;
        my $ok = eval {
            my $request_config = $config->for_request($controller);
            my $engine = $request_config->engine($controller);
            my $host = Selecto::API::RemoteQuery->new(
                base_path => $config->canonical_api_path,
                limits => $request_config->limits->intersect($engine->limits),
                max_limit => $request_config->max_limit,
                default_limit => $request_config->default_limit,
                field_encodings => $config->canonical_field_encodings,
                publish_domain => $config->canonical_publish_domain,
            );
            my $publication = $config->canonical_publication->($controller, $engine);
            die "Invalid canonical publication\n" unless defined($publication)
                && !ref($publication) && length($publication) && length($publication) <= 4096;
            my $explorer = $config->canonical_explorer
                ? _explorer($config, $request_config, $engine, $publication, $controller) : undef;
            if ($explorer && ($kind eq 'explorer-features' || $kind eq 'explorer-query'
                || $kind eq '' || $kind eq '/')) {
                $response = $kind eq '' || $kind eq '/' ? $explorer->manifest_response($engine)
                    : $explorer->request($engine, {method => $controller->req->method,
                        path => $config->canonical_api_path . '/' . $kind,
                        content_type => $controller->req->headers->content_type,
                        accept => $controller->req->headers->accept, body => $controller->req->json});
                _add_catalog_routes($config, $response) if $kind eq '' || $kind eq '/';
            } elsif ($kind eq 'catalog') {
                $response = {status => 200, content_type => 'application/json; charset=utf-8',
                    body => JSON::PP->new->utf8->canonical->encode({
                        format => 'selecto.domain-catalog', format_version => 1,
                        domains => [{id => $config->id, label => $config->title, publication => $publication,
                            manifest => $config->canonical_api_path,
                            explorer_metadata => $config->canonical_api_path . '/explorer'}]})};
            } elsif ($kind eq 'explorer') {
                $response = {status => 200, content_type => 'application/json; charset=utf-8',
                    body => JSON::PP->new->utf8->canonical->encode($host->explorer_metadata($engine,
                        id => $config->id, label => $config->title, publication => $publication,
                        fields => $config->default_fields))};
            } else {
                $response = $host->request($engine, {method => $controller->req->method,
                    path => $config->canonical_api_path . $kind,
                    content_type => $controller->req->headers->content_type,
                    body => $controller->req->json});
                _add_catalog_routes($config, $response) if $kind eq '' || $kind eq '/';
            }
            1;
        };
        return _error($controller, 500, 'internal_failure') unless $ok;
        $controller->res->headers->content_type($response->{content_type}
            // $response->{headers}{'content-type'} // 'application/json; charset=utf-8');
        for my $header (qw(content-disposition x-content-type-options)) {
            my $value = ($response->{headers} // {})->{$header};
            $controller->res->headers->header($header => $value) if defined $value;
        }
        return $controller->render(data => $response->{body}, status => $response->{status});
    };
    for my $suffix ('', '/', '/domain', '/openapi.json', '/catalog', '/explorer') {
        my $kind = $suffix eq '/catalog' ? 'catalog' : $suffix eq '/explorer' ? 'explorer' : $suffix;
        $routes->get($mounted_path . $suffix)->to(cb => sub ($controller) { $respond->($controller, $kind) });
    }
    $routes->post($mounted_path . '/query')->to(cb => sub ($controller) { $respond->($controller, '/query') });
    if ($config->canonical_explorer) {
        $routes->get($mounted_path . '/explorer-features')
            ->to(cb => sub ($controller) { $respond->($controller, 'explorer-features') });
        $routes->post($mounted_path . '/explorer-query')
            ->to(cb => sub ($controller) { $respond->($controller, 'explorer-query') });
    }
}

sub _add_catalog_routes ($config, $response) {
    return unless $response->{status} == 200;
    my $manifest = JSON::PP->new->utf8->decode($response->{body});
    push @{$manifest->{routes}},
        {method => 'GET', path => $config->canonical_api_path . '/catalog', operation_id => 'getDomainCatalog'},
        {method => 'GET', path => $config->canonical_api_path . '/explorer', operation_id => 'getExplorerMetadata'};
    $response->{body} = JSON::PP->new->utf8->canonical->encode($manifest);
}

# The explorer host for this request: the explorer's engine limits and
# paging, the host's trusted clock and options, and the request's publication.
sub _explorer ($config, $request_config, $engine, $publication, $controller) {
    my %options = %{$config->canonical_explorer};
    my $clock = ref($options{clock}) eq 'CODE' ? $options{clock}->($controller)
        : $options{clock} // strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
    my %limits = (max_limit => $request_config->max_limit, %{$options{limits} // {}});
    return Selecto::API::Explorer->new(
        base_path => $config->canonical_api_path, id => $config->id, label => $config->title,
        publication => $publication, clock => $clock,
        default_limit => $request_config->default_limit, limits => \%limits,
        engine_limits => $request_config->limits->intersect($engine->limits),
        publish_domain => $config->canonical_publish_domain,
        (map { exists($options{$_}) ? ($_ => $options{$_}) : () }
            qw(count_exact collection_limit supports services links)),
    );
}

sub _error ($controller, $status, $code) {
    return $controller->render(status => $status, json => {ok => JSON::PP::false,
        error => {code => $code, message => 'Request could not be completed.', details => {}}});
}

1;

=head1 NAME

Selecto::Components::Canonical - canonical reads on an explorer's trusted engine

=head1 DESCRIPTION

Configure C<canonical_api_path>, C<canonical_authorizer>, and
C<canonical_publication> on an explorer to register its canonical manifest,
catalog, metadata and query endpoints. Both transports use that explorer's
fresh engine factory and the core bounded reader. JSON POSTs require the
current session's X-CSRF-Token and same-origin policy. Publication identifiers
are host-derived cache identities, never row authority. Complete domain
publication requires C<canonical_publish_domain =E<gt> 1>.

Set C<canonical_explorer> to a hash of explorer host options (C<clock>,
C<count_exact>, C<limits>, C<collection_limit>, C<supports>, C<services>,
C<links>) to add C<remote_query.explorer.v1>: C<GET .../explorer-features>
and C<POST .../explorer-query> over L<Selecto::API::Explorer>, advertised in
the manifest. The explorer POST has the same X-CSRF-Token and same-origin
rules as C<POST .../query>. C<clock> is the trusted instant "today" is taken
from (an RFC 3339 string or a callback receiving the controller; default the
server clock).

=cut
