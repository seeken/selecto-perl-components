package Selecto::Components::Controller::QueryAssistant;

use Mojo::Base -base, -signatures;
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);
use Selecto::Components::QueryContract ();
use Selecto::Components::QueryAssistant::Draft ();
use Selecto::Components::QueryAssistant::Tools ();
use Selecto::Components::QueryAssistant::Validator ();
use Selecto::Components::Renderer::Builder ();
use Selecto::Components::State ();

sub create ($class, $controller, $explorer, $origin_check) {
    my ($config, $assistant, $body, $error) = _request($controller, $explorer, $origin_check);
    return _error($controller, $error) if $error;
    my $engine = eval { $config->engine($controller) };
    return _error($controller, [500, 'temporarily_unavailable']) unless $engine;
    my $input = ref($body->{input}) eq 'HASH' ? $body->{input} : {};
    my $state = Selecto::Components::State->from_input($config, $engine->domain, $input);
    return _json($controller, {ok => 0, code => 'invalid_target', errors => $state->errors}, 422)
        unless $state->valid;
    my ($owner, $scope) = _identity($controller, $assistant);
    my $contract = Selecto::Components::QueryContract->build(
        config => $config, domain => $engine->domain, state => $state, scope => $scope,
    );
    my $record = eval {
        Selecto::Components::QueryAssistant::Draft->create(
            store => $assistant->{store}, owner => $owner, config => $config,
            state => $state, context_version => $contract->{context_version},
        )
    };
    return _json($controller, {ok => 0, code => 'limit_exceeded'}, 429) unless $record;
    return _json($controller, {
        ok => 1, draft_id => $record->{id}, revision => $record->{revision},
        context_version => $record->{context_version}, target => $record->{target},
        tools => Selecto::Components::QueryAssistant::Tools->definitions,
    }, 201);
}

