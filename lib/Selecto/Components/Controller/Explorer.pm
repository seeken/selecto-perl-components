package Selecto::Components::Controller::Explorer;

use Mojo::Base -base, -signatures;
use Selecto::Components::Actions ();
use Selecto::Components::Controller::SavedQueries ();
use Time::HiRes qw(time);

sub _decorate_model ($controller, $model) {
    my $started = time;
    $model->{csrf_token} = Selecto::Components::_csrf_token($controller);
    $model->{action_notice} = $controller->flash('selecto_action_notice');
    $model->{action_error} = $controller->flash('selecto_action_error');
    $model->{saved_query_notice} = $controller->flash('selecto_saved_query_notice');
    $model->{saved_query_error} = $controller->flash('selecto_saved_query_error');
    $model->{saved_queries} = [];
    my $results_only = ref($model->{input}) eq 'HASH'
        && ($model->{input}{render_scope} // '') eq 'results';
    if (!$results_only && $model->{domain}
        && $model->{config}->saved_queries_enabled($model->{domain})) {
        my $ok = eval {
            my $queries = $model->{config}->saved_query_store->list(
                $controller, $model->{config},
            );
            die "saved query store returned an invalid list\n" unless ref($queries) eq 'ARRAY';
            $model->{saved_queries} = Selecto::Components::Controller::SavedQueries::_normalize_saved_queries($model->{config}, $queries);
            1;
        };
        unless ($ok) {
            $controller->app->log->error("Selecto saved query listing failed: $@");
            $model->{saved_query_error} //= 'Saved queries could not be loaded.';
        }
    }
    $model->{available_actions} = [];
    $model->{bulk_actions} = [];
    if ($model->{domain} && $model->{state} && $model->{state}->valid
        && $model->{state}->view eq 'detail') {
        my $ok = eval {
            $model->{available_actions} = Selecto::Components::Actions->available(
                $model->{config}, $model->{domain}, $controller,
            );
            my %selected = map {
                my $id = $model->{config}->action_id_from_column($_);
                defined($id) ? ($id => 1) : ()
            } @{$model->{state}->fields};
            $model->{bulk_actions} = [grep {
                $selected{$_->{id}}
            } @{$model->{available_actions}}];
            _apply_action_row_eligibility($controller, $model);
            1;
        };
        unless ($ok) {
            $controller->app->log->error("Selecto action discovery failed: $@");
            $model->{available_actions} = [];
            $model->{bulk_actions} = [];
        }
    }
    if (ref($model->{result}) eq 'HASH'
        && ref($model->{result}{debug}) eq 'HASH'
        && ref($model->{result}{debug}{stats}) eq 'HASH') {
        $model->{result}{debug}{stats}{decorate_ms}
            = int((time - $started) * 1000 + 0.5);
    }
    return $model;
}

sub _apply_action_row_eligibility ($controller, $model) {
    my $result = $model->{result};
    return unless ref($result) eq 'HASH' && ref($result->{records}) eq 'ARRAY';
    return if $result->{all_rows};
    my $target_key = $result->{action_key};
    return unless defined($target_key) && !ref($target_key) && length($target_key);

    for my $action (@{$model->{bulk_actions} // []}) {
        next unless ref($action) eq 'HASH' && ref($action->{selection}) eq 'HASH';
        my $field = $action->{selection}{eligibility_field};
        next unless defined($field) && !ref($field)
            && "$field" =~ /\A__[a-z][a-z0-9_]*\z/;

        $_->{$field} = 0 for @{$result->{records}};
        my $resolver = $model->{config}->action_eligibility_resolver($action->{id});
        unless ($resolver) {
            $controller->app->log->error(
                "Selecto action $action->{id} declares $field without an eligibility resolver",
            );
            next;
        }

        my (%seen, @row_ids);
        for my $record (@{$result->{records}}) {
            next unless ref($record) eq 'HASH';
            my $id = $record->{$target_key};
            next unless defined($id) && !ref($id) && "$id" ne '' && !$seen{"$id"}++;
            push @row_ids, "$id";
        }
        next unless @row_ids;

        my $eligible;
        my $ok = eval {
            $eligible = $resolver->($controller, {
                phase => 'display', action => $action, row_ids => \@row_ids,
            });
            die "eligibility resolver returned an invalid result\n"
                unless ref($eligible) eq 'HASH';
            1;
        };
        unless ($ok) {
            $controller->app->log->error(
                "Selecto action $action->{id} eligibility failed: $@",
            );
            next;
        }
        for my $record (@{$result->{records}}) {
            next unless ref($record) eq 'HASH';
            my $id = $record->{$target_key};
            $record->{$field} = defined($id) && !ref($id) && $eligible->{"$id"} ? 1 : 0;
        }
    }
}

1;
