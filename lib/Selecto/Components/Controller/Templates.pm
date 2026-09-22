package Selecto::Components::Controller::Templates;

use Mojo::Base -base, -signatures;
use Selecto::Components::Templates::ComponentIdentity ();
use Selecto::Components::Templates::PublicInputs ();
use Selecto::Components::Templates::Regions ();
use Selecto::Components::Templates::SourceExecutor ();

sub show ($class, $controller, $runtime) {
    my $owner = _owner($controller, $runtime);
    return $runtime->{transport}->respond_error($controller, $owner)
        unless $owner->{status} eq 'ok';
    my $template_id = $controller->stash('selecto_template_id');
    my $template = $runtime->{templates}{$template_id};
    return $runtime->{transport}->respond_error($controller, {
        status => 'not_found', code => 'template_not_found',
        message => 'Template was not found.',
    }) unless $template;

    my $inputs = _inputs($controller, $template);
    return $runtime->{transport}->respond_error($controller, $inputs)
        unless $inputs->{status} eq 'ok';
    return $runtime->{transport}->respond_redirect(
        $controller, $inputs->{canonical_url},
    ) if $inputs->{redirect};
    my $now = eval { $runtime->{clock}->() };
    return $runtime->{transport}->respond_error($controller, _unavailable())
        if $@ || !defined($now) || ref($now);

    my $mounted = $runtime->{dispatcher}->mount(
        owner_scope => $owner->{owner_scope},
        manifest => $template->{manifest},
        release_id => $template->{release_id},
        inputs => $inputs->{inputs},
        expires_at => $now + $template->{ttl_seconds},
    );
    return $runtime->{transport}->respond_error($controller, $mounted)
        unless $mounted->{status} eq 'ok';
    return _snapshot_response(
        $controller, $runtime, $template, $mounted->{observation}{snapshot},
        $mounted->{store_revision},
        canonical_url => $inputs->{canonical_url},
    );
}

sub event ($class, $controller, $runtime) {
    return $runtime->{transport}->respond_error($controller, _csrf_error())
        unless _csrf_valid($controller);
    my $params = _event_params($controller);
    return $runtime->{transport}->respond_error($controller, $params)
        unless $params->{status} eq 'ok';
    my $result = $class->dispatch_event(
        $controller, $runtime,
        instance_id => $controller->stash('selecto_template_instance_id'),
        params => $params,
    );
    return $runtime->{transport}->respond_error($controller, $result)
        unless $result->{status} eq 'ok';
    return _snapshot_response(
        $controller, $runtime, $result->{template},
        $result->{snapshot}, $result->{store_revision},
        event_id => $result->{event_id},
        component_id => $result->{component_id},
        component_lifetime => $result->{component_lifetime},
        form_revision => $result->{form_revision},
        region_node_ids => $result->{region_node_ids},
    );
}

