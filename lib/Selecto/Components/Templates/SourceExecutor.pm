package Selecto::Components::Templates::SourceExecutor;

use 5.034;
use strict;
use warnings;

use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Expression ();
use Selecto::Components::Templates::PageCursor ();
use Selecto::Components::Templates::RootCursor ();
use Selecto::Templates ();

my %DEFAULT_RESOURCE_BUDGET = (
    max_root_rows => 100,
    max_result_nodes => 10_000,
    max_collection_depth => 3,
    max_source_statements => 2,
    max_input_bytes => 1_048_576,
    max_result_bytes => 1_048_576,
);

=head1 NAME

Selecto::Components::Templates::SourceExecutor - Execute compiled source intent with fresh host authority

=head1 DESCRIPTION

The manifest chooses bounded query intent. The host authorization callback is
invoked for every effect and supplies a freshly scoped C<Selecto::Engine> plus
its host query. Neither tenant authority nor a database handle comes from the
template artifact or browser request.

Before execution, the effective root limit and every nested C<max-items>
bound must fit the host source resource budget. The defaults allow 100 roots,
10,000 projected nodes, three collection levels, two data statements per
source read, and 1 MiB each for
source-effect input and projected JSON.
An unbounded collection fails closed.
Projected results are checked again against the effective root and collection
limits before being returned.

A trusted host can request a root keyset page with C<root_cursor =E<gt> 'first'>
or an opaque token. Continuations also require the server-held C<root_snapshot>
and C<root_secret>; the executor reauthorizes before resolving the token.
These options must be assembled by the host, not copied from request data.

=head2 Database connections in the child

When used through L<Selecto::Components::Templates>, C<execute> and therefore
the host's C<source_authorizer> run in a child process forked by
L<Selecto::Components::Templates::SourceScheduler>. B<The authorizer must open
a fresh database connection in the child. It must not reuse a DBI handle
created in the parent process>, whether captured in a closure, held in a
global, or returned from a parent-populated C<connect_cached> cache. A forked
child shares the parent's socket: queries from both processes interleave on one
server session, rows can be delivered to the wrong request, and the child's
exit can tear down the parent's session.

Enforcement is opt-in and exact: if the returned engine's adapter exposes a
C<dbh> carrying C<private_selecto_pid> (set it with
C<< $dbh->{private_selecto_pid} = $$ >> right after connecting) and that pid is
not the current process, execution fails with C<source_connection_inherited>
before any query runs. Handles without the marker are not second-guessed.

=cut

sub _inherited_database_handle {
    my ($engine) = @_;
    my $adapter = eval { $engine->adapter };
    return 0 unless blessed($adapter) && $adapter->can('dbh');
    my $dbh = eval { $adapter->dbh };
    return 0 unless blessed($dbh) && Scalar::Util::reftype($dbh) eq 'HASH';
    my $pid = eval { $dbh->{private_selecto_pid} };
    return defined($pid) && !ref($pid) && "$pid" =~ /\A[0-9]+\z/
        && $pid != $$ ? 1 : 0;
}

