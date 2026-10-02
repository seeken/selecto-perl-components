package Selecto::Components::Controller::Actions;

use Mojo::Base -base, -signatures;
use Selecto::Components::Actions ();
use Selecto::Components::Renderer::Results ();

sub form ($controller, $explorer) {
    $controller->res->headers->cache_control('private, no-store');
    my $config = $explorer->config->for_request($controller);
    my $target = Selecto::Components::Actions->canonical_target($config, $controller->every_param('selected_id'));
    my $ids = $target->{ids};
    return $controller->render(status => 422, json => {ok => 0, message => 'Select exactly one row.'})
        unless !@{$target->{errors}} && @$ids == 1 && defined($ids->[0]) && length($ids->[0]) && length($ids->[0]) <= 200;
    my $id = $controller->stash('selecto_action_id') // '';
    return $controller->render(status => 404, json => {ok => 0, message => 'That action form is not available.'})
        unless $config->action_form_resolvers->{$id};
    my $resolved;
    my $ok = eval {
        $resolved = Selecto::Components::Actions->find($config,
            $config->engine($controller)->domain, $controller, $id, 'preview', {ids => $ids});
        1;
    };
    unless ($ok) {
        $controller->app->log->error("Selecto action form failed: $@");
        return $controller->render(status => 500, json => {ok => 0, message => 'The action form could not be loaded.'});
    }
    return $controller->render(status => 403, json => {ok => 0,
        message => $resolved ? ($resolved->{decision}{reason} || 'That action is not permitted.') : 'That action is not available.'})
        unless $resolved && $resolved->{decision}{status} eq 'enabled';
    return $controller->render(json => {ok => 1,
        html => Selecto::Components::Renderer::Results::_action_inputs($resolved->{action})});
}

sub _run_action ($controller, $explorer) {
    my $config = $explorer->config->for_request($controller);
    my $return_to = Selecto::Components::_safe_return_to($config, scalar $controller->param('return_to'));
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => 'The action form expired. Reload the explorer and try again.',
    }) unless Selecto::Components::_csrf_valid($controller);

    my $selected_values = $controller->every_param('selected_id');
    my $target = Selecto::Components::Actions->canonical_target($config, $selected_values);
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 422, message => join(' ', @{$target->{errors}}),
    }) if @{$target->{errors}};
    my @selected_ids = @{$target->{ids}};
    my $action_id = $controller->stash('selecto_action_id') // '';
    my ($domain, $resolved);
    my $discovery_ok = eval {
        $domain = $config->engine($controller)->domain;
        $resolved = Selecto::Components::Actions->find(
            $config, $domain, $controller, $action_id, 'preview', {ids => \@selected_ids},
        );
        1;
    };
    unless ($discovery_ok) {
        $controller->app->log->error("Selecto action lookup failed: $@");
        return Selecto::Components::_action_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The action could not be prepared.',
        });
    }
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 404, message => 'That action is not available.',
    }) unless $resolved;
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => $resolved->{invalid_target} ? 422 : 403,
        message => $resolved->{decision}{reason} || 'That action is not permitted.',
    }) unless $resolved->{decision}{status} eq 'enabled';

    my $raw_inputs = Selecto::Components::Actions->submitted_inputs($controller);
    my $request = Selecto::Components::Actions->request(
        $config, $resolved->{action}, \@selected_ids, $raw_inputs,
        {group_payload => scalar $controller->param('action_groups'), form_encoded => 1},
    );
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 422, message => join(' ', @{$request->{errors}}),
        errors => $request->{errors},
    }) unless $request->{valid};

    my $execute_decision = Selecto::Components::Actions->authorize(
        $config, $controller, $resolved->{action}, 'execute', {
            ids => $request->{selected_ids}, inputs => $request->{inputs},
            groups => $request->{groups},
        },
    );
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => $execute_decision->{reason} || 'That action is not permitted.',
    }) unless $execute_decision->{status} eq 'enabled';

    my $eligible;
    my $eligibility_ok = eval {
        $eligible = Selecto::Components::Actions->row_eligibility(
            $config, $controller, $resolved->{action},
            $request->{selected_ids}, 'execute',
        );
        1;
    };
    unless ($eligibility_ok) {
        $controller->app->log->error(
            "Selecto action $action_id eligibility failed: $@",
        );
        return Selecto::Components::_action_response($controller, $return_to, {
            ok => 0, status => 403,
            message => 'That action is not available for the selected row.',
        });
    }
    if (defined($eligible)
        && grep { !$eligible->{"$_"} } @{$request->{selected_ids}}) {
        return Selecto::Components::_action_response($controller, $return_to, {
            ok => 0, status => 403,
            message => @{$request->{selected_ids}} == 1
                ? 'That action is not available for this row.'
                : 'That action is not available for one or more selected rows.',
        });
    }

    my $handler = $config->action_handler($action_id);
    my $result;
    my $execute_ok = eval { $result = $handler->($controller, $request); 1 };
    unless ($execute_ok) {
        $controller->app->log->error("Selecto action $action_id failed: $@");
        return Selecto::Components::_action_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The action could not be completed.',
        });
    }
    unless (ref($result) eq 'HASH') {
        $controller->app->log->error("Selecto action $action_id returned an invalid result");
        return Selecto::Components::_action_response($controller, $return_to, {
            ok => 0, status => 500, message => 'The action returned an invalid result.',
        });
    }
    $result->{ok} = 1 unless exists $result->{ok};
    $result->{status} = $result->{ok} ? 200 : 422 unless defined $result->{status};
    $result->{message} //= $result->{ok}
        ? 'The action was completed.' : 'The action was not completed.';
    return Selecto::Components::_action_response($controller, $return_to, $result);
}

1;

__END__

=head1 NAME

Selecto::Components::Controller::Actions - Request handlers for selected-row action forms and submissions

=head1 DESCRIPTION

This module is an internal part of L<Selecto::Components>. Its interface may
change without notice; use the plugin and its documented host modules
instead.

=head1 SEE ALSO

L<Selecto::Components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
