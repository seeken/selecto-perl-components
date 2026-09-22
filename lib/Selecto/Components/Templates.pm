package Selecto::Components::Templates;

use Mojolicious 9.49 ();
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::File qw(path);
use Time::HiRes qw(time);
use Selecto::Components::Controller::Templates ();
use Selecto::Components::Templates::Dispatcher ();
use Selecto::Components::Templates::Transport ();

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
    my $templates = _templates($plugin_config->{templates});
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
}

sub _templates ($specs) {
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
        for my $callback (qw(resolve_inputs source_authorizer source_runner)) {
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
        $templates{$id} = {
            %$spec,
            id => "$id",
            release_id => "$release",
            ttl_seconds => $ttl_seconds,
            lease_seconds => $lease_seconds,
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