sub dispatch_event ($class, $controller, $runtime, %args) {
    my $params = $args{params};
    return _invalid_request('invalid_event_params', 'Template event parameters are invalid.')
        unless ref($params) eq 'HASH';
    my $context = $class->instance_context(
        $controller, $runtime, $args{instance_id},
    );
    return $context unless $context->{status} eq 'ok';
    my $duplicate = ref($context->{loaded}{snapshot}{processed_event_ids}) eq 'ARRAY'
        && grep { $_ eq $params->{event_id} }
            @{$context->{loaded}{snapshot}{processed_event_ids}};
    my $identity = $duplicate ? {
        status => 'ok',
        map { $_ => $params->{$_} }
            qw(component_id component_lifetime form_revision),
    } : Selecto::Components::Templates::ComponentIdentity->validate(
        manifest => $context->{template}{manifest},
        snapshot => $context->{loaded}{snapshot},
        component_id => $params->{component_id},
        component_lifetime => $params->{component_lifetime},
        form_revision => $params->{form_revision},
        state_revision => $params->{state_revision},
        event => $params->{event},
    );
    return _event_error($identity, $context, $params)
        unless $identity->{status} eq 'ok';
    my $result = $runtime->{dispatcher}->dispatch_params(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        manifest => $context->{template}{manifest},
        event_id => $params->{event_id},
        name => $params->{event},
        expected_state_revision => $params->{state_revision},
        params => {value => $params->{value}},
    );
    return _event_error($result, $context, $params)
        unless $result->{status} eq 'ok';
    if (($result->{observation}{outcome} // '') ne 'accepted') {
        return _event_error({
            status => 'conflict',
            code => $result->{observation}{code} // 'event_rejected',
            message => 'Template event could not be applied. Reload and try again.',
        }, $context, $params);
    }
    return {
        status => 'ok', template => $context->{template},
        snapshot => $result->{observation}{snapshot},
        store_revision => $result->{store_revision},
        event_id => "$params->{event_id}",
        component_id => $identity->{component_id},
        component_lifetime => $identity->{component_lifetime},
        form_revision => $identity->{form_revision},
        region_node_ids => Selecto::Components::Templates::Regions->for_event(
            $context->{template}{manifest}, $params->{event},
        ),
    };
}

sub source ($class, $controller, $runtime) {
    return $runtime->{transport}->respond_error($controller, _csrf_error())
        unless _csrf_valid($controller);
    my $params = _source_params($controller);
    return $runtime->{transport}->respond_error($controller, $params)
        unless $params->{status} eq 'ok';
    my $context = $class->instance_context(
        $controller, $runtime, $controller->stash('selecto_template_instance_id'),
    );
    return $runtime->{transport}->respond_error($controller, $context)
        unless $context->{status} eq 'ok';
    my $source_id = $controller->stash('selecto_template_source_id');
    my $source = $context->{loaded}{snapshot}{sources}{$source_id};
    return $runtime->{transport}->respond_error($controller, {
        status => 'error', code => 'source_not_pending',
        message => 'Template source is not waiting to run.',
    }) unless ref($source) eq 'HASH' && ($source->{status} // '') eq 'loading'
        && defined($source->{generation}) && !ref($source->{generation})
        && "$source->{generation}" =~ /\A[1-9][0-9]*\z/;

    my $snapshot = $context->{loaded}{snapshot};
    my $effect = {
        schema => 'selecto.template.runtime-effect.v1',
        effect_id => "$context->{instance_id}:source:$source_id:$source->{generation}",
        kind => 'load_source', source => "$source_id",
        generation => 0 + $source->{generation},
        bindings => {input => $snapshot->{inputs}, state => $snapshot->{state}},
    };
    my $claim = $runtime->{dispatcher}->claim_effect(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        effect => $effect,
        lease_seconds => $context->{template}{lease_seconds},
    );
    return $runtime->{transport}->respond_error($controller, $claim)
        unless $claim->{status} eq 'claimed';
    my $source_context = _source_context($controller, $context, $effect);
    return _release_and_error(
        $controller, $runtime, $context, $effect,
        $claim->{claim_token}, $source_context,
    ) unless $source_context->{status} eq 'ok';

    my $manifest = $context->{template}{manifest};
    my $source_authorizer = $context->{template}{source_authorizer};
    my $source_runner = $context->{template}{source_runner};
    my $scheduled = $runtime->{source_scheduler}->execute(
        payload => {
            manifest => $manifest,
            effect => $effect,
            source_context => $source_context->{source_context},
        },
        timeout_seconds => $context->{template}{source_timeout_seconds},
        work => sub ($payload) {
            return Selecto::Components::Templates::SourceExecutor->execute(
                manifest => $payload->{manifest},
                effect => $payload->{effect},
                authorize => sub ($declared_source, $declared_effect) {
                    return $source_authorizer->(
                        $payload->{source_context},
                        $declared_source,
                        $declared_effect,
                    );
                },
                (defined($source_runner) ? (run => $source_runner) : ()),
            );
        },
        on_finish => sub ($execution) {
            return _finish_source(
                $controller, $runtime, $context, $effect,
                $claim->{claim_token}, $execution,
            );
        },
    );
    if (($scheduled->{status} // '') ne 'scheduled') {
        return _release_and_error(
            $controller, $runtime, $context, $effect,
            $claim->{claim_token}, $scheduled,
        );
    }
    $controller->render_later;
    return undef;
}

sub _release_and_error ($controller, $runtime, $context, $effect, $claim_token, $error) {
    my $released = $runtime->{dispatcher}->release_effect_claim(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        effect => $effect,
        claim_token => $claim_token,
    );
    return $runtime->{transport}->respond_error($controller, $released)
        unless $released->{status} eq 'ok';
    return $runtime->{transport}->respond_error($controller, $error);
}

sub _finish_source ($controller, $runtime, $context, $effect, $claim_token, $execution) {
    my $completion = {
        schema => 'selecto.template.runtime-completion.v1',
        instance_id => $context->{instance_id},
        release_id => $context->{template}{release_id},
        effect_id => $effect->{effect_id},
        source => $effect->{source},
        generation => $effect->{generation},
        ($execution->{status} eq 'ok'
            ? (outcome => 'ok', result => $execution->{result})
            : (outcome => 'error', error => {
                code => $execution->{code} // 'source_execution_failed',
                message => $execution->{message} // 'Template source execution failed.',
            })),
    };
    my $completed = $runtime->{dispatcher}->complete_claimed_effect(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        manifest => $context->{template}{manifest},
        claim_token => $claim_token,
        completion => $completion,
    );
    return $runtime->{transport}->respond_error($controller, $completed)
        unless $completed->{status} eq 'ok';
    return _snapshot_response(
        $controller, $runtime, $context->{template},
        $completed->{observation}{snapshot}, $completed->{store_revision},
        source_id => $effect->{source},
        source_generation => $effect->{generation},
        region_node_ids => Selecto::Components::Templates::Regions->for_source(
            $context->{template}{manifest}, $effect->{source},
        ),
    );
}

sub _source_context ($controller, $context, $effect) {
    my $resolver = $context->{template}{resolve_source_context};
    return {
        status => 'ok',
        source_context => {owner_scope => $context->{owner_scope}},
    } unless defined($resolver);
    my $resolved = eval {
        $resolver->($controller, $context->{owner_scope}, $effect)
    };
    return {
        status => 'error', code => 'source_context_unavailable',
        message => 'Template source context is unavailable.',
    } if $@;
    return _invalid_request(
        'invalid_source_context', 'Template source context is invalid.',
    ) unless ref($resolved) eq 'HASH';
    return {status => 'ok', source_context => $resolved};
}

sub _snapshot_response ($controller, $runtime, $template, $snapshot, $store_revision, %metadata) {
    return $runtime->{transport}->respond_snapshot(
        $controller,
        template => $template,
        snapshot => $snapshot,
        store_revision => $store_revision,
        %metadata,
    );
}

sub _event_error ($result, $context, $params) {
    return $result unless ref($result) eq 'HASH'
        && ref($context) eq 'HASH' && ref($context->{loaded}) eq 'HASH'
        && ref($context->{loaded}{snapshot}) eq 'HASH'
        && ref($params) eq 'HASH';
    my $snapshot = $context->{loaded}{snapshot};
    return {
        %$result,
        response_metadata => {
            instance_id => "$context->{instance_id}",
            state_revision => 0 + $snapshot->{state_revision},
            store_revision => 0 + $context->{loaded}{revision},
            map { $_ => "$params->{$_}" }
                qw(event_id component_id component_lifetime form_revision),
        },
    };
}

sub instance_context ($class, $controller, $runtime, $instance_id) {
    my $owner = _owner($controller, $runtime);
    return $owner unless $owner->{status} eq 'ok';
    return _invalid_request('invalid_instance_id', 'Template instance is invalid.')
        unless _scalar($instance_id, 256);
    my $loaded = $runtime->{dispatcher}->load(
        owner_scope => $owner->{owner_scope}, instance_id => $instance_id,
    );
    return $loaded unless $loaded->{status} eq 'ok';
    my $template = $runtime->{templates_by_release}{$loaded->{release}};
    return {status => 'not_found', code => 'template_release_not_found',
        message => 'Template release was not found.'} unless $template;
    return {
        status => 'ok', owner_scope => $owner->{owner_scope},
        instance_id => "$instance_id", loaded => $loaded, template => $template,
    };
}

sub _owner ($controller, $runtime) {
    my $resolved = eval { $runtime->{resolve_owner}->($controller) };
    return _unavailable() if $@;
    return {status => 'unauthenticated', code => 'authentication_required',
        message => 'Authentication is required.'}
        if ref($resolved) eq 'HASH' && ($resolved->{status} // '') eq 'unauthenticated';
    return {status => 'forbidden', code => 'template_forbidden',
        message => 'Template access is forbidden.'}
        if ref($resolved) eq 'HASH' && ($resolved->{status} // '') eq 'forbidden';
    return _unavailable()
        unless ref($resolved) eq 'HASH' && ($resolved->{status} // '') eq 'ok'
        && ref($resolved->{owner_scope}) eq 'HASH' && keys %{$resolved->{owner_scope}};
    return {status => 'ok', owner_scope => $resolved->{owner_scope}};
}

sub _inputs ($controller, $template) {
    my $public = Selecto::Components::Templates::PublicInputs->decode(
        $controller, $template->{public_inputs},
    );
    return $public unless $public->{status} eq 'ok';
    my $trusted = {};
    if (defined($template->{resolve_inputs})) {
        $trusted = eval { $template->{resolve_inputs}->($controller) };
        return _unavailable() if $@;
        return _invalid_request('invalid_template_inputs', 'Template inputs are invalid.')
            unless ref($trusted) eq 'HASH';
    }
    return {
        status => 'error', code => 'template_host_unavailable',
        message => 'Template host is unavailable.',
    } if grep { exists($trusted->{$_->{name}}) } @{$template->{public_inputs}};
    return {
        %$public,
        inputs => {%$trusted, %{$public->{inputs}}},
    };
}

sub _event_params ($controller) {
    my %allowed = map { $_ => 1 }
        qw(template_action csrf_token event event_id state_revision value
            component_id component_lifetime form_revision);
    my @names = @{$controller->req->params->names};
    return _invalid_request('invalid_event_params', 'Template event parameters are invalid.')
        if grep { !$allowed{$_} } @names;
    my %values;
    for my $name (qw(event event_id state_revision value component_id
        component_lifetime form_revision)) {
        my $submitted = $controller->every_param($name);
        return _invalid_request('invalid_event_params', 'Template event parameters are invalid.')
            unless ref($submitted) eq 'ARRAY' && @$submitted == 1
            && !ref($submitted->[0]);
        $values{$name} = $submitted->[0];
    }
    my $csrf = $controller->every_param('csrf_token');
    return _invalid_request('invalid_event_params', 'Template event parameters are invalid.')
        unless _scalar($values{event}, 128)
        && "$values{event_id}" =~ /\A[\x21-\x7e]{1,256}\z/
        && "$values{state_revision}" =~ /\A[0-9]+\z/
        && "$values{component_id}" =~ /\A[A-Za-z0-9_.:-]{1,512}\z/
        && "$values{component_lifetime}" =~ /\A[0-9a-f]{64}\z/
        && "$values{form_revision}" =~ /\A[0-9]+\z/
        && ref($csrf) eq 'ARRAY' && @$csrf == 1 && !ref($csrf->[0]);
    my $action = $controller->every_param('template_action');
    return _invalid_request('invalid_event_params', 'Template event parameters are invalid.')
        unless ref($action) eq 'ARRAY' && @$action == 1
        && !ref($action->[0]) && $action->[0] eq 'event';
    return {
        status => 'ok', %values,
        state_revision => 0 + $values{state_revision},
    };
}

sub _source_params ($controller) {
    my %allowed = map { $_ => 1 } qw(csrf_token);
    my @names = @{$controller->req->params->names};
    return _invalid_request('invalid_source_params', 'Template source parameters are invalid.')
        if grep { !$allowed{$_} } @names;
    my $csrf = $controller->every_param('csrf_token');
    return _invalid_request('invalid_source_params', 'Template source parameters are invalid.')
        unless ref($csrf) eq 'ARRAY' && @$csrf == 1 && !ref($csrf->[0]);
    return {status => 'ok'};
}

sub _csrf_valid ($controller) {
    return !$controller->validation->csrf_protect->has_error('csrf_token');
}

sub _csrf_error {
    return {status => 'forbidden', code => 'invalid_csrf',
        message => 'The request token is invalid. Reload and try again.'};
}

sub _invalid_request ($code, $message) {
    return {status => 'error', code => $code, message => $message};
}

sub _unavailable {
    return {status => 'error', code => 'template_host_unavailable',
        message => 'Template host is unavailable.'};
}

sub _scalar ($value, $max) {
    return defined($value) && !ref($value) && length("$value")
        && length("$value") <= $max;
}

1;
