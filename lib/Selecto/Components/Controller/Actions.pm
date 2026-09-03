package Selecto::Components::Controller::Actions;

use Mojo::Base -base, -signatures;
use Mojo::Util qw(secure_compare);
use Selecto::Components::Actions ();

sub _run_action ($controller, $explorer) {
    my $config = $explorer->config->for_request($controller);
    my $return_to = Selecto::Components::_safe_return_to($config, scalar $controller->param('return_to'));
    my $submitted_token = $controller->param('csrf_token') // '';
    my $expected_token = $controller->session('selecto_components_csrf') // '';
    return Selecto::Components::_action_response($controller, $return_to, {
        ok => 0, status => 403,
        message => 'The action form expired. Reload the explorer and try again.',
    }) unless length($submitted_token) && length($expected_token)
        && secure_compare("$submitted_token", "$expected_token");

    my $selected_values = $controller->every_param('selected_id');
    my @selected_ids = ref($selected_values) eq 'ARRAY' ? @$selected_values : ();
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
        ok => 0, status => 403,
        message => $resolved->{decision}{reason} || 'That action is not permitted.',
    }) unless $resolved->{decision}{status} eq 'enabled';

    my %raw_inputs = map {
        $_->{id} => scalar $controller->param('action_input_' . $_->{id})
    } @{$resolved->{action}{inputs}};
    my $request = Selecto::Components::Actions->request(
        $config, $resolved->{action}, \@selected_ids, \%raw_inputs,
        {group_payload => scalar $controller->param('action_groups')},
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
