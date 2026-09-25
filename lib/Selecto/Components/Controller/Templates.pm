package Selecto::Components::Controller::Templates;

use Mojo::Base -base, -signatures;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Selecto::Components::Templates::ComponentIdentity ();
use Selecto::Components::Templates::PublicInputs ();
use Selecto::Components::Templates::Regions ();
use Selecto::Components::Templates::SourceExecutor ();

sub show ($class, $controller, $runtime) {
    my $result = $class->mount_instance(
        $controller, $runtime,
        $controller->stash('selecto_template_id'),
    );
    return $runtime->{transport}->respond_error($controller, $result)
        unless $result->{status} eq 'ok' || $result->{status} eq 'redirect';
    return $runtime->{transport}->respond_redirect(
        $controller, $result->{location},
    ) if $result->{status} eq 'redirect';
    return _snapshot_response(
        $controller, $runtime, $result->{template}, $result->{snapshot},
        $result->{store_revision}, canonical_url => $result->{canonical_url},
    );
}

sub reopen ($class, $controller, $runtime) {
    my $context = $class->instance_context(
        $controller, $runtime,
        $controller->stash('selecto_template_instance_id'),
    );
    return $runtime->{transport}->respond_error($controller, $context)
        unless $context->{status} eq 'ok';
    return _snapshot_response(
        $controller, $runtime, $context->{template},
        $context->{loaded}{snapshot}, $context->{loaded}{revision},
    );
}

sub mount_instance ($class, $controller, $runtime, $template_id) {
    my $owner = _owner($controller, $runtime);
    return $owner unless $owner->{status} eq 'ok';
    my $template = $runtime->{templates}{$template_id};
    return {
        status => 'not_found', code => 'template_not_found',
        message => 'Template was not found.',
    } unless $template;

    my $inputs = _inputs($controller, $template);
    return $inputs unless $inputs->{status} eq 'ok';
    return {status => 'redirect', location => $inputs->{canonical_url}}
        if $inputs->{redirect};
    my $now = eval { $runtime->{clock}->() };
    return _unavailable()
        if $@ || !defined($now) || ref($now);

    my $mounted = $runtime->{dispatcher}->mount(
        owner_scope => $owner->{owner_scope},
        manifest => $template->{manifest},
        release_id => $template->{release_id},
        inputs => $inputs->{inputs},
        expires_at => $now + $template->{ttl_seconds},
    );
    return $mounted unless $mounted->{status} eq 'ok';
    return {
        status => 'ok', template => $template,
        snapshot => $mounted->{observation}{snapshot},
        store_revision => $mounted->{store_revision},
        canonical_url => $inputs->{canonical_url},
    };
}

