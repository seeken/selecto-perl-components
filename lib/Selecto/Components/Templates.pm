package Selecto::Components::Templates;

use Mojolicious 9.49 ();
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::File qw(path);
use Mojo::IOLoop ();
use Time::HiRes qw(time);
use Selecto::Components::Controller::Templates ();
use Selecto::Components::Templates::Dispatcher ();
use Selecto::Components::Templates::Native ();
use Selecto::Components::Templates::PublicInputs ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Templates::SourceScheduler ();
use Selecto::Components::Templates::Transport ();
use Selecto::Components::Templates::WebSocket ();
use Selecto::Components::WebSocketPolicy ();

=head1 NAME

Selecto::Components::Templates - Mojolicious routes for native Selecto templates

=head1 DESCRIPTION

This additive plugin mounts server-owned compiled templates. The host resolves
the authenticated owner scope and supplies renderer and source-authority
callbacks. Browser requests carry opaque instance references and declared event
values; they never carry a manifest, query, adapter, or owner scope.

=head1 SOURCE AUTHORIZERS RUN IN A FORKED CHILD

B<Every template C<source_authorizer> (and C<source_runner>) runs in a child
process forked by L<Selecto::Components::Templates::SourceScheduler>. The
authorizer must open a fresh database connection inside that child and must
never return an engine whose adapter wraps a DBI handle created in the parent
(web worker) process.> A forked child shares the parent's socket; using an
inherited handle interleaves protocol traffic between processes, can return one
request's rows to another, and destroys the parent's session state when the
child exits.

Build the handle inside the callback, for example with C<< DBI->connect(...) >>
(not C<connect_cached> on a parent-populated cache, and not a handle captured
from the enclosing scope). If you mark handles with
C<< $dbh->{private_selecto_pid} = $$ >> when connecting, the executor rejects an
engine whose handle was created in another process with
C<source_connection_inherited>. See
L<Selecto::Components::Templates::SourceExecutor/"Database connections in the child">.

=head1 CONFIGURATION

Resource limits relevant to production:

=over 4

=item source_max_workers

Concurrent source subprocesses per web worker process. Default 4, at most 64.

=item source_max_workers_per_owner

Concurrent source subprocesses one owner scope may hold in this process.
Default C<max(1, int(source_max_workers / 2))>, i.e. 2 with the default pool;
must not exceed C<source_max_workers>. Owners are identified by a SHA-256 digest
of the canonical owner scope returned by C<resolve_owner>, so the scope should
identify the principal you want to limit (tenant and actor, not a per-request
value). A request over either limit receives HTTP 409 with
C<source_workers_busy> or C<source_owner_workers_busy>.

Page and root-page requests claim the C<(source, generation, page)> they
continue through the instance store before any subprocess is spawned. A
duplicate request for the same in-flight page receives HTTP 409
C<page_request_in_progress> instead of running the query again.

=item max_instances_per_owner

Live template instances one owner scope may hold. Every C<GET> of a template
mounts a new instance; when the owner is at the cap, mounting evicts that
owner's oldest live instances (and their effect claims) and its expired ones.
When omitted, the store default applies (32 for the bundled Memory and
PostgreSQL stores). Custom stores receive the value as the
C<max_instances_per_owner> argument of C<create>.

=item cleanup_interval_seconds

Interval for the periodic C<cleanup_expired> and C<cleanup_expired_claims>
store sweeps. Default 300 seconds; C<0> disables the timer (for hosts that run
the sweeps from their own scheduler). Each sweep is bounded by the store's
C<cleanup_limit>. The timer runs in every web worker process and never in a
forked source worker.

=back

