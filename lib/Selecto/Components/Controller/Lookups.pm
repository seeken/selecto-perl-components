package Selecto::Components::Controller::Lookups;

use Mojo::Base -base, -signatures;
use Selecto::CoDomain ();
use Selecto::Components::Actions ();

sub _run_action_lookup ($controller, $explorer) {
    my $config = $explorer->config->for_request($controller);
    my $query = $controller->param('q');
    $query = '' unless defined($query) && !ref($query);
    $query = "$query";
    $query =~ s/\A\s+|\s+\z//g;
    return _lookup_response($controller, 422, {
        error => 'The lookup query is too long.', results => [],
    }) if length($query) > 100 || $query =~ /\0/;

    my $selected_values = $controller->every_param('selected_id');
    my @selected_ids = ref($selected_values) eq 'ARRAY' ? @$selected_values : ();
    my %seen;
    @selected_ids = grep {
        defined($_) && !ref($_) && length("$_") <= 200 && "$_" !~ /\0/
            && !$seen{"$_"}++
    } @selected_ids;
    return _lookup_response($controller, 422, {
        error => 'Too many rows were selected for this lookup.', results => [],
    }) if @selected_ids > $config->max_action_rows;

    my $action_id = $controller->stash('selecto_action_id') // '';
    my $input_id = $controller->stash('selecto_input_id') // '';
    my ($domain, $resolved);
    my $discovery_ok = eval {
        $domain = $config->engine($controller)->domain;
        $resolved = Selecto::Components::Actions->find(
            $config, $domain, $controller, $action_id, 'preview',
            @selected_ids ? {ids => \@selected_ids} : undef,
        );
        1;
    };
    unless ($discovery_ok) {
        $controller->app->log->error("Selecto action lookup discovery failed: $@");
        return _lookup_response($controller, 500, {
            error => 'The lookup could not be prepared.', results => [],
        });
    }
    return _lookup_response($controller, 404, {
        error => 'That lookup is not available.', results => [],
    }) unless $resolved && ($resolved->{decision}{status} // '') eq 'enabled';

    my @inputs = (
        @{$resolved->{action}{inputs} // []},
        @{$resolved->{action}{selection}{group_inputs} // []},
    );
    my ($input) = grep {
        ($_->{id} // '') eq $input_id && ($_->{type} // '') eq 'lookup'
    } @inputs;
    return _lookup_response($controller, 404, {
        error => 'That lookup is not available.', results => [],
    }) unless $input;
    return _lookup_response($controller, 200, {results => []})
        if length($query) < ($input->{minimum_query_length} // 2);

    my $lookup_request = {
        query => $query,
        limit => $input->{result_limit} // 20,
        action => $resolved->{action},
        input => $input,
        selected_ids => \@selected_ids,
    };
    my $raw;
    my $lookup_ok = eval {
        my $co_domain_id = $input->{co_domain};
        my $lookup_source = $input->{lookup_source};
        die "lookup input must declare exactly one lookup source\n"
            if (defined($co_domain_id) ? 1 : 0) + (defined($lookup_source) ? 1 : 0) != 1;
        if (defined $co_domain_id) {
            my $definition = Selecto::CoDomain->definition($domain, $co_domain_id);
            my $co_engine = $config->co_domain_engine(
                $definition->{domain}, $controller, $lookup_request,
            ) or die "co-domain engine $definition->{domain} is not configured\n";
            my %lookup_args = (
                source_domain => $domain,
                co_domain => $co_domain_id,
                engine => $co_engine,
                query => $query,
                limit => $lookup_request->{limit},
            );
            if (my $scope_resolver = $config->co_domain_scope($co_domain_id)) {
                my $scope = $scope_resolver->($controller, $lookup_request, $co_engine);
                if (ref($scope) eq 'HASH') {
                    $lookup_args{predicate} = $scope->{predicate}
                        if exists $scope->{predicate};
                    $lookup_args{parameters} = $scope->{parameters}
                        if exists $scope->{parameters};
                } elsif (defined $scope) {
                    $lookup_args{predicate} = $scope;
                }
            }
            $raw = Selecto::CoDomain->lookup(%lookup_args);
        } else {
            my $resolver = $config->lookup_source($lookup_source)
                or die "lookup source $lookup_source is not configured\n";
            $raw = $resolver->($controller, $lookup_request);
        }
        1;
    };
    unless ($lookup_ok) {
        my $lookup_id = $input->{co_domain} // $input->{lookup_source} // 'unknown';
        $controller->app->log->error("Selecto action lookup $lookup_id failed: $@");
        return _lookup_response($controller, 500, {
            error => 'The lookup could not be completed.', results => [],
        });
    }
    $raw = $raw->{results} if ref($raw) eq 'HASH';
    unless (ref($raw) eq 'ARRAY') {
        $controller->app->log->error(
            'Selecto action lookup returned an invalid result',
        );
        return _lookup_response($controller, 500, {
            error => 'The lookup returned an invalid result.', results => [],
        });
    }

    my (@results, %seen_value);
    for my $item (@$raw) {
        next unless ref($item) eq 'HASH';
        my $value = $item->{value} // $item->{id};
        my $label = $item->{label} // $item->{name};
        next unless defined($value) && !ref($value) && defined($label) && !ref($label);
        $value = "$value";
        $label = "$label";
        next if $value eq '' || $label eq '' || length($value) > 200
            || length($label) > 200 || $value =~ /\0/ || $label =~ /\0/
            || $seen_value{$value}++;
        my %normalized = (value => $value, label => $label);
        my $description = $item->{description};
        $normalized{description} = "$description"
            if defined($description) && !ref($description)
                && length("$description") <= 400 && "$description" !~ /\0/;
        push @results, \%normalized;
        last if @results >= ($input->{result_limit} // 20);
    }
    return _lookup_response($controller, 200, {results => \@results});
}

sub _lookup_response ($controller, $status, $payload) {
    $controller->res->headers->cache_control('no-store');
    return $controller->render(json => $payload, status => $status);
}

1;
