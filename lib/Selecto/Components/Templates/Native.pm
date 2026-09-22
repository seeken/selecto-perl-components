package Selecto::Components::Templates::Native;

use 5.034;
use strict;
use warnings;

use Storable qw(dclone);
use Selecto::Components::Controller::Templates ();
use Selecto::Components::Templates::ComponentIdentity ();

=head1 NAME

Selecto::Components::Templates::Native - Trusted view models for native Mojolicious templates

=head1 DESCRIPTION

Builds HTML-free, server-owned template models for ordinary Mojolicious EP
templates. The helper model exposes resolved input, state, source results, and
bounded POST form descriptors. It never exposes a manifest, owner scope,
database handle, adapter, or source authority to the browser.

=cut

sub new {
    my ($class, %args) = @_;
    die "native template helper requires a runtime\n"
        unless ref($args{runtime}) eq 'HASH';
    return bless {runtime => $args{runtime}}, $class;
}

sub model {
    my ($self, $controller, %args) = @_;
    my $template_id = delete $args{template};
    my $instance_id = delete $args{instance};
    return _error('invalid_native_template_request',
        'Specify exactly one template or instance.')
        if (defined($template_id) ? 1 : 0) + (defined($instance_id) ? 1 : 0) != 1;

    if (defined($template_id)) {
        my $mounted = Selecto::Components::Controller::Templates->mount_instance(
            $controller, $self->{runtime}, $template_id,
        );
        return $mounted unless ($mounted->{status} // '') eq 'ok';
        return $self->_build_model(
            $controller, $mounted->{template}, $mounted->{snapshot},
            $mounted->{store_revision}, %args,
            canonical_url => $mounted->{canonical_url},
        );
    }

    my $context = Selecto::Components::Controller::Templates->instance_context(
        $controller, $self->{runtime}, $instance_id,
    );
    return $context unless ($context->{status} // '') eq 'ok';
    return $self->_build_model(
        $controller, $context->{template}, $context->{loaded}{snapshot},
        $context->{loaded}{revision}, %args,
    );
}

sub dispatch_event {
    my ($self, $controller, %args) = @_;
    my $instance_id = delete $args{instance};
    my $result = Selecto::Components::Controller::Templates->dispatch_event_request(
        $controller, $self->{runtime}, instance_id => $instance_id,
    );
    return $result unless ($result->{status} // '') eq 'ok';
    return $self->_build_model(
        $controller, $result->{template}, $result->{snapshot},
        $result->{store_revision}, %args,
        event_id => $result->{event_id},
        component_id => $result->{component_id},
        component_lifetime => $result->{component_lifetime},
        form_revision => $result->{form_revision},
    );
}

sub dispatch_source {
    my ($self, $controller, %args) = @_;
    my $instance_id = delete $args{instance};
    my $source_id = delete $args{source};
    my $on_finish = delete $args{on_finish};
    return _error('invalid_native_template_callback',
        'Native template source callback is invalid.')
        unless ref($on_finish) eq 'CODE';
    return Selecto::Components::Controller::Templates->dispatch_source_request(
        $controller, $self->{runtime},
        instance_id => $instance_id,
        source_id => $source_id,
        on_finish => sub {
            my ($result) = @_;
            return $on_finish->($result)
                unless ($result->{status} // '') eq 'ok';
            my $model = $self->_build_model(
                $controller, $result->{template}, $result->{snapshot},
                $result->{store_revision}, %args,
                source_id => $result->{source_id},
                source_generation => $result->{source_generation},
            );
            return $on_finish->($model);
        },
    );
}

sub _build_model {
    my ($self, $controller, $template, $snapshot, $store_revision, %args) = @_;
    my $instance_path = _instance_path(
        $args{instance_path} // $self->{runtime}{transport}->instance_path,
    );
    my $target = _target($args{target} // ('#' . _root_id($snapshot->{instance_id})));
    my $csrf_token = $controller->csrf_token;
    my $event_action = "$instance_path/$snapshot->{instance_id}/events";
    my @events;
    _event_forms(
        \@events, $template->{manifest}{view}{nodes}, $template->{manifest},
        $snapshot, $event_action, $target, $csrf_token,
        $self->{runtime}{transport}->event_id_generator,
    );

    my (%sources, %source_forms);
    for my $source_id (sort keys %{$snapshot->{sources}}) {
        my $source = $snapshot->{sources}{$source_id};
        next unless ref($source) eq 'HASH';
        $sources{$source_id} = {
            status => $source->{status},
            generation => 0 + $source->{generation},
            (defined($source->{result}) ? (rows => dclone($source->{result})) : ()),
            (defined($source->{error}) ? (error => dclone($source->{error})) : ()),
        };
        next unless ($source->{status} // '') eq 'loading';
        my $action = "$instance_path/$snapshot->{instance_id}/sources/$source_id";
        $source_forms{$source_id} = {
            action => $action,
            method => 'post',
            hx_post => $action,
            hx_trigger => 'load',
            hx_target => $target,
            hx_swap => 'outerHTML',
            fields => {csrf_token => "$csrf_token"},
        };
    }

    my %metadata = map {
        defined($args{$_}) ? ($_ => $args{$_}) : ()
    } qw(canonical_url event_id component_id component_lifetime form_revision
        source_id source_generation);
    return {
        status => 'ok',
        schema => 'selecto.template.native-model.v1',
        template => {
            id => "$template->{id}",
            name => "$template->{manifest}{template}{name}",
            version => "$template->{manifest}{template}{version}",
            release_id => "$template->{release_id}",
        },
        instance_id => "$snapshot->{instance_id}",
        state_revision => 0 + $snapshot->{state_revision},
        store_revision => 0 + $store_revision,
        root_id => substr($target, 1),
        inputs => dclone($snapshot->{inputs}),
        state => dclone($snapshot->{state}),
        sources => \%sources,
        forms => {events => \@events, sources => \%source_forms},
        response => \%metadata,
    };
}

sub _event_forms {
    my ($forms, $nodes, $manifest, $snapshot, $action, $target, $csrf, $generator) = @_;
    for my $node (@$nodes) {
        next unless ref($node) eq 'HASH';
        if (($node->{kind} // '') eq 'component' && ref($node->{events}) eq 'HASH') {
            for my $binding (sort keys %{$node->{events}}) {
                my $event = $node->{events}{$binding};
                my $event_id = $generator->();
                die "invalid_event_id: event ID generator returned an invalid value\n"
                    unless defined($event_id) && !ref($event_id)
                    && "$event_id" =~ /\A[\x21-\x7e]{1,256}\z/;
                my $identity = Selecto::Components::Templates::ComponentIdentity->descriptor(
                    manifest => $manifest, snapshot => $snapshot,
                    component_id => $node->{node_id}, event => $event,
                );
                push @$forms, {
                    binding => "$binding",
                    event => "$event",
                    component_id => "$node->{node_id}",
                    action => $action,
                    method => 'post',
                    hx_post => $action,
                    hx_target => $target,
                    hx_swap => 'outerHTML',
                    input_name => 'value',
                    fields => {
                        template_action => 'event',
                        csrf_token => "$csrf",
                        event => "$event",
                        event_id => "$event_id",
                        state_revision => 0 + $snapshot->{state_revision},
                        %$identity,
                    },
                };
            }
        }
        _event_forms(
            $forms, $node->{$_}, $manifest, $snapshot, $action, $target,
            $csrf, $generator,
        ) for grep { ref($node->{$_}) eq 'ARRAY' } qw(children then else);
    }
}

sub _instance_path {
    my ($value) = @_;
    die "native template instance path is invalid\n"
        unless defined($value) && !ref($value)
        && "$value" =~ m{\A/[A-Za-z0-9/_-]*[A-Za-z0-9_-]\z};
    return "$value";
}

sub _target {
    my ($value) = @_;
    die "native template target is invalid\n"
        unless defined($value) && !ref($value)
        && "$value" =~ /\A#[A-Za-z][A-Za-z0-9_-]{0,255}\z/;
    return "$value";
}

sub _root_id {
    my ($instance_id) = @_;
    my $encoded = join '', map {
        ($_ >= 48 && $_ <= 57) || ($_ >= 65 && $_ <= 90)
            || ($_ >= 97 && $_ <= 122) || $_ == 95
            ? chr($_) : sprintf('-%02X', $_)
    } unpack 'C*', "$instance_id";
    return "selecto-native-template-$encoded";
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