Oversized state (an event value or source result that would make the stored
snapshot exceed the store's C<max_snapshot_bytes>) returns HTTP 422 with
C<snapshot_too_large> and the fixed message C<Template state is too large.>

=cut

sub register ($self, $app, $plugin_config) {
    $plugin_config //= {};
    die "Selecto::Components::Templates configuration must be an object\n"
        unless ref($plugin_config) eq 'HASH';
    my $store = $plugin_config->{store};
    die "Selecto::Components::Templates requires an instance store\n"
        unless ref($store);
    my $resolve_owner = $plugin_config->{resolve_owner};
    die "Selecto::Components::Templates requires a resolve_owner callback\n"
        unless ref($resolve_owner) eq 'CODE';
    my $origin_check = $plugin_config->{origin_check}
        // \&Selecto::Components::WebSocketPolicy::same_origin;
    die "origin_check must be a coderef\n" unless ref($origin_check) eq 'CODE';
    my $websocket_inactivity_timeout = _positive_integer_range(
        $plugin_config->{websocket_inactivity_timeout} // 3600,
        30, 86_400, 'websocket_inactivity_timeout',
    );
    my $websocket_heartbeat_interval = _websocket_heartbeat(
        $plugin_config->{websocket_heartbeat_interval} // 30,
        $websocket_inactivity_timeout,
    );
    my $source_timeout_seconds = _positive_number(
        $plugin_config->{source_timeout_seconds} // 15, 300,
        'source_timeout_seconds',
    );
    my $source_scheduler = $plugin_config->{source_scheduler};
    if (defined($source_scheduler)) {
        die "source_scheduler must provide execute\n"
            unless ref($source_scheduler) && $source_scheduler->can('execute');
    }
    else {
        my $max_workers = _positive_integer(
            $plugin_config->{source_max_workers} // 4, 64,
            'source_max_workers',
        );
        my $default_per_owner = int($max_workers / 2) || 1;
        $source_scheduler = Selecto::Components::Templates::SourceScheduler->new(
            max_workers => $max_workers,
            max_workers_per_owner => _positive_integer(
                $plugin_config->{source_max_workers_per_owner} // $default_per_owner,
                $max_workers, 'source_max_workers_per_owner',
            ),
            timeout_seconds => $source_timeout_seconds,
            max_payload_bytes => _positive_integer(
                $plugin_config->{source_max_payload_bytes} // 1_048_576,
                16_777_216, 'source_max_payload_bytes',
            ),
            max_result_bytes => _positive_integer(
                $plugin_config->{source_max_result_bytes} // 1_048_576,
                16_777_216, 'source_max_result_bytes',
            ),
        );
    }
    my $templates = _templates(
        $plugin_config->{templates}, $source_timeout_seconds,
    );
    my $template_path = _path(
        $plugin_config->{template_path} // '/templates', 'template_path',
    );
    my $instance_path = _path(
        $plugin_config->{instance_path} // '/template-instances', 'instance_path',
    );
    my $clock = $plugin_config->{clock} // sub { time() };
    die "clock must be a coderef\n" unless ref($clock) eq 'CODE';
    my $event_id_generator = $plugin_config->{event_id_generator} // \&_opaque_id;
    die "event_id_generator must be a coderef\n"
        unless ref($event_id_generator) eq 'CODE';
    my $max_instances_per_owner = defined($plugin_config->{max_instances_per_owner})
        ? _positive_integer(
            $plugin_config->{max_instances_per_owner}, 10_000,
            'max_instances_per_owner',
        ) : undef;
    my $cleanup_interval = _non_negative_integer(
        $plugin_config->{cleanup_interval_seconds} // 300, 86_400,
        'cleanup_interval_seconds',
    );

    _install_assets($app) unless exists($plugin_config->{install_assets})
        && !$plugin_config->{install_assets};

    my $dispatcher = Selecto::Components::Templates::Dispatcher->new(
        store => $store,
        (defined($max_instances_per_owner)
            ? (max_instances_per_owner => $max_instances_per_owner) : ()),
    );
    _schedule_cleanup($app, $store, $cleanup_interval) if $cleanup_interval;
    my $transport = Selecto::Components::Templates::Transport->new(
        template_path => $template_path,
        instance_path => $instance_path,
        event_id_generator => $event_id_generator,
        clock => $clock,
    );
    my %by_release = map { $templates->{$_}{release_id} => $templates->{$_} }
        keys %$templates;
    my $runtime = {
        dispatcher => $dispatcher,
        transport => $transport,
        templates => $templates,
        templates_by_release => \%by_release,
        resolve_owner => $resolve_owner,
        source_scheduler => $source_scheduler,
        origin_check => $origin_check,
        websocket_inactivity_timeout => $websocket_inactivity_timeout,
        websocket_heartbeat_interval => $websocket_heartbeat_interval,
        clock => $clock,
    };
    my $native = Selecto::Components::Templates::Native->new(runtime => $runtime);
    $app->helper(selecto_template_model => sub ($controller, %args) {
        return $native->model($controller, %args);
    });
    $app->helper(selecto_template_dispatch_event => sub ($controller, %args) {
        return $native->dispatch_event($controller, %args);
    });
    $app->helper(selecto_template_dispatch_source => sub ($controller, %args) {
        return $native->dispatch_source($controller, %args);
    });
    $app->helper(selecto_template_websocket => sub ($controller, %args) {
        return $native->websocket($controller, %args);
    });

    $app->routes->get("$template_path/:selecto_template_id")->to(cb => sub ($controller) {
        return Selecto::Components::Controller::Templates->show($controller, $runtime);
    });
    $app->routes->get("$instance_path/:selecto_template_instance_id")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Controller::Templates->reopen($controller, $runtime);
        });
    $app->routes->post("$instance_path/:selecto_template_instance_id/events")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Controller::Templates->event($controller, $runtime);
        });
    $app->routes
        ->post("$instance_path/:selecto_template_instance_id/sources/:selecto_template_source_id")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Controller::Templates->source($controller, $runtime);
        });
    $app->routes
        ->post("$instance_path/:selecto_template_instance_id/pages/:selecto_template_source_id")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Controller::Templates->page($controller, $runtime);
        });
    $app->routes
        ->post("$instance_path/:selecto_template_instance_id/root-pages/:selecto_template_source_id")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Controller::Templates->root_page($controller, $runtime);
        });
    $app->routes->websocket("$instance_path/:selecto_template_instance_id/ws")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Templates::WebSocket->connect(
                $controller, $runtime,
            );
        });
}