sub execute {
    my ($class, %args) = @_;
    my $manifest = $args{manifest};
    my $effect = $args{effect};
    my $authorize = $args{authorize};
    my $run = $args{run};

    return _error('invalid_source_effect', 'template source effect is invalid')
        unless _valid_effect($effect)
        && ref($manifest) eq 'HASH' && ref($manifest->{sources}) eq 'ARRAY';
    return _error('invalid_source_executor', 'template source executor is invalid')
        unless ref($authorize) eq 'CODE' && (!defined($run) || ref($run) eq 'CODE');

    my ($budget, $budget_error) = _resource_budget($args{resource_budget});
    return $budget_error if $budget_error;
    my $effect_json = eval { JSON::PP->new->utf8->canonical->encode($effect) };
    return _error('invalid_source_effect', 'template source effect is invalid')
        if $@ || !defined($effect_json);
    return _error('source_input_too_large', 'template source input exceeds host byte budget')
        if length($effect_json) > $budget->{max_input_bytes};

    my ($source) = grep {
        ref($_) eq 'HASH' && defined($_->{id}) && $_->{id} eq $effect->{source}
    } @{$manifest->{sources}};
    return _error('unknown_source', 'template source is not declared') unless $source;

    my ($authority, $authorization_exception);
    {
        local $@;
        my $ok = eval {
            $authority = $authorize->($source, $effect);
            1;
        };
        $authorization_exception = $@ unless $ok;
    }
    return _error('source_authorization_failed', 'template source authorization failed')
        if defined($authorization_exception)
        || ref($authority) ne 'HASH'
        || ($authority->{status} // '') ne 'ok'
        || !blessed($authority->{engine})
        || !$authority->{engine}->isa('Selecto::Engine')
        || !blessed($authority->{query})
        || !$authority->{query}->isa('Selecto::Query');
    return _error(
        'source_connection_inherited',
        'template source authorizer returned a database handle created in another process; '
            . 'open a fresh connection inside the source worker',
    ) if _inherited_database_handle($authority->{engine});

    return _error('invalid_root_cursor', 'root page cursor is invalid')
        if exists($args{root_cursor}) && exists($args{page_cursor});
    return _error('invalid_root_cursor', 'root page cursor is invalid')
        if exists($args{root_cursor})
        && (!defined($args{root_cursor}) || ref($args{root_cursor}));
    my ($page_position, $root_position);
    my $query_source = $source;
    if (exists $args{page_cursor}) {
        return _error('invalid_page_cursor', 'collection page cursor is invalid')
            unless _page_effect_current($manifest, $effect, $args{page_snapshot});
        my $resolved = Selecto::Components::Templates::PageCursor->resolve(
            snapshot => $args{page_snapshot},
            source_id => $source->{id}, source_plan => $source,
            scope => $authority->{page_scope}, secret => $args{page_secret},
            token => $args{page_cursor},
            (exists($args{page_now}) ? (now => $args{page_now}) : ()),
            (exists($args{page_ttl_seconds})
                ? (ttl_seconds => $args{page_ttl_seconds}) : ()),
        );
        return $resolved unless $resolved->{status} eq 'ok';
        $page_position = $resolved->{position};
        my $bounded = Selecto::Templates->narrow_collection_page(
            $source,
            $args{page_snapshot}{sources}{$source->{id}}{result},
            $page_position,
        );
        return $bounded unless $bounded->{status} eq 'ok';
        $query_source = $bounded->{source};
        # The signed position identifies a root already visible in the held
        # page. Its offset must not skip that root on the scoped child read.
        delete $query_source->{query}{page};
    }
    if (exists($args{root_cursor}) && $args{root_cursor} ne 'first') {
        return _error('invalid_root_cursor', 'root page cursor is invalid')
            unless _page_effect_current($manifest, $effect, $args{root_snapshot});
        my $resolved = Selecto::Components::Templates::RootCursor->resolve(
            snapshot => $args{root_snapshot},
            source_id => $source->{id}, source_plan => $source,
            scope => $authority->{page_scope}, secret => $args{root_secret},
            token => $args{root_cursor},
            (exists($args{root_now}) ? (now => $args{root_now}) : ()),
            (exists($args{root_ttl_seconds})
                ? (ttl_seconds => $args{root_ttl_seconds}) : ()),
        );
        return $resolved unless $resolved->{status} eq 'ok';
        $root_position = $resolved->{position};
    }

    my $page_query = $authority->{query};
    if (defined($page_position)) {
        my $primary_key = $authority->{engine}->domain->primary_key;
        my $root_id = $page_position->{parent_path}[0];
        return _error('invalid_page_cursor', 'collection page cursor is invalid')
            unless defined($primary_key) && !ref($primary_key)
            && ref($source->{query}{select}) eq 'ARRAY'
            && scalar(grep { $_ eq $primary_key } @{$source->{query}{select}})
            && defined($root_id) && !ref($root_id);
        my $identity = Selecto::Expression->eq($primary_key, $root_id);
        my $existing = $page_query->predicate;
        $page_query = $page_query->where(
            defined($existing)
                ? Selecto::Expression->all($existing, $identity) : $identity,
        );
    }

    my ($lowered, $lowering_exception);
    {
        local $@;
        my $ok = eval {
            my $method = defined($page_position) ? 'lower_page_query'
                : exists($args{root_cursor}) ? 'lower_root_cursor_query'
                : 'lower_query';
            $lowered = Selecto::Templates->$method(
                source => $query_source,
                engine => $authority->{engine},
                query => $page_query,
                bindings => $effect->{bindings},
                (defined($page_position)
                    ? (page_position => $page_position) : ()),
                (defined($root_position)
                    ? (root_position => $root_position) : ()),
            );
            1;
        };
        $lowering_exception = $@ unless $ok;
    }
    if (defined($lowering_exception)) {
        return {
            status => 'error',
            %{$lowering_exception->as_hash},
        } if blessed($lowering_exception)
            && $lowering_exception->isa('Selecto::Templates::QueryLoweringDiagnostic');
        return _error('source_lowering_failed', 'template source lowering failed');
    }

    my $query_budget_error = _check_resource_budget($lowered, $budget);
    return $query_budget_error if $query_budget_error;

    my $statement_roles = _statement_roles($source, $page_position);
    return _error('invalid_source_shape', 'template source shape is invalid')
        unless $statement_roles;
    return _error('source_budget_exceeded', 'template source exceeds host budget')
        if @$statement_roles > $budget->{max_source_statements};

    my $declarations = $source->{query}{source_totals} // [];
    my %count_queries;
    if (@$declarations && !defined($page_position)) {
        my $ok = eval {
            for my $declaration (@$declarations) {
                next if $declaration->{scope} eq 'page'
                    && !exists($declaration->{association});
                my $id = $declaration->{id};
                if (exists($declaration->{association})) {
                    my $lowered_total = Selecto::Templates->lower_declared_related_total(
                        source => $source, engine => $authority->{engine},
                        query => $authority->{query}, bindings => $effect->{bindings},
                        total_id => $id,
                        (defined($root_position)
                            ? (root_position => $root_position) : ()),
                    );
                    $count_queries{$id} = {
                        %$lowered_total, function => $declaration->{function},
                    };
                }
                else {
                    $count_queries{$id} = Selecto::Templates->lower_declared_filtered_total(
                        source => $source, engine => $authority->{engine},
                        query => $authority->{query}, bindings => $effect->{bindings},
                        total_id => $id,
                    )->{query};
                }
            }
            1;
        };
        if (!$ok) {
            my $error = $@;
            return {status => 'error', %{$error->as_hash}}
                if blessed($error)
                && $error->isa('Selecto::Templates::QueryLoweringDiagnostic');
            return _error('source_lowering_failed', 'template source lowering failed');
        }
        return _error('source_snapshot_unavailable', 'template source snapshot is unavailable')
            if %count_queries && !(ref($args{snapshot_run}) eq 'CODE'
                || (!defined($run) && _snapshot_dbh($authority->{engine})));
    }

    my ($native, $source_totals, $execution_exception);
    {
        local $@;
        my $ok = eval {
            if (%count_queries) {
                my $snapshot = ref($args{snapshot_run}) eq 'CODE'
                    ? $args{snapshot_run}->(
                        $authority->{engine}, $lowered->{query}, \%count_queries,
                        $effect, $statement_roles,
                    )
                    : _execute_db_snapshot(
                        $authority->{engine}, $lowered->{query}, \%count_queries,
                    );
                $native = {rows => $snapshot->{rows}};
                $source_totals = $snapshot->{totals};
            }
            else {
                $native = defined($run)
                    ? $run->($authority->{engine}, $lowered->{query}, $effect)
                    : $authority->{engine}->all($lowered->{query});
            }
            1;
        };
        $execution_exception = $@ unless $ok;
    }
    return _error('source_execution_failed', 'template source execution failed')
        if defined($execution_exception)
        || ref($native) ne 'HASH' || ref($native->{rows}) ne 'ARRAY'
        || (%count_queries && ref($source_totals) ne 'HASH');

    my ($projected, $projection_exception);
    {
        local $@;
        my $ok = eval {
            $projected = _has_pages($lowered->{result_shape}{collections})
                ? Selecto::Templates->project_rows_with_pages(
                    $lowered->{result_shape}, $native->{rows},
                )
                : Selecto::Templates->project_rows(
                    $lowered->{result_shape}, $native->{rows},
                );
            1;
        };
        $projection_exception = $@ unless $ok;
    }
    return _error('invalid_source_result', 'template source result is invalid')
        if defined($projection_exception)
        || (ref($projected) eq 'HASH' && $projected->{status});

    if (defined($page_position)) {
        my $snapshot_source = $args{page_snapshot}{sources}{$effect->{source}};
        my $current = ref($snapshot_source) eq 'HASH'
            ? $snapshot_source->{result} : undef;
        my $max_items = _collection_max_items(
            $lowered->{result_shape}{collections},
            $page_position->{collection_path},
        );
        my $merged = eval {
            Selecto::Templates->merge_collection_page(
                $lowered->{result_shape}, $current, $projected,
                $page_position, $max_items,
            )
        };
        return _error('invalid_source_result', 'template source result is invalid')
            if $@ || ref($merged) ne 'HASH';
        return $merged if ($merged->{status} // '') eq 'error';
        $projected = $merged;
    }

    my $root_page;
    if (exists($lowered->{cursor_page})) {
        my $rows = ref($projected) eq 'HASH'
            ? $projected->{rows} : $projected;
        my $window = eval {
            Selecto::Templates->project_root_cursor_page(
                $lowered->{cursor_page}, $rows,
            )
        };
        return _error('invalid_source_result', 'template source result is invalid')
            if $@ || ref($window) ne 'HASH' || $window->{status};
        my $visible = _visible_root_result(
            $projected, $window->{items},
            $lowered->{cursor_page}{primary_key},
        );
        return _error('invalid_source_result', 'template source result is invalid')
            unless defined($visible);
        $projected = $visible;
        $root_page = {
            config => $lowered->{cursor_page},
            has_more => $window->{has_more},
            after_values => $window->{after_values},
        };
    }

    if (@$declarations && !defined($page_position)) {
        my $attached = eval {
            Selecto::Templates->attach_source_totals(
                $source, $projected, $source_totals // {},
            )
        };
        return _error('invalid_source_result', 'template source result is invalid')
            if $@ || ref($attached) ne 'HASH';
        $projected = $attached;
    }
    if ($root_page) {
        $projected = {rows => $projected} if ref($projected) eq 'ARRAY';
        return _error('invalid_source_result', 'template source result is invalid')
            unless ref($projected) eq 'HASH'
            && ref($projected->{rows}) eq 'ARRAY';
        $projected->{root_page} = $root_page;
    }

    my $public_rows = ref($projected) eq 'HASH'
        ? $projected->{rows} : $projected;

    my $projected_error = _check_projected_nodes(
        $public_rows, $lowered->{result_shape}, $lowered->{query}->limit_value, $budget,
    );
    return $projected_error if $projected_error;

    my $result_json = eval { JSON::PP->new->utf8->canonical->encode($projected) };
    return _error('invalid_source_result', 'template source result is invalid')
        if $@ || !defined($result_json);
    return _error('source_result_too_large', 'template source result exceeds host byte budget')
        if length($result_json) > $budget->{max_result_bytes};

    return {status => 'ok', result => $projected};
}

sub _visible_root_result {
    my ($projected, $visible, $primary_key) = @_;
    return undef unless ref($visible) eq 'ARRAY';
    return $visible if ref($projected) eq 'ARRAY';
    return undef unless ref($projected) eq 'HASH'
        && join(',', sort keys %$projected) eq 'identities,pages,rows'
        && ref($projected->{pages}) eq 'ARRAY'
        && ref($projected->{identities}) eq 'ARRAY';
    my %keys = map { $_->{$primary_key} => 1 } @$visible;
    for my $entry (@{$projected->{pages}}, @{$projected->{identities}}) {
        return undef unless ref($entry) eq 'HASH'
            && ref($entry->{parent_path}) eq 'ARRAY'
            && @{$entry->{parent_path}}
            && defined($entry->{parent_path}[0]);
    }
    return {
        rows => $visible,
        pages => [grep { $keys{$_->{parent_path}[0]} } @{$projected->{pages}}],
        identities => [grep { $keys{$_->{parent_path}[0]} }
            @{$projected->{identities}}],
    };
}

sub _snapshot_dbh {
    my ($engine) = @_;
    my $adapter = eval { $engine->adapter };
    return undef unless blessed($adapter) && $adapter->isa('Selecto::PostgreSQL');
    my $dbh = eval { $adapter->dbh };
    return blessed($dbh) && $dbh->isa('DBI::db') && $dbh->{AutoCommit}
        ? $dbh : undef;
}

sub _execute_db_snapshot {
    my ($engine, $page_query, $count_queries) = @_;
    my $dbh = _snapshot_dbh($engine)
        or die "template source snapshot is unavailable\n";
    $dbh->begin_work;
    my $result = eval {
        $dbh->do('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
        my $page = $engine->all($page_query);
        my %totals;
        for my $id (sort keys %$count_queries) {
            my $total = $count_queries->{$id};
            if (ref($total) eq 'HASH') {
                my $value = $engine->projection_sum($total->{query}, $total->{column});
                die "invalid source total\n"
                    unless defined($value) && !ref($value);
                if ($total->{function} eq 'count') {
                    die "invalid source total\n"
                        unless "$value" =~ /\A(?:0|[1-9][0-9]*)\z/;
                    $totals{$id} = 0 + $value;
                }
                elsif ($total->{function} eq 'sum') {
                    die "invalid source total\n"
                        unless "$value" =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/;
                    my $decimal = "$value";
                    $decimal =~ s/(\.[0-9]*?)0+\z/$1/;
                    $decimal =~ s/\.\z//;
                    $decimal = '0' if $decimal eq '-0';
                    $totals{$id} = $decimal;
                }
                else {
                    die "invalid source total\n";
                }
            }
            else {
                my $count = $engine->all($total);
                die "invalid source total\n"
                    unless ref($count) eq 'HASH' && ref($count->{rows}) eq 'ARRAY'
                    && @{$count->{rows}} == 1 && ref($count->{rows}[0]) eq 'ARRAY'
                    && @{$count->{rows}[0]} == 1;
                $totals{$id} = $count->{rows}[0][0];
            }
        }
        {rows => $page->{rows}, totals => \%totals};
    };
    if ($@ || ref($result) ne 'HASH') {
        eval { $dbh->rollback };
        die "template source snapshot failed\n";
    }
    $dbh->commit;
    return $result;
}

sub _page_effect_current {
    my ($manifest, $effect, $snapshot) = @_;
    return 0 unless ref($snapshot) eq 'HASH'
        && ref($manifest->{template}) eq 'HASH'
        && defined($snapshot->{template_fingerprint})
        && $snapshot->{template_fingerprint}
            eq ($manifest->{template}{fingerprint} // '')
        && ref($snapshot->{sources}) eq 'HASH'
        && ref($snapshot->{sources}{$effect->{source}}) eq 'HASH'
        && defined($snapshot->{sources}{$effect->{source}}{generation})
        && !ref($snapshot->{sources}{$effect->{source}}{generation})
        && $snapshot->{sources}{$effect->{source}}{generation}
            == $effect->{generation}
        && defined($snapshot->{instance_id})
        && ($effect->{effect_id} // '') eq join(':',
            $snapshot->{instance_id}, 'source', $effect->{source},
            $effect->{generation});
    my $expected = {
        input => $snapshot->{inputs}, state => $snapshot->{state},
    };
    my $json = JSON::PP->new->canonical(1)->allow_nonref(1);
    my $same = eval {
        $json->encode($expected) eq $json->encode($effect->{bindings})
    };
    return $same ? 1 : 0;
}

sub _has_pages {
    my ($collections) = @_;
    return 0 unless ref($collections) eq 'ARRAY';
    for my $collection (@$collections) {
        next unless ref($collection) eq 'HASH';
        return 1 if exists($collection->{page_size});
        return 1 if _has_pages($collection->{collections});
    }
    return 0;
}

sub _collection_max_items {
    my ($collections, $path) = @_;
    return undef unless ref($collections) eq 'ARRAY'
        && ref($path) eq 'ARRAY' && @$path;
    my $current = $collections;
    my $collection;
    for my $id (@$path) {
        my @matching = grep {
            ref($_) eq 'HASH' && defined($_->{id}) && $_->{id} eq $id
        } @$current;
        return undef unless @matching == 1;
        $collection = $matching[0];
        $current = $collection->{collections};
        return undef unless ref($current) eq 'ARRAY';
    }
    return $collection->{max_items};
}

sub _resource_budget {
    my ($overrides) = @_;
    return (undef, _error('invalid_source_budget', 'host source budget is invalid'))
        if defined($overrides) && ref($overrides) ne 'HASH';
    $overrides //= {};
    my %budget = (%DEFAULT_RESOURCE_BUDGET, %$overrides);
    for my $key (keys %budget) {
        return (undef, _error('invalid_source_budget', 'host source budget is invalid'))
            unless exists($DEFAULT_RESOURCE_BUDGET{$key})
            && defined($budget{$key}) && !ref($budget{$key})
            && "$budget{$key}" =~ /\A[1-9][0-9]*\z/;
    }
    return (\%budget, undef);
}

sub _statement_roles {
    my ($source, $page_position) = @_;
    my $declarations = $source->{query}{source_totals} // [];
    return undef unless ref($declarations) eq 'ARRAY';
    return ['page'] if defined($page_position);
    my @names;
    for my $declaration (@$declarations) {
        return undef unless ref($declaration) eq 'HASH';
        my $related = exists($declaration->{association});
        return undef unless defined($declaration->{id}) && !ref($declaration->{id})
            && length($declaration->{id})
            && ($declaration->{scope} // '') =~ /\A(?:page|filtered)\z/
            && ($related
                ? (($declaration->{function} // '') =~ /\A(?:count|sum)\z/
                    && defined($declaration->{association}) && length($declaration->{association})
                    && defined($declaration->{target_schema}) && length($declaration->{target_schema})
                    && defined($declaration->{field}) && length($declaration->{field}))
                : ($declaration->{function} // '') eq 'count');
        push @names, "$declaration->{scope}_total:$declaration->{id}"
            if $declaration->{scope} eq 'filtered' || $related;
    }
    return ['page', sort @names];
}

sub _check_resource_budget {
    my ($lowered, $budget) = @_;

    my $root_rows = $lowered->{query}->limit_value;
    return _error('invalid_source_shape', 'template source shape is invalid')
        unless defined($root_rows) && !ref($root_rows)
        && "$root_rows" =~ /\A[1-9][0-9]*\z/;
    return _error('source_budget_exceeded', 'template source exceeds host budget')
        if $root_rows > $budget->{max_root_rows};
    my $collections = $lowered->{result_shape}{collections};
    my ($nodes_per_root, $error) = _count_nodes($collections, 1, $budget);
    return $error if $error;
    return _error('source_budget_exceeded', 'template source exceeds host budget')
        if $nodes_per_root > int($budget->{max_result_nodes} / $root_rows);
    return undef;
}

sub _count_nodes {
    my ($collections, $depth, $budget) = @_;
    return (undef, _error('invalid_source_shape', 'template source shape is invalid'))
        unless ref($collections) eq 'ARRAY';
    my $count = 1;
    for my $collection (@$collections) {
        return (undef, _error('invalid_source_shape', 'template source shape is invalid'))
            unless ref($collection) eq 'HASH'
            && ref($collection->{collections}) eq 'ARRAY';
        return (undef, _error('unbounded_collection', 'template collection has no row bound'))
            unless defined($collection->{max_items}) && !ref($collection->{max_items})
            && "$collection->{max_items}" =~ /\A[1-9][0-9]*\z/;
        return (undef, _error('source_budget_exceeded', 'template source exceeds host budget'))
            if $depth > $budget->{max_collection_depth};
        my ($nodes_per_child, $error) = _count_nodes(
            $collection->{collections}, $depth + 1, $budget,
        );
        return (undef, $error) if $error;
        return (undef, _error('source_budget_exceeded', 'template source exceeds host budget'))
            if $collection->{max_items} > int($budget->{max_result_nodes} / $nodes_per_child);
        $count += $collection->{max_items} * $nodes_per_child;
        return (undef, _error('source_budget_exceeded', 'template source exceeds host budget'))
            if $count > $budget->{max_result_nodes};
    }
    return ($count, undef);
}

sub _check_projected_nodes {
    my ($rows, $shape, $root_limit, $budget) = @_;
    return _error('invalid_source_result', 'template source result is invalid')
        unless ref($rows) eq 'ARRAY' && ref($shape) eq 'HASH'
        && ref($shape->{collections}) eq 'ARRAY';
    return _error('source_budget_exceeded', 'template source exceeds host budget')
        if @$rows > $root_limit || @$rows > $budget->{max_root_rows};
    my ($count, $error) = _count_projected_rows(
        $rows, $shape->{collections}, $budget,
    );
    return $error;
}

sub _count_projected_rows {
    my ($rows, $collections, $budget) = @_;
    my $count = 0;
    for my $row (@$rows) {
        return (undef, _error('invalid_source_result', 'template source result is invalid'))
            unless ref($row) eq 'HASH';
        my $row_count = 1;
        for my $collection (@$collections) {
            my $items = $row->{$collection->{id}};
            return (undef, _error('invalid_source_result', 'template source result is invalid'))
                unless ref($items) eq 'ARRAY';
            return (undef, _error('source_budget_exceeded', 'template source exceeds host budget'))
                if @$items > $collection->{max_items};
            my ($child_count, $error) = _count_projected_rows(
                $items, $collection->{collections}, $budget,
            );
            return (undef, $error) if $error;
            $row_count += $child_count;
            return (undef, _error('source_budget_exceeded', 'template source exceeds host budget'))
                if $row_count > $budget->{max_result_nodes};
        }
        $count += $row_count;
        return (undef, _error('source_budget_exceeded', 'template source exceeds host budget'))
            if $count > $budget->{max_result_nodes};
    }
    return ($count, undef);
}

sub _valid_effect {
    my ($effect) = @_;
    return ref($effect) eq 'HASH'
        && ($effect->{schema} // '') eq 'selecto.template.runtime-effect.v1'
        && ($effect->{kind} // '') eq 'load_source'
        && defined($effect->{effect_id}) && !ref($effect->{effect_id}) && length($effect->{effect_id})
        && defined($effect->{source}) && !ref($effect->{source}) && length($effect->{source})
        && defined($effect->{generation}) && !ref($effect->{generation})
        && "$effect->{generation}" =~ /\A[1-9][0-9]*\z/
        && ref($effect->{bindings}) eq 'HASH'
        && ref($effect->{bindings}{input}) eq 'HASH'
        && ref($effect->{bindings}{state}) eq 'HASH';
}

sub _error {
    my ($code, $message) = @_;
    return {status => 'error', code => $code, message => $message};
}

1;