sub event ($class, $controller, $runtime) {
    my $result = $class->dispatch_event_request(
        $controller, $runtime,
        instance_id => $controller->stash('selecto_template_instance_id'),
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

sub dispatch_event_request ($class, $controller, $runtime, %args) {
    return _csrf_error() unless _csrf_valid($controller);
    my $params = _event_params($controller);
    return $params unless $params->{status} eq 'ok';
    return $class->dispatch_event(
        $controller, $runtime,
        instance_id => $args{instance_id}, params => $params,
        expected_template_id => $args{expected_template_id},
    );
}

sub dispatch_event ($class, $controller, $runtime, %args) {
    my $params = $args{params};
    return _invalid_request('invalid_event_params', 'Template event parameters are invalid.')
        unless ref($params) eq 'HASH';
    my $context = $class->instance_context(
        $controller, $runtime, $args{instance_id},
        expected_template_id => $args{expected_template_id},
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
    my $result = $class->dispatch_source_request(
        $controller, $runtime,
        instance_id => $controller->stash('selecto_template_instance_id'),
        source_id => $controller->stash('selecto_template_source_id'),
        on_finish => sub ($finished) {
            my $tx = $controller->tx;
            return unless $tx && !$tx->is_finished;
            return $runtime->{transport}->respond_error($controller, $finished)
                unless $finished->{status} eq 'ok';
            return _snapshot_response(
                $controller, $runtime, $finished->{template},
                $finished->{snapshot}, $finished->{store_revision},
                source_id => $finished->{source_id},
                source_generation => $finished->{source_generation},
                region_node_ids => $finished->{region_node_ids},
            );
        },
    );
    return $runtime->{transport}->respond_error($controller, $result)
        unless $result->{status} eq 'scheduled';
    $controller->render_later;
    return undef;
}

sub page ($class, $controller, $runtime) {
    my $result = $class->dispatch_page_request(
        $controller, $runtime,
        instance_id => $controller->stash('selecto_template_instance_id'),
        source_id => $controller->stash('selecto_template_source_id'),
        on_finish => sub ($finished) {
            my $tx = $controller->tx;
            return unless $tx && !$tx->is_finished;
            return $runtime->{transport}->respond_error($controller, $finished)
                unless $finished->{status} eq 'ok';
            return _snapshot_response(
                $controller, $runtime, $finished->{template},
                $finished->{snapshot}, $finished->{store_revision},
                source_id => $finished->{source_id},
                source_generation => $finished->{source_generation},
                region_node_ids => $finished->{region_node_ids},
            );
        },
    );
    return $runtime->{transport}->respond_error($controller, $result)
        unless $result->{status} eq 'scheduled';
    $controller->render_later;
    return undef;
}

sub root_page ($class, $controller, $runtime) {
    my $result = $class->dispatch_root_page_request(
        $controller, $runtime,
        instance_id => $controller->stash('selecto_template_instance_id'),
        source_id => $controller->stash('selecto_template_source_id'),
        on_finish => sub ($finished) {
            my $tx = $controller->tx;
            return unless $tx && !$tx->is_finished;
            return $runtime->{transport}->respond_error($controller, $finished)
                unless $finished->{status} eq 'ok';
            return _snapshot_response(
                $controller, $runtime, $finished->{template},
                $finished->{snapshot}, $finished->{store_revision},
                source_id => $finished->{source_id},
                source_generation => $finished->{source_generation},
                region_node_ids => $finished->{region_node_ids},
            );
        },
    );
    return $runtime->{transport}->respond_error($controller, $result)
        unless $result->{status} eq 'scheduled';
    $controller->render_later;
    return undef;
}

sub dispatch_page_request ($class, $controller, $runtime, %args) {
    return _csrf_error() unless _csrf_valid($controller);
    my $params = _page_params($controller);
    return $params unless $params->{status} eq 'ok';
    my $on_finish = $args{on_finish};
    return _invalid_request('invalid_page_callback', 'Template page callback is invalid.')
        unless ref($on_finish) eq 'CODE';
    my $context = $class->instance_context(
        $controller, $runtime, $args{instance_id},
        expected_template_id => $args{expected_template_id},
    );
    return $context unless $context->{status} eq 'ok';
    my $source_id = $args{source_id};
    my $snapshot = $context->{loaded}{snapshot};
    my $source = ref($snapshot->{sources}) eq 'HASH'
        ? $snapshot->{sources}{$source_id} : undef;
    my $declared = ref($context->{template}{manifest}{sources}) eq 'ARRAY'
        ? scalar(grep {
            ref($_) eq 'HASH' && ($_->{id} // '') eq $source_id
        } @{$context->{template}{manifest}{sources}}) : 0;
    return _invalid_request('invalid_page_cursor', 'Collection page cursor is invalid.')
        unless $declared && ref($source) eq 'HASH'
        && ($source->{status} // '') eq 'ready'
        && ref($source->{result}) eq 'HASH'
        && ref($source->{result}{pages}) eq 'ARRAY'
        && defined($source->{generation}) && !ref($source->{generation})
        && "$source->{generation}" =~ /\A[1-9][0-9]*\z/
        && defined($source->{page}) && !ref($source->{page})
        && "$source->{page}" =~ /\A[1-9][0-9]*\z/;
    my $template = $context->{template};
    return _invalid_request('invalid_page_cursor', 'Collection page cursor is invalid.')
        unless defined($template->{page_secret})
        && !ref($template->{page_secret})
        && length($template->{page_secret}) >= 32;
    my $effect = {
        schema => 'selecto.template.runtime-effect.v1',
        effect_id => "$context->{instance_id}:source:$source_id:$source->{generation}",
        kind => 'load_source', source => "$source_id",
        generation => 0 + $source->{generation},
        bindings => {input => $snapshot->{inputs}, state => $snapshot->{state}},
    };
    my $claim = _claim_page($runtime, $context, $source_id, $source, {
        status => 'conflict', code => 'stale_page_commit',
        message => 'The collection changed. Reload and try again.',
    });
    return $claim unless $claim->{status} eq 'claimed';
    my $release = sub ($result) {
        return _release_page(
            $runtime, $context, $source_id, $source, $claim->{claim_token}, $result,
        );
    };
    my $source_context = _source_context($controller, $context, $effect);
    return $release->($source_context) unless $source_context->{status} eq 'ok';
    my $source_authorizer = $template->{source_authorizer};
    my $source_runner = $template->{source_runner};
    my $scheduled = $runtime->{source_scheduler}->execute(
        payload => {
            manifest => $template->{manifest}, effect => $effect,
            source_context => $source_context->{source_context},
            page_snapshot => $snapshot, page_cursor => $params->{page_cursor},
        },
        owner_key => owner_key($context->{owner_scope}),
        timeout_seconds => $template->{source_timeout_seconds},
        work => sub ($payload) {
            return Selecto::Components::Templates::SourceExecutor->execute(
                manifest => $payload->{manifest}, effect => $payload->{effect},
                authorize => sub ($declared_source, $declared_effect) {
                    return $source_authorizer->(
                        $payload->{source_context}, $declared_source,
                        $declared_effect,
                    );
                },
                (defined($source_runner) ? (run => $source_runner) : ()),
                resource_budget => $template->{source_resource_budget},
                page_snapshot => $payload->{page_snapshot},
                page_cursor => $payload->{page_cursor},
                page_secret => $template->{page_secret},
                page_now => int($runtime->{clock}->()),
            );
        },
        on_finish => sub ($execution) {
            return $on_finish->($release->($execution))
                unless ($execution->{status} // '') eq 'ok';
            my $commit = {
                schema => 'selecto.template.runtime-page-commit.v1',
                instance_id => "$context->{instance_id}",
                release_id => "$template->{release_id}",
                source => "$source_id",
                generation => 0 + $source->{generation},
                expected_state_revision => 0 + $snapshot->{state_revision},
                expected_page => 0 + $source->{page},
                result => $execution->{result},
            };
            my $committed = $runtime->{dispatcher}->commit_page(
                owner_scope => $context->{owner_scope},
                instance_id => $context->{instance_id},
                manifest => $template->{manifest}, commit => $commit,
            );
            $release->($committed);
            return $on_finish->($committed)
                unless ($committed->{status} // '') eq 'ok';
            return $on_finish->({
                status => 'conflict', code => 'stale_page_commit',
                message => 'The collection changed. Reload and try again.',
            }) unless ($committed->{observation}{outcome} // '') eq 'accepted';
            return $on_finish->({
                status => 'ok', template => $template,
                snapshot => $committed->{observation}{snapshot},
                store_revision => $committed->{store_revision},
                source_id => "$source_id",
                source_generation => 0 + $source->{generation},
                region_node_ids => Selecto::Components::Templates::Regions->for_source(
                    $template->{manifest}, $source_id,
                ),
            });
        },
    );
    return $release->($scheduled)
        unless ($scheduled->{status} // '') eq 'scheduled';
    return $scheduled;
}

sub dispatch_root_page_request ($class, $controller, $runtime, %args) {
    return _csrf_error() unless _csrf_valid($controller);
    my $params = _root_page_params($controller);
    return $params unless $params->{status} eq 'ok';
    my $on_finish = $args{on_finish};
    return _invalid_request('invalid_root_page_callback', 'Template root page callback is invalid.')
        unless ref($on_finish) eq 'CODE';
    my $context = $class->instance_context(
        $controller, $runtime, $args{instance_id},
        expected_template_id => $args{expected_template_id},
    );
    return $context unless $context->{status} eq 'ok';
    my $source_id = $args{source_id};
    my $snapshot = $context->{loaded}{snapshot};
    my $source = ref($snapshot->{sources}) eq 'HASH'
        ? $snapshot->{sources}{$source_id} : undef;
    my $template = $context->{template};
    my $root_enabled = ref($template->{root_cursor_sources}) eq 'ARRAY'
        && scalar(grep { $_ eq $source_id } @{$template->{root_cursor_sources}});
    my $declared = ref($template->{manifest}{sources}) eq 'ARRAY'
        ? scalar(grep {
            ref($_) eq 'HASH' && ($_->{id} // '') eq $source_id
        } @{$template->{manifest}{sources}}) : 0;
    return _invalid_request('invalid_root_cursor', 'Root page cursor is invalid.')
        unless $root_enabled && $declared && ref($source) eq 'HASH'
        && ($source->{status} // '') eq 'ready'
        && ref($source->{result}) eq 'HASH'
        && ref($source->{result}{root_page}) eq 'HASH'
        && $source->{result}{root_page}{has_more}
        && ref($source->{result}{root_page}{after_values}) eq 'ARRAY'
        && defined($source->{generation}) && !ref($source->{generation})
        && "$source->{generation}" =~ /\A[1-9][0-9]*\z/
        && defined($source->{page}) && !ref($source->{page})
        && "$source->{page}" =~ /\A[1-9][0-9]*\z/
        && defined($template->{page_secret})
        && !ref($template->{page_secret})
        && length($template->{page_secret}) >= 32;
    my $effect = {
        schema => 'selecto.template.runtime-effect.v1',
        effect_id => "$context->{instance_id}:source:$source_id:$source->{generation}",
        kind => 'load_source', source => "$source_id",
        generation => 0 + $source->{generation},
        bindings => {input => $snapshot->{inputs}, state => $snapshot->{state}},
    };
    my $claim = _claim_page($runtime, $context, $source_id, $source, {
        status => 'conflict', code => 'stale_root_page_commit',
        message => 'The root page changed. Reload and try again.',
    });
    return $claim unless $claim->{status} eq 'claimed';
    my $release = sub ($result) {
        return _release_page(
            $runtime, $context, $source_id, $source, $claim->{claim_token}, $result,
        );
    };
    my $source_context = _source_context($controller, $context, $effect);
    return $release->($source_context) unless $source_context->{status} eq 'ok';
    my $source_authorizer = $template->{source_authorizer};
    my $source_runner = $template->{source_runner};
    my $scheduled = $runtime->{source_scheduler}->execute(
        payload => {
            manifest => $template->{manifest}, effect => $effect,
            source_context => $source_context->{source_context},
            root_snapshot => $snapshot, root_cursor => $params->{root_cursor},
        },
        owner_key => owner_key($context->{owner_scope}),
        timeout_seconds => $template->{source_timeout_seconds},
        work => sub ($payload) {
            return Selecto::Components::Templates::SourceExecutor->execute(
                manifest => $payload->{manifest}, effect => $payload->{effect},
                authorize => sub ($declared_source, $declared_effect) {
                    return $source_authorizer->(
                        $payload->{source_context}, $declared_source,
                        $declared_effect,
                    );
                },
                (defined($source_runner) ? (run => $source_runner) : ()),
                resource_budget => $template->{source_resource_budget},
                root_snapshot => $payload->{root_snapshot},
                root_cursor => $payload->{root_cursor},
                root_secret => $template->{page_secret},
                root_now => int($runtime->{clock}->()),
            );
        },
        on_finish => sub ($execution) {
            return $on_finish->($release->($execution))
                unless ($execution->{status} // '') eq 'ok';
            my $commit = {
                schema => 'selecto.template.runtime-root-page-commit.v1',
                instance_id => "$context->{instance_id}",
                release_id => "$template->{release_id}",
                source => "$source_id",
                generation => 0 + $source->{generation},
                expected_state_revision => 0 + $snapshot->{state_revision},
                expected_page => 0 + $source->{page},
                expected_after_values => $source->{result}{root_page}{after_values},
                result => $execution->{result},
            };
            my $committed = $runtime->{dispatcher}->commit_root_page(
                owner_scope => $context->{owner_scope},
                instance_id => $context->{instance_id},
                manifest => $template->{manifest}, commit => $commit,
            );
            $release->($committed);
            return $on_finish->($committed)
                unless ($committed->{status} // '') eq 'ok';
            return $on_finish->({
                status => 'conflict', code => 'stale_root_page_commit',
                message => 'The root page changed. Reload and try again.',
            }) unless ($committed->{observation}{outcome} // '') eq 'accepted';
            return $on_finish->({
                status => 'ok', template => $template,
                snapshot => $committed->{observation}{snapshot},
                store_revision => $committed->{store_revision},
                source_id => "$source_id",
                source_generation => 0 + $source->{generation},
                region_node_ids => Selecto::Components::Templates::Regions->for_source(
                    $template->{manifest}, $source_id,
                ),
            });
        },
    );
    return $release->($scheduled)
        unless ($scheduled->{status} // '') eq 'scheduled';
    return $scheduled;
}

sub dispatch_source_request ($class, $controller, $runtime, %args) {
    return _csrf_error() unless _csrf_valid($controller);
    my $params = _source_params($controller);
    return $params unless $params->{status} eq 'ok';
    my $on_finish = $args{on_finish};
    return _invalid_request(
        'invalid_source_callback', 'Template source callback is invalid.',
    ) unless ref($on_finish) eq 'CODE';
    my $context = $class->instance_context(
        $controller, $runtime, $args{instance_id},
        expected_template_id => $args{expected_template_id},
    );
    return $context unless $context->{status} eq 'ok';
    my $source_id = $args{source_id};
    my $source = $context->{loaded}{snapshot}{sources}{$source_id};
    return {
        status => 'error', code => 'source_not_pending',
        message => 'Template source is not waiting to run.',
    } unless ref($source) eq 'HASH' && ($source->{status} // '') eq 'loading'
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
    return $claim unless $claim->{status} eq 'claimed';
    my $source_context = _source_context($controller, $context, $effect);
    return _release_and_result(
        $runtime, $context, $effect,
        $claim->{claim_token}, $source_context,
    ) unless $source_context->{status} eq 'ok';

    my $manifest = $context->{template}{manifest};
    my $source_authorizer = $context->{template}{source_authorizer};
    my $source_runner = $context->{template}{source_runner};
    my $root_first = ref($context->{template}{root_cursor_sources}) eq 'ARRAY'
        && scalar(grep { $_ eq $source_id }
            @{$context->{template}{root_cursor_sources}});
    my $scheduled = $runtime->{source_scheduler}->execute(
        payload => {
            manifest => $manifest,
            effect => $effect,
            source_context => $source_context->{source_context},
            root_first => $root_first ? 1 : 0,
        },
        owner_key => owner_key($context->{owner_scope}),
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
                resource_budget => $context->{template}{source_resource_budget},
                ($payload->{root_first} ? (root_cursor => 'first') : ()),
            );
        },
        on_finish => sub ($execution) {
            my $finished = _finish_source_result(
                $runtime, $context, $effect,
                $claim->{claim_token}, $execution,
            );
            return $on_finish->($finished);
        },
    );
    if (($scheduled->{status} // '') ne 'scheduled') {
        return _release_and_result(
            $runtime, $context, $effect,
            $claim->{claim_token}, $scheduled,
        );
    }
    return {status => 'scheduled'};
}

sub owner_key ($owner_scope) {
    state $json = JSON::PP->new->canonical(1)->ascii(1)->allow_nonref(1);
    return sha256_hex($json->encode($owner_scope));
}

sub _claim_page ($runtime, $context, $source_id, $source, $stale) {
    my $claim = $runtime->{dispatcher}->claim_page_effect(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        source => $source_id,
        generation => $source->{generation},
        page => $source->{page},
        lease_seconds => $context->{template}{lease_seconds},
    );
    return $claim if ($claim->{status} // '') eq 'claimed';
    return {
        status => 'busy', code => 'page_request_in_progress',
        message => 'This page is already loading. Try again.',
    } if ($claim->{status} // '') eq 'busy';
    return $stale if ($claim->{status} // '') eq 'stale';
    return $claim;
}

sub _release_page ($runtime, $context, $source_id, $source, $claim_token, $result) {
    $runtime->{dispatcher}->release_page_claim(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        source => $source_id,
        generation => $source->{generation},
        page => $source->{page},
        claim_token => $claim_token,
    );
    return $result;
}

sub _release_and_result ($runtime, $context, $effect, $claim_token, $error) {
    my $released = $runtime->{dispatcher}->release_effect_claim(
        owner_scope => $context->{owner_scope},
        instance_id => $context->{instance_id},
        effect => $effect,
        claim_token => $claim_token,
    );
    return $released unless $released->{status} eq 'ok';
    return $error;
}

sub _finish_source_result ($runtime, $context, $effect, $claim_token, $execution) {
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
    if (($completed->{code} // '') eq 'snapshot_too_large'
        && ($completion->{outcome} // '') eq 'ok') {
        # The result would not fit in the stored snapshot. Record a bounded
        # source error with the same claim so the source does not stay
        # "loading" until its lease expires, then report the client error.
        delete $completion->{result};
        $completion->{outcome} = 'error';
        $completion->{error} = {
            code => 'source_result_too_large',
            message => 'Template source result is too large.',
        };
        $runtime->{dispatcher}->complete_claimed_effect(
            owner_scope => $context->{owner_scope},
            instance_id => $context->{instance_id},
            manifest => $context->{template}{manifest},
            claim_token => $claim_token,
            completion => $completion,
        );
        return $completed;
    }
    return $completed unless $completed->{status} eq 'ok';
    return {
        status => 'ok', template => $context->{template},
        snapshot => $completed->{observation}{snapshot},
        store_revision => $completed->{store_revision},
        source_id => $effect->{source},
        source_generation => $effect->{generation},
        region_node_ids => Selecto::Components::Templates::Regions->for_source(
            $context->{template}{manifest}, $effect->{source},
        ),
    };
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

sub instance_context ($class, $controller, $runtime, $instance_id, %options) {
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
    return {status => 'not_found', code => 'template_instance_not_found',
        message => 'Template instance was not found.'}
        if defined($options{expected_template_id})
        && ($template->{id} // '') ne $options{expected_template_id};
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

sub _page_params ($controller) {
    my %allowed = map { $_ => 1 } qw(csrf_token page_cursor);
    my @names = @{$controller->req->params->names};
    return _invalid_request('invalid_page_params', 'Template page parameters are invalid.')
        if grep { !$allowed{$_} } @names;
    my $csrf = $controller->every_param('csrf_token');
    my $cursor = $controller->every_param('page_cursor');
    return _invalid_request('invalid_page_params', 'Template page parameters are invalid.')
        unless ref($csrf) eq 'ARRAY' && @$csrf == 1 && !ref($csrf->[0])
        && ref($cursor) eq 'ARRAY' && @$cursor == 1
        && _scalar($cursor->[0], 128);
    return {status => 'ok', page_cursor => "$cursor->[0]"};
}

sub _root_page_params ($controller) {
    my %allowed = map { $_ => 1 } qw(csrf_token root_cursor);
    my @names = @{$controller->req->params->names};
    return _invalid_request('invalid_root_page_params', 'Template root page parameters are invalid.')
        if grep { !$allowed{$_} } @names;
    my $csrf = $controller->every_param('csrf_token');
    my $cursor = $controller->every_param('root_cursor');
    return _invalid_request('invalid_root_page_params', 'Template root page parameters are invalid.')
        unless ref($csrf) eq 'ARRAY' && @$csrf == 1 && !ref($csrf->[0])
        && ref($cursor) eq 'ARRAY' && @$cursor == 1
        && _scalar($cursor->[0], 128);
    return {status => 'ok', root_cursor => "$cursor->[0]"};
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
