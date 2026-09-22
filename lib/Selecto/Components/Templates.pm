package Selecto::Components::Templates;

use Mojolicious 9.49 ();
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::File qw(path);
use Time::HiRes qw(time);
use Selecto::Components::Controller::Templates ();
use Selecto::Components::Templates::Dispatcher ();
use Selecto::Components::Templates::PublicInputs ();
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
        $source_scheduler = Selecto::Components::Templates::SourceScheduler->new(
            max_workers => _positive_integer(
                $plugin_config->{source_max_workers} // 4, 64,
                'source_max_workers',
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

    _install_assets($app) unless exists($plugin_config->{install_assets})
        && !$plugin_config->{install_assets};

    my $dispatcher = Selecto::Components::Templates::Dispatcher->new(store => $store);
    my $transport = Selecto::Components::Templates::Transport->new(
        template_path => $template_path,
        instance_path => $instance_path,
        event_id_generator => $event_id_generator,
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

    $app->routes->get("$template_path/:selecto_template_id")->to(cb => sub ($controller) {
        return Selecto::Components::Controller::Templates->show($controller, $runtime);
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
    $app->routes->websocket("$instance_path/:selecto_template_instance_id/ws")
        ->to(cb => sub ($controller) {
            return Selecto::Components::Templates::WebSocket->connect(
                $controller, $runtime,
            );
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
        for my $callback (qw(resolve_inputs resolve_source_context source_authorizer source_runner)) {
            die "template $id $callback must be a coderef\n"
                if defined($spec->{$callback}) && ref($spec->{$callback}) ne 'CODE';
        }
        my $has_sources = ref($manifest->{sources}) eq 'ARRAY'
            && @{$manifest->{sources}};
        die "template $id requires source_authorizer for its declared sources\n"
            if $has_sources && ref($spec->{source_authorizer}) ne 'CODE';
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
            public_inputs => $public_inputs,
            title => _scalar($spec->{title}, 256) ? "$spec->{title}" : "$id",
        };
    }
    return \%templates;
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
