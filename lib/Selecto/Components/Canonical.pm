package Selecto::Components::Canonical;

use Mojo::Base -base, -signatures;
use JSON::PP ();
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
            if ($kind eq 'catalog') {
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
            }
            1;
        };
        return _error($controller, 500, 'internal_failure') unless $ok;
        $controller->res->headers->content_type($response->{content_type}
            // $response->{headers}{'content-type'} // 'application/json; charset=utf-8');
        return $controller->render(data => $response->{body}, status => $response->{status});
    };
    for my $suffix ('', '/', '/domain', '/openapi.json', '/catalog', '/explorer') {
        my $kind = $suffix eq '/catalog' ? 'catalog' : $suffix eq '/explorer' ? 'explorer' : $suffix;
        $routes->get($mounted_path . $suffix)->to(cb => sub ($controller) { $respond->($controller, $kind) });
    }
    $routes->post($mounted_path . '/query')->to(cb => sub ($controller) { $respond->($controller, '/query') });
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

=cut