sub tool ($class, $controller, $explorer, $origin_check) {
    my ($config, $assistant, $body, $error) = _request($controller, $explorer, $origin_check);
    return _error($controller, $error) if $error;
    my $name = $controller->stash('selecto_assistant_tool') // '';
    return _json($controller, {ok => 0, code => 'unknown_tool'}, 404)
        unless Selecto::Components::QueryAssistant::Tools->definition($name);
    my $engine = eval { $config->engine($controller) };
    return _error($controller, [500, 'temporarily_unavailable']) unless $engine;
    my ($owner, $scope) = _identity($controller, $assistant);
    my $record = $assistant->{store}->get($body->{draft_id} // '');
    return _json($controller, {ok => 0, code => 'draft_expired'}, 404) unless $record;
    return _json($controller, {ok => 0, code => 'forbidden'}, 403)
        unless $record->{owner} eq $owner && $record->{explorer_id} eq $config->id;
    my $state = Selecto::Components::State->from_input($config, $engine->domain, $record->{input});
    my $contract = Selecto::Components::QueryContract->build(
        config => $config, domain => $engine->domain, state => $state, scope => $scope,
    );
    if ($name eq 'get_query_context') {
        return _json($controller, {ok => 1, revision => $record->{revision}, %$contract}, 200);
    }
    if ($name eq 'validate_query_target') {
        return _json($controller, {ok => 0, code => 'revision_conflict', current_revision => $record->{revision}}, 409)
            unless defined($body->{base_revision}) && $body->{base_revision} == $record->{revision};
        return _json($controller, {ok => 0, code => 'context_changed'}, 409)
            unless ($body->{context_version} // '') eq $contract->{context_version};
        my $choice_error = _validate_membership_choices($controller, $assistant, $body->{target});
        return _json($controller, $choice_error, 422) if $choice_error;
        my $result = Selecto::Components::QueryAssistant::Validator->validate(
            config => $config, domain => $engine->domain, engine => $engine,
            target => $body->{target}, preserve_input => $record->{input},
        );
        delete @{$result}{qw(input state prepared statement)};
        return _json($controller, $result, $result->{ok} ? 200 : 422);
    }
    if ($name eq 'apply_query_draft') {
        return _json($controller, {ok => 0, code => 'context_changed'}, 409)
            unless ($body->{context_version} // '') eq $contract->{context_version};
        my $choice_error = _validate_membership_choices($controller, $assistant, $body->{target});
        return _json($controller, $choice_error, 422) if $choice_error;
        my $result = Selecto::Components::QueryAssistant::Draft->apply(
            store => $assistant->{store}, id => $body->{draft_id}, owner => $owner,
            config => $config, domain => $engine->domain, engine => $engine,
            context_version => $contract->{context_version}, base_revision => $body->{base_revision},
            request_id => $body->{request_id}, target => $body->{target},
        );
        _attach_builder($controller, $config, $engine->domain, $result);
        return _json($controller, $result, _status($result));
    }
    if ($name eq 'undo_query_draft') {
        my $result = Selecto::Components::QueryAssistant::Draft->undo(
            store => $assistant->{store}, id => $body->{draft_id}, owner => $owner,
            base_revision => $body->{base_revision}, undo_token => $body->{undo_token},
        );
        _attach_builder($controller, $config, $engine->domain, $result);
        return _json($controller, $result, _status($result));
    }
    my $resolver = $assistant->{choice_resolver};
    return _json($controller, {ok => 0, code => 'choice_unavailable'}, 422) unless $resolver;
    my %published = map { $_->{id} => 1 } grep { $_->{choice_search} } @{$contract->{fields}};
    return _json($controller, {ok => 0, code => 'choice_unavailable'}, 422)
        unless $published{$body->{field} // ''};
    my $limit = $body->{limit} // 20;
    $limit = 50 if $limit > 50;
    my $items = eval { $resolver->($controller, {field => $body->{field}, text => $body->{text} // '', limit => $limit}) };
    return _json($controller, {ok => 0, code => 'temporarily_unavailable'}, 503)
        unless ref($items) eq 'ARRAY';
    return _json($controller, {ok => 1, items => [@$items[0 .. ($#$items < $limit - 1 ? $#$items : $limit - 1)]]}, 200);
}

sub sync ($class, $controller, $explorer, $origin_check) {
    my ($config, $assistant, $body, $error) = _request($controller, $explorer, $origin_check);
    return _error($controller, $error) if $error;
    my $engine = eval { $config->engine($controller) };
    return _error($controller, [500, 'temporarily_unavailable']) unless $engine;
    my $input = ref($body->{input}) eq 'HASH' ? $body->{input} : {};
    my $state = Selecto::Components::State->from_input($config, $engine->domain, $input);
    return _json($controller, {ok => 0, code => 'invalid_target', errors => $state->errors}, 422)
        unless $state->valid && !grep { $_->{draft} } @{$state->filters};
    my ($owner) = _identity($controller, $assistant);
    my $result = Selecto::Components::QueryAssistant::Draft->sync(
        store => $assistant->{store}, id => $controller->stash('selecto_assistant_draft'),
        owner => $owner, base_revision => $body->{base_revision}, state => $state, input => $input,
    );
    return _json($controller, $result, _status($result));
}

sub _request ($controller, $explorer, $origin_check) {
    my $config = $explorer->config->for_request($controller);
    my $assistant = $config->query_assistant;
    return ($config, undef, undef, [404, 'not_found']) unless $config->query_assistant_enabled;
    if (my $authorize = $assistant->{context_authorizer}) {
        my $allowed = eval { $authorize->($controller, $config) };
        return ($config, $assistant, undef, [403, 'forbidden']) unless $allowed;
    }
    return ($config, $assistant, undef, [403, 'origin_not_allowed']) unless $origin_check->($controller);
    my $length = $controller->req->headers->content_length // 0;
    return ($config, $assistant, undef, [413, 'limit_exceeded']) if $length > 65_536;
    my $expected = Selecto::Components::_csrf_token($controller);
    my $provided = $controller->req->headers->header('X-CSRF-Token') // '';
    return ($config, $assistant, undef, [403, 'csrf_failed']) unless length($provided) && $provided eq $expected;
    my $body = $controller->req->json;
    return ($config, $assistant, undef, [400, 'invalid_json']) unless ref($body) eq 'HASH';
    return ($config, $assistant, undef, [413, 'limit_exceeded'])
        if length(encode_json($body)) > 65_536;
    return ($config, $assistant, $body, undef);
}

sub _identity ($controller, $assistant) {
    if (my $callback = $assistant->{actor}) {
        my $value = $callback->($controller);
        die "query assistant actor must return a scalar\n" if !defined($value) || ref($value) || "$value" eq '';
        return (sha256_hex("actor:$value"), "$value");
    }
    my $id = $controller->session('selecto_query_assistant_owner');
    unless (defined($id) && !ref($id) && "$id" =~ /\A[0-9a-f]{64}\z/) {
        $id = sha256_hex(join(':', $$, rand(), {}, time));
        $controller->session(selecto_query_assistant_owner => $id);
    }
    return ($id, $id);
}

sub _status ($result) {
    return 200 if $result->{ok};
    return 404 if ($result->{code} // '') eq 'draft_expired';
    return 403 if ($result->{code} // '') eq 'forbidden';
    return 409 if ($result->{code} // '') =~ /(?:conflict|context_changed)/;
    return 422;
}

sub _validate_membership_choices ($controller, $assistant, $target) {
    return undef unless ref($target) eq 'HASH' && ref($target->{filters}) eq 'ARRAY';
    my $fields = ref($assistant->{choice_fields}) eq 'HASH' ? $assistant->{choice_fields} : {};
    my $resolver = $assistant->{choice_resolver};
    for my $filter (@{$target->{filters}}) {
        next unless ref($filter) eq 'HASH' && $fields->{$filter->{field} // ''};
        return {ok => 0, code => 'choice_unavailable'} unless $resolver;
        my @values = ref($filter->{value}) eq 'ARRAY'
            ? @{$filter->{value}} : ($filter->{value});
        next if ($filter->{operator} // '') =~ /_null\z/;
        my $items = eval {
            $resolver->($controller, {
                phase => 'validate', field => $filter->{field}, values => \@values,
                exact => 1, limit => @values,
            })
        };
        return {ok => 0, code => 'temporarily_unavailable'} unless ref($items) eq 'ARRAY';
        my %allowed = map {
            ref($_) eq 'HASH' && defined($_->{value}) && !ref($_->{value})
                ? ("$_->{value}" => 1) : ()
        } @$items;
        my @missing = grep { !defined($_) || ref($_) || !$allowed{"$_"} } @values;
        return {ok => 0, code => 'choice_unavailable', field => $filter->{field}}
            if @missing;
    }
    return undef;
}

sub _attach_builder ($controller, $config, $domain, $result) {
    return unless $result->{ok} && ref($result->{input}) eq 'HASH';
    my $state = Selecto::Components::State->from_input($config, $domain, $result->{input});
    return unless $state->valid;
    my $model = {
        config => $config, domain => $domain, state => $state, input => $result->{input},
        csrf_token => Selecto::Components::_csrf_token($controller), saved_queries => [],
        available_actions => [],
    };
    $result->{builder_html} = Selecto::Components::Renderer::Builder->_form(
        $model, $config->field_catalog($domain), $config->detail_column_catalog($domain, []),
    );
}

sub _error ($controller, $error) { return _json($controller, {ok => 0, code => $error->[1]}, $error->[0]); }
sub _json ($controller, $body, $status) {
    $controller->res->headers->cache_control('no-store');
    return $controller->render(json => $body, status => $status);
}

1;
