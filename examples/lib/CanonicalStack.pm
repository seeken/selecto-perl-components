package CanonicalStack;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::File qw(path);
use Mojo::Util qw(xml_escape);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use DBI;
use Selecto;
use Selecto::Components;
use Selecto::Components::APIConsole;
use Selecto::Components::WebSocketPolicy;
use Selecto::API::Spa;

has workspace => sub { path(__FILE__)->to_abs->dirname->dirname->dirname->dirname->to_string };
has database_url => sub { $ENV{SELECTO_PERL_STACK_POSTGRES_URL} };
# An independently authored seed of the same shape may replace the protocol corpus copy.
has seed_path => sub ($self) { $ENV{SELECTO_PERL_STACK_SEED}
    // path($self->workspace, 'selecto-protocol/spec/fixtures/detail/pilot-seed.v1.json')->to_string };
# SELECTO_PERL_STACK_EXPLORER=1 also serves remote_query.explorer.v1 on the
# canonical base (canonical_explorer; SELECTO_PERL_STACK_CLOCK pins "today").
# SELECTO_PERL_STACK_SPA_ROUTES=1 mounts the selecto.spa/v1 routes
# (Selecto::API::Spa) at /api/spa as a reference: the same SPA request runs on
# both transports against the same session-scoped engine.
has explorer => sub { ($ENV{SELECTO_PERL_STACK_EXPLORER} // '') eq '1' };
has spa_routes => sub { ($ENV{SELECTO_PERL_STACK_SPA_ROUTES} // '') eq '1' };

sub connection ($self) {
    my $url = Mojo::URL->new($self->database_url // '');
    my $database = substr($url->path, 1);
    die "An owned selecto_perl_stack PostgreSQL database is required\n"
        unless ($url->scheme // '') =~ /\Apostgres(?:ql)?\z/
            && $database =~ /\Aselecto_perl_stack_[A-Za-z0-9_]+\z/;
    return DBI->connect('dbi:Pg:dbname=' . $database . ';host=' . $url->host . ';port=' . $url->port,
        $url->username, $url->password // '', {RaiseError => 1, PrintError => 0, pg_enable_utf8 => 1});
}

sub seed ($self) {
    return decode_json(path($self->seed_path)->slurp);
}

sub setup_database ($self) {
    my $dbh = $self->connection;
    $dbh->begin_work;
    my $ok = eval {
        # Deliberately no IF NOT EXISTS, DROP, TRUNCATE or reseed. An existing
        # fixture is a conflict, not permission to replace another run's data.
        $dbh->do('CREATE TABLE canonical_stack_items (tenant_id INTEGER NOT NULL,
            id INTEGER NOT NULL, name TEXT NOT NULL, amount NUMERIC NOT NULL,
            active BOOLEAN NOT NULL, note TEXT, large_integer BIGINT NOT NULL,
            due_on DATE NOT NULL, secret TEXT NOT NULL, PRIMARY KEY (tenant_id,id))');
        my $seed = $self->seed;
        for my $pair ([alpha => 1], [beta => 2]) {
            for my $row (@{$seed->{tenants}{$pair->[0]}}) {
                $dbh->do('INSERT INTO canonical_stack_items VALUES (?,?,?,?,?,?,?,?,?)', undef,
                    $pair->[1], @{$row}{qw(id name amount)}, $row->{active} ? 1 : 0,
                    @{$row}{qw(note large_integer due_on secret)});
            }
        }
        $dbh->commit;
        1;
    };
    my $error = $@;
    eval { $dbh->rollback } unless $ok;
    $dbh->disconnect;
    die $error unless $ok;
}

sub domain ($self) {
    my $seed = $self->seed;
    my @fields = map { $_->{id} } @{$seed->{fields}};
    my $contract = {schema_version => 1, domain_version => '1.0.0', name => 'Perl PostgreSQL Items',
        source => {source_table => 'canonical_stack_items', primary_key => 'id', tenant_field => 'tenant_id',
            fields => [@fields, qw(tenant_id secret)],
            columns => {map({$_->{id} => {type => $_->{type}, nullable => $_->{nullable}, label => $_->{id}}} @{$seed->{fields}}),
                tenant_id => {type => 'integer', internal => 1}, secret => {type => 'string', internal => 1}},
            associations => {}}, schemas => {}, joins => {}};
    $contract->{domain_fingerprint} = 'sha256:' . sha256_hex(Selecto::API::canonical_json($contract));
    return Selecto::Domain->parse($contract, strict => 1);
}

sub startup ($self) {
    die "Canonical stack is a disposable development/test example\n"
        unless $self->mode eq 'development' || $self->mode eq 'test';
    $self->max_request_size(131_072);
    $self->secrets([$ENV{MOJO_SECRET} // 'canonical-stack-disposable-development-only']);
    $self->sessions->samesite('Lax');
    $self->hook(after_dispatch => sub ($c) {
        $c->res->headers->cache_control('no-store, private');
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('Content-Security-Policy' =>
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    });
    my $routes = $self->routes;
    $routes->get('/up')->to(cb => sub ($c) { $c->render(text => 'ok') });
    $routes->get('/session')->to(cb => sub ($c) {
        $c->render(data => '<!doctype html><html><head><title>Choose demo session</title></head><body>'
            . '<h1>Choose demo session</h1><form method="post" action="/session">'
            . '<input type="hidden" name="csrf_token" value="' . xml_escape($c->csrf_token) . '">'
            . '<button name="actor" value="alpha">Alpha</button><button name="actor" value="beta">Beta</button>'
            . '</form></body></html>', format => 'html');
    });
    $routes->post('/session')->to(cb => sub ($c) {
        return $c->render(text => 'Request refused', status => 403)
            unless Selecto::Components::WebSocketPolicy::valid_csrf($c, $c->param('csrf_token'))
                && Selecto::Components::WebSocketPolicy::same_origin($c);
        my $actor = $c->param('actor') // '';
        return $c->render(text => 'Unknown demo session', status => 422) unless $actor =~ /\A(?:alpha|beta)\z/;
        $c->session(actor => $actor);
        $c->redirect_to('/explore/items');
    });
    $routes->post('/logout')->to(cb => sub ($c) {
        return $c->render(text => 'Request refused', status => 403)
            unless Selecto::Components::WebSocketPolicy::valid_csrf($c, $c->param('csrf_token'));
        $c->session(expires => 1);
        $c->redirect_to('/session');
    });
    my $protected = $routes->under(sub ($c) {
        return 1 if $c->session('actor') || $c->req->url->path->to_string =~ m{\A/api/};
        $c->redirect_to('/session');
        return undef;
    });
    my $factory = sub ($c) {
        my $actor = $c->session('actor');
        die "An authenticated demo session is required\n" unless defined($actor) && $actor =~ /\A(?:alpha|beta)\z/;
        if (!$self->{_adapter} || $self->{_adapter_pid} != $$) {
            $self->{_adapter} = Selecto->adapter(postgresql => dbh => $self->connection);
            $self->{_adapter_pid} = $$;
        }
        return Selecto::Engine->new(domain => $self->domain, adapter => $self->{_adapter},
            scope => {tenant => $actor eq 'alpha' ? 1 : 2});
    };
    $self->plugin('Selecto::Components' => {
        route_bridge => {routes => $protected, prefix => ''},
        websocket_context => sub ($c, @) { $c->session('actor') },
        explorers => {items => {path => '/explore/items', title => 'Perl PostgreSQL Items',
            engine_factory => $factory, default_fields => [map { $_->{id} } @{$self->seed->{fields}}],
            default_limit => 2, max_limit => 100,
            canonical_api_path => '/api/items', canonical_publish_domain => 1,
            api_console_resolver => sub ($c, $config, $model) { '/api/items/console' },
            canonical_authorizer => sub ($c) { return ($c->session('actor') // '') =~ /\A(?:alpha|beta)\z/ ? 1 : 0 },
            canonical_publication => sub ($c, $engine) {
                return 'publication:' . hmac_sha256_hex(encode_json([$c->session('actor'), $engine->domain->fingerprint]), $self->secrets->[0]);
            }, canonical_field_encodings => {large_integer => 'decimal-string'},
            ($self->explorer ? (canonical_explorer => {count_exact => 1,
                links => {api_console => '/api/items/console'},
                ($ENV{SELECTO_PERL_STACK_CLOCK} ? (clock => $ENV{SELECTO_PERL_STACK_CLOCK}) : ())}) : ()),
        }},
    });
    $self->_spa_routes($protected, $factory) if $self->spa_routes;
    $protected->get('/api/items/console')->to(cb => sub ($c) {
        return $c->redirect_to('/session')
            unless ($c->session('actor') // '') =~ /\A(?:alpha|beta)\z/;
        $c->render(data => Selecto::Components::APIConsole->page(
            base_path => '/api/items', title => 'Perl PostgreSQL API Console',
            csrf_token => $c->csrf_token,
            page_shell => {body_start_html => '<nav><a href="/explore/items">Explorer</a> | ' . join(' | ', map { qq{<a href="/$_">\u$_</a>} } qw(vue react angular svelte solid)) . '</nav>'},
        ), format => 'html');
    });
    $protected->get('/')->to(cb => sub ($c) { $c->redirect_to('/explore/items') });
    # Every SPA build uses the shared canonical adapter against /api/items
    # (selecto_spa_<name>: npm run build:canonical, dist/perl-postgres).
    my @spa = qw(vue react angular svelte solid);
    my %spa = map { ("spa-$_" => "selecto_spa_$_/dist/perl-postgres") } @spa;
    for my $name (@spa) {
        $protected->get("/$name")->to(cb => sub ($c) { $c->redirect_to("/spa-$name/index.html") });
    }
    $protected->get('/:spa/*file' => [spa => [sort keys %spa]])->to(cb => sub ($c) {
        my $file = $c->stash('file');
        # Vite builds emit assets/; Angular emits hashed bundles beside index.html.
        return $c->reply->not_found unless $file =~ /\A(?:index\.html|(?:assets\/)?[A-Za-z0-9_][A-Za-z0-9_.-]*\.(?:js|css))\z/;
        my $asset = path($self->workspace, $spa{$c->stash('spa')}, $file);
        return $c->reply->not_found unless -f $asset;
        if ($file eq 'index.html') {
            my $html = $asset->slurp;
            my $csrf = xml_escape($c->csrf_token);
            $html =~ s/<!-- SELECTO_CSRF -->/<meta name="csrf-token" content="$csrf">/;
            return $c->render(data => $html, format => 'html');
        }
        return $c->reply->file($asset);
    });
}

# The SPA protocol over the same session-scoped engine. Descriptor field ids
# follow the SPA convention (source.<path>), as the explorer client's
# descriptors do, so one SPA request runs unchanged on both transports.
sub _spa_routes ($self, $routes, $factory) {
    my @compare = qw(equals not_equals greater_than greater_than_or_equal less_than less_than_or_equal between in not_in is_null is_not_null);
    my %operators = (boolean => [qw(equals not_equals is_null is_not_null)], string => [@compare, qw(contains starts_with ends_with)]);
    my %aggregates = (integer => [qw(count count_distinct sum avg min max)], decimal => [qw(count count_distinct sum avg min max)],
        boolean => [qw(count count_distinct)]);
    my $descriptor = {schema => 'selecto.spa.domain-descriptor/v1', schemaVersion => 1, id => 'items',
        name => 'Perl PostgreSQL Items', source => 'canonical_stack_items',
        capabilities => [qw(detail aggregate graph aggregate_grid)],
        views => [map { +{id => $_, kind => $_, label => ucfirst} } qw(detail aggregate graph)],
        fields => [map { my $f = $_; +{id => "source.$f->{id}", label => $f->{id}, type => $f->{type} eq 'string' ? 'text' : $f->{type},
            groupable => Mojo::JSON::true, aggregatable => Mojo::JSON::true,
            aggregateFunctions => $aggregates{$f->{type}} // [qw(count count_distinct min max)],
            filterOperators => $operators{$f->{type}} // \@compare} } @{$self->seed->{fields}}]};
    my $spa = Selecto::API::Spa->new(base_path => '/api/spa', domains => [{descriptor => $descriptor,
        domain => $self->domain, engine => sub ($c) { $factory->($c) }}]);
    $routes->any([qw(GET POST)] => '/api/spa/*spa_path')->to(cb => sub ($c) {
        return $c->render(status => 403, json => {error => 'Request refused'})
            if $c->req->method eq 'POST' && !(Selecto::Components::WebSocketPolicy::valid_csrf($c, $c->req->headers->header('X-CSRF-Token'))
                && Selecto::Components::WebSocketPolicy::same_origin($c));
        my $response = $spa->request({method => $c->req->method, path => $c->req->url->path->to_string,
            body => $c->req->json, context => $c});
        $c->render(status => $response->{status}, json => $response->{json});
    });
}

1;