sub _schedule_cleanup ($app, $store, $interval) {
    my @tasks = grep { $store->can($_) } qw(cleanup_expired cleanup_expired_claims);
    return undef unless @tasks;
    my $log = $app->log;
    return Mojo::IOLoop->recurring($interval => sub {
        # Forked source workers reset their event loop, but never run
        # housekeeping from one even if a timer survives the fork.
        return if Selecto::Components::Templates::SourceScheduler->in_worker;
        for my $task (@tasks) {
            my $removed = eval { $store->$task };
            if (my $error = $@) {
                $error = "$error";
                $error =~ s/\s+\z//;
                $log->warn("Selecto template $task failed: $error");
                next;
            }
            $log->debug("Selecto template $task removed $removed rows")
                if $removed;
        }
    });
}

sub _templates ($specs, $default_source_timeout_seconds) {
    die "Selecto::Components::Templates requires a templates object\n"
        unless ref($specs) eq 'HASH' && keys %$specs;
    my (%templates, %releases);
    for my $id (sort keys %$specs) {
        die "template ID $id is invalid\n"
            unless $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/;
        my $spec = $specs->{$id};
        die "template $id configuration must be an object\n"
            unless ref($spec) eq 'HASH';
        my $manifest = $spec->{manifest};
        my $release = $spec->{release_id};
        my $registry = $spec->{registry};
        die "template $id requires a compiled manifest\n"
            unless ref($manifest) eq 'HASH';
        die "template $id requires a release_id\n"
            unless _scalar($release, 256);
        die "template release_id $release is configured more than once\n"
            if $releases{$release}++;
        die "template $id requires a renderer registry\n"
            unless ref($registry) eq 'HASH';
        eval { Selecto::Components::Templates::Renderer->validate_manifest($manifest); 1 }
            or die "template $id manifest is unsafe: $@";
        for my $callback (qw(resolve_inputs resolve_source_context resolve_page_scope source_authorizer source_runner)) {
            die "template $id $callback must be a coderef\n"
                if defined($spec->{$callback}) && ref($spec->{$callback}) ne 'CODE';
        }
        my $has_sources = ref($manifest->{sources}) eq 'ARRAY'
            && @{$manifest->{sources}};
        my $root_sources = $spec->{root_cursor_sources} // [];
        die "template $id root_cursor_sources must be a list of declared source IDs\n"
            unless ref($root_sources) eq 'ARRAY';
        my %declared_sources = map { ($_->{id} // '') => $_ }
            grep { ref($_) eq 'HASH' }
            @{ref($manifest->{sources}) eq 'ARRAY' ? $manifest->{sources} : []};
        my %seen_root_sources;
        for my $source_id (@$root_sources) {
            die "template $id root_cursor_sources contains an invalid source\n"
                unless _scalar($source_id, 128)
                && !$seen_root_sources{$source_id}++
                && ref($declared_sources{$source_id}) eq 'HASH';
            my $query = $declared_sources{$source_id}{query};
            die "template $id root cursor source $source_id has no keyset root query\n"
                unless ref($query) eq 'HASH'
                && ref($query->{select}) eq 'ARRAY'
                && ref($query->{order_by}) eq 'ARRAY'
                && (@{$query->{order_by}}
                    || (ref($query->{ordering_choice}) eq 'HASH'
                        && ref($query->{ordering_choice}{choices}) eq 'ARRAY'
                        && @{$query->{ordering_choice}{choices}}
                        && ref($query->{ordering_choice}{binding}) eq 'HASH'))
                && defined($query->{limit}) && !ref($query->{limit})
                && "$query->{limit}" =~ /\A[1-9][0-9]*\z/
                && !exists($query->{page});
        }
        die "template $id requires source_authorizer for its declared sources\n"
            if $has_sources && ref($spec->{source_authorizer}) ne 'CODE';
        if (_manifest_has_pages($manifest) || @$root_sources) {
            die "template $id requires a page_secret of at least 32 bytes\n"
                unless defined($spec->{page_secret}) && !ref($spec->{page_secret})
                && length($spec->{page_secret}) >= 32;
            die "template $id requires resolve_page_scope for its paged sources\n"
                unless ref($spec->{resolve_page_scope}) eq 'CODE';
        }
        my $ttl_seconds = _positive_integer(
            $spec->{ttl_seconds} // 3600, 86_400,
            "template $id ttl_seconds",
        );
        my $lease_seconds = _positive_integer(
            $spec->{lease_seconds} // 30, 300,
            "template $id lease_seconds",
        );
        my $source_timeout_seconds = _positive_number(
            $spec->{source_timeout_seconds} // $default_source_timeout_seconds,
            300, "template $id source_timeout_seconds",
        );
        my $source_resource_budget = _source_resource_budget(
            $spec->{source_resource_budget}, "template $id source_resource_budget",
        );
        die "template $id source_timeout_seconds must be less than lease_seconds\n"
            if $has_sources && $source_timeout_seconds >= $lease_seconds;
        my $public_inputs = Selecto::Components::Templates::PublicInputs->configure(
            $manifest, $spec->{public_inputs}, $id,
        );
        $templates{$id} = {
            %$spec,
            id => "$id",
            release_id => "$release",
            ttl_seconds => $ttl_seconds,
            lease_seconds => $lease_seconds,
            source_timeout_seconds => $source_timeout_seconds,
            source_resource_budget => $source_resource_budget,
            public_inputs => $public_inputs,
            title => _scalar($spec->{title}, 256) ? "$spec->{title}" : "$id",
        };
    }
    return \%templates;
}

sub _manifest_has_pages ($manifest) {
    return 0 unless ref($manifest->{sources}) eq 'ARRAY';
    for my $source (@{$manifest->{sources}}) {
        next unless ref($source) eq 'HASH'
            && ref($source->{query}) eq 'HASH';
        return 1 if _collection_has_page($source->{query}{collections});
    }
    return 0;
}

sub _collection_has_page ($collections) {
    return 0 unless ref($collections) eq 'ARRAY';
    for my $collection (@$collections) {
        next unless ref($collection) eq 'HASH';
        return 1 if exists($collection->{page_size});
        return 1 if _collection_has_page($collection->{collections});
    }
    return 0;
}

sub _source_resource_budget ($value, $name) {
    return undef unless defined($value);
    die "$name must be an object\n" unless ref($value) eq 'HASH';
    my %maximum = (
        max_root_rows => 10_000,
        max_result_nodes => 1_000_000,
        max_collection_depth => 8,
        max_source_statements => 32,
        max_input_bytes => 16_777_216,
        max_result_bytes => 16_777_216,
    );
    my %budget;
    for my $key (keys %$value) {
        die "$name has an unknown field $key\n" unless exists($maximum{$key});
        $budget{$key} = _positive_integer($value->{$key}, $maximum{$key}, "$name $key");
    }
    return \%budget;
}

sub _path ($value, $name) {
    die "$name must be an absolute path without a trailing slash\n"
        unless defined($value) && !ref($value)
        && "$value" =~ m{\A/[A-Za-z0-9/_-]*[A-Za-z0-9_-]\z};
    return "$value";
}

sub _positive_integer ($value, $max, $name) {
    die "$name must be an integer between 1 and $max\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A[1-9][0-9]*\z/ && $value <= $max;
    return 0 + $value;
}

sub _non_negative_integer ($value, $max, $name) {
    die "$name must be an integer between 0 and $max\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A[0-9]+\z/ && $value <= $max;
    return 0 + $value;
}

sub _positive_number ($value, $max, $name) {
    die "$name must be a number greater than 0 and at most $max\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/
        && $value > 0 && $value <= $max;
    return 0 + $value;
}

sub _positive_integer_range ($value, $min, $max, $name) {
    die "$name must be an integer between $min and $max\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A[0-9]+\z/ && $value >= $min && $value <= $max;
    return 0 + $value;
}

sub _websocket_heartbeat ($value, $inactivity_timeout) {
    die "websocket_heartbeat_interval must be 0 or an integer between 15 and 300 seconds\n"
        unless defined($value) && !ref($value) && "$value" =~ /\A[0-9]+\z/
        && ($value == 0 || $value >= 15 && $value <= 300);
    die "websocket_heartbeat_interval must be less than websocket_inactivity_timeout\n"
        if $value && $value >= $inactivity_timeout;
    return 0 + $value;
}

sub _scalar ($value, $max) {
    return defined($value) && !ref($value) && length("$value")
        && length("$value") <= $max;
}

sub _install_assets ($app) {
    my $module_lib = path(__FILE__)->to_abs->dirname->dirname->dirname;
    my @public_candidates = (
        $module_lib->dirname->child('public'),
        $module_lib->child('auto', 'share', 'dist', 'Selecto-Components', 'public'),
    );
    my ($public_path) = grep { -d $_ } @public_candidates;
    die "Selecto::Components packaged browser assets were not found\n"
        unless $public_path;
    my $path_string = $public_path->to_string;
    unshift @{$app->static->paths}, $path_string
        unless grep { $_ eq $path_string } @{$app->static->paths};
}

sub _opaque_id {
    open my $random, '<:raw', '/dev/urandom'
        or die "event_id_unavailable: secure random source is unavailable\n";
    my $bytes = '';
    my $read = read($random, $bytes, 16);
    close $random;
    die "event_id_unavailable: secure random source is unavailable\n"
        unless defined($read) && $read == 16;
    return unpack('H*', $bytes);
}

1;
