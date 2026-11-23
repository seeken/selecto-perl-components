package Selecto::Components::PivotValues;

use Mojo::Base -base, -signatures;
use Selecto::BoundedQuery ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Query ();

# The same stable identities and order serve pivot columns and graph series.
sub layout ($class, $axis) {
    return ((map { {value => $axis->{pivot_labels}{$_} // $_, selection_value => $_} } @{$axis->{pivot_values}}),
        ($axis->{pivot_other} ? ({value => 'Other', selection_value => $axis->{pivot_other_value}}) : ()));
}

# A rank belongs to a selected key, including the missing-value sentinel.
# Other has no rank. Labels and identities themselves remain unchanged.
sub rank_prefix ($class, $axis, $entry) {
    return '' unless $axis->{pivot_ranked};
    my $key = $entry->{selection_value};
    return '' unless defined $key;
    my $rank = 0;
    for my $value (@{$axis->{pivot_values} // []}) {
        $rank++;
        return "$rank \x{b7} " if "$value" eq "$key";
    }
    return '';
}

sub entry_order ($class, $column) {
    if ($column->{pivot_values}) {
        my $i = 0;
        my %rank = map { ("$_" => $i++) } @{$column->{pivot_values}};
        return sub ($left, $right) {
            ($rank{$left->{selection_value} // ''} // 100000) <=> ($rank{$right->{selection_value} // ''} // 100000)
        };
    }
    if ($column->{value_order}) {
        my $i = 0;
        my %rank = map { ("$_" => $i++) } @{$column->{value_order}};
        return sub ($left, $right) {
            my $lv = exists($left->{selection_value}) ? $left->{selection_value} : $left->{value};
            my $rv = exists($right->{selection_value}) ? $right->{selection_value} : $right->{value};
            !defined($lv) <=> !defined($rv)
                || (defined($lv) && defined($rv) ? ($rank{$lv} // $i) <=> ($rank{$rv} // $i)
                    || _text_order($left->{value}, $right->{value}) : 0)
        };
    }
    die "entry_order requires chosen values or value_order metadata\n";
}

sub _text_order ($left, $right) {
    return 0 unless defined($left) && defined($right);
    return !length("$left") <=> !length("$right")
        || fc("$left") cmp fc("$right") || "$left" cmp "$right";
}

# A dimension chooser reads the lookup relation, including unused keys. Keep
# its authored target predicates and pinned tenant/scope pairs. Core owns SQL
# compilation, typed binding, execution budgets and inline-value relations.
sub dimension_rows ($class, $engine, $dimension, %options) {
    my $resolved = $engine->domain->resolve_association($dimension->{association});
    my $association = $resolved->{association};
    # Source-dependent joins without a pinned scope must use reachable rows.
    return $class->_reachable_rows($engine, $dimension, %options)
        if $association->through || @{$association->conditions // []};
    my $contract = $engine->domain->contract;
    my $source = defined($association->queryable)
        ? $contract->{schemas}{$association->queryable} : undef;
    my $lookup_domain;
    if ($source) {
        $lookup_domain = Selecto::Domain->parse({schema_version => 1, name => 'Column values',
            source => $source, schemas => $contract->{schemas} // {}, joins => {}}, strict => 1);
    } else {
        return $class->_reachable_rows($engine, $dimension, %options) if $association->values;
        $lookup_domain = Selecto::Domain->new(name => 'Column values', table => $association->table,
            fields => $association->fields, primary_key => $association->related_key);
    }
    my @conditions;
    my $where = $association->where;
    for my $field (sort keys %$where) {
        my $value = $where->{$field};
        push @conditions, !defined($value) ? Selecto::Expression->is_null($field)
            : ref($value) eq 'ARRAY'
                ? Selecto::Expression->can($value->[0])->('Selecto::Expression', $field, Selecto::Expression->field($value->[1][1]))
                : Selecto::Expression->eq($field, $value);
    }
    my $parent = $dimension->{association} =~ s/\.?[^.]+\z//r;
    my @pairs;
    push @pairs, [$association->source_tenant_field, $association->target_tenant_field]
        if defined($association->target_tenant_field);
    push @pairs, [$association->source_scope_key, $association->target_scope_key]
        if defined($association->target_scope_key);
    my %pins;
    _pins($engine->read_domain->required_predicate, \%pins);
    return $class->_reachable_rows($engine, $dimension, %options) if delete $pins{__conflicting};
    for my $pair (@pairs) {
        my $source = $pair->[0];
        my $pin = defined($source) ? $pins{length($parent) ? "$parent.$source" : $source} : $engine->scope->{tenant} // $engine->tenant_context->{tenant_id};
        return $class->_reachable_rows($engine, $dimension, %options) unless defined($pin);
        push @conditions, Selecto::Expression->eq($pair->[1], $pin);
    }
    $lookup_domain = $lookup_domain->with_required_predicate(Selecto::Expression->all(\@conditions)) if @conditions;
    my $lookup = Selecto::Engine->new(domain => $lookup_domain, adapter => $engine->adapter, limits => $engine->limits);
    my $context = $engine->tenant_context;
    $lookup = $lookup->with_read_context({prefix => $context->{prefix}}) if defined($context->{prefix});
    return _rows($lookup, $association->related_key, $association->display_field, %options);
}

sub _pins ($predicate, $pins) {
    return unless $predicate;
    if ($predicate->kind eq 'and') { _pins($_, $pins) for @{$predicate->arguments->[0]} }
    elsif ($predicate->kind eq 'eq') {
        my ($field, $value) = @{$predicate->arguments};
        $value = $value->arguments->[0] if ref($value) && $value->kind eq 'literal';
        return unless ref($field) && $field->kind eq 'field' && defined($value) && !ref($value);
        my $name = $field->arguments->[0];
        $pins->{__conflicting} = 1 if defined($pins->{$name}) && "$pins->{$name}" ne "$value";
        $pins->{$name} = $value;
    }
}

sub _reachable_rows ($class, $engine, $dimension, %options) {
    return _rows($engine, $dimension->{key_field}, $dimension->{display_field}, %options, grouped => 1);
}

sub _rows ($engine, $key, $display, %options) {
    my $query = Selecto::Query->new->select(Selecto::Expression->field($key)->as('value'),
        ($options{grouped} ? Selecto::Expression->min($display) : Selecto::Expression->field($display))->as('label'));
    $query = $query->group_by([$key]) if $options{grouped};
    $query = $query->where(Selecto::Expression->in($key, $options{values})) if $options{values};
    $query = $query->where(Selecto::Expression->text_contains_ci($display, $options{term})) if defined($options{term});
    my $label_order = $options{grouped} ? Selecto::Expression->min($display) : Selecto::Expression->field($display);
    $query = $query->order_by($label_order, 'asc')->order_by($key, 'asc')->limit($options{limit} // 30);
    my $raw = Selecto::BoundedQuery->all($engine, $query, limits => $engine->limits);
    return [map { [@$_[0,1]] } @{$raw->{rows}}];
}

1;
