package Selecto::Components::Actions;

use 5.034;
use strict;
use warnings;
use Mojo::Base -base, -signatures;
use Storable qw(dclone);

sub available ($class, $config, $domain, $controller, $phase = 'preview', $target = undef) {
    my $actions = $domain->actions;
    return [] unless ref($actions) eq 'HASH';

    my @available;
    for my $id (sort keys %$actions) {
        next unless $config->action_handler($id);
        my $action = $class->_normalize_action($id, $actions->{$id}, $config, $controller);
        next unless $action && $class->_bulk_enabled($action);
        my $decision = $class->_authorize($config, $controller, $action, $phase, $target);
        next if $decision->{status} eq 'hidden';
        $action->{status} = $decision->{status};
        $action->{status_reason} = $decision->{reason} if defined $decision->{reason};
        push @available, $action;
    }
    return \@available;
}

sub find ($class, $config, $domain, $controller, $id, $phase = 'preview', $target = undef) {
    return undef unless defined($id) && !ref($id) && "$id" =~ /\A[a-z][a-z0-9_-]*\z/;
    my $actions = $domain->actions;
    return undef unless ref($actions) eq 'HASH' && ref($actions->{$id}) eq 'HASH';
    return undef unless $config->action_handler($id);
    my $action = $class->_normalize_action($id, $actions->{$id}, $config, $controller);
    return undef unless $action && $class->_bulk_enabled($action);
    my $decision = $class->_authorize($config, $controller, $action, $phase, $target);
    return { action => $action, decision => $decision };
}

sub authorize ($class, $config, $controller, $action, $phase, $target = undef) {
    return $class->_authorize($config, $controller, $action, $phase, $target);
}

sub request ($class, $config, $action, $selected_ids, $raw_inputs) {
    my @errors;
    my @ids;
    my %seen;
    for my $value (@{$selected_ids // []}) {
        next unless defined($value) && !ref($value);
        my $id = "$value";
        $id =~ s/\A\s+|\s+\z//g;
        next if $id eq '' || $seen{$id}++;
        if (length($id) > 200 || $id =~ /\0/) {
            push @errors, 'A selected row identifier is invalid.';
            next;
        }
        push @ids, $id;
    }
    push @errors, 'Select at least one row.' unless @ids;
    push @errors, 'Too many rows were selected for one action.' if @ids > $config->max_action_rows;

    $raw_inputs = {} unless ref($raw_inputs) eq 'HASH';
    my %inputs;
    for my $input (@{$action->{inputs}}) {
        my $id = $input->{id};
        my $value = exists($raw_inputs->{$id}) && defined($raw_inputs->{$id})
            ? "$raw_inputs->{$id}" : '';
        $value =~ s/\r\n?/\n/g;
        $value =~ s/\A\s+|\s+\z//g if $input->{trim};

        if ($input->{required} && $value eq '') {
            push @errors, "$input->{label} is required.";
            next;
        }
        next if $value eq '' && !$input->{required};

        if ($input->{type} eq 'select') {
            my %allowed = map { ($_->{value} . '') => 1 } @{$input->{options}};
            push @errors, "$input->{label} is not an available choice." unless $allowed{$value};
        }
        if (defined($input->{min_length}) && length($value) < $input->{min_length}) {
            push @errors, "$input->{label} is too short.";
        }
        if (defined($input->{max_length}) && length($value) > $input->{max_length}) {
            push @errors, "$input->{label} is too long.";
        }
        $inputs{$id} = $value;
    }

    return {
        valid => @errors ? 0 : 1,
        errors => \@errors,
        action => $action,
        selected_ids => \@ids,
        inputs => \%inputs,
    };
}

sub _normalize_action ($class, $id, $spec, $config, $controller) {
    return undef unless ref($spec) eq 'HASH';
    my $action = dclone($spec);
    $action->{id} = "$id";
    $action->{label} = _text($action->{label} // $action->{name}) || _humanize($id);
    $action->{description} = _text($action->{description});
    $action->{scope} = lc(_text($action->{scope}) || 'row');
    $action->{inputs} = $class->_normalize_inputs($action->{inputs}, $config, $controller, $action);
    return $action;
}

sub _normalize_inputs ($class, $specs, $config, $controller, $action) {
    my @specs;
    if (ref($specs) eq 'ARRAY') {
        @specs = @$specs;
    } elsif (ref($specs) eq 'HASH') {
        @specs = map { +{id => $_, %{$specs->{$_}}} } sort keys %$specs;
    }

    my @inputs;
    my %seen;
    for my $spec (@specs) {
        next unless ref($spec) eq 'HASH';
        my $id = _text($spec->{id});
        next unless $id =~ /\A[a-z][a-z0-9_]*\z/ && !$seen{$id}++;
        my $type = lc(_text($spec->{type}) || 'string');
        $type = 'textarea' if $type eq 'text';
        $type = 'select' if $type eq 'choice';
        $type = 'string' unless $type =~ /\A(?:string|textarea|select|number|date|datetime-local)\z/;
        my $input = {
            id => $id,
            label => _text($spec->{label}) || _humanize($id),
            type => $type,
            required => $spec->{required} ? 1 : 0,
            trim => exists($spec->{trim}) ? ($spec->{trim} ? 1 : 0) : 1,
            (defined($spec->{min_length}) ? (min_length => 0 + $spec->{min_length}) : ()),
            (defined($spec->{max_length}) ? (max_length => 0 + $spec->{max_length}) : ()),
            (defined($spec->{rows}) ? (rows => 0 + $spec->{rows}) : ()),
        };
        my $options = $spec->{options};
        my $source = _text($spec->{choice_source});
        if ($source ne '') {
            my $resolver = $config->choice_source($source);
            $options = $resolver ? $resolver->($controller, $action, $spec) : [];
        }
        $input->{options} = _normalize_options($options) if $type eq 'select';
        push @inputs, $input;
    }
    return \@inputs;
}

sub _authorize ($class, $config, $controller, $action, $phase, $target) {
    my $resolver = $config->action_authorizer;
    return {status => 'enabled'} unless $resolver || _text($action->{capability}) ne '';
    return {
        status => 'hidden',
        reason => 'The host did not provide an action capability resolver.',
    } unless $resolver;
    my $raw = $resolver->($controller, {
        phase => $phase,
        action => $action,
        capability => $action->{capability},
        target => $target,
    });
    return {status => $raw} if defined($raw) && !ref($raw)
        && $raw =~ /\A(?:enabled|disabled|hidden)\z/;
    if (ref($raw) eq 'HASH') {
        my $status = _text($raw->{status});
        return {
            status => $status =~ /\A(?:enabled|disabled|hidden)\z/ ? $status : 'hidden',
            (defined($raw->{reason}) ? (reason => _text($raw->{reason})) : ()),
        };
    }
    return {status => 'hidden', reason => 'Action authorization is unavailable.'};
}

sub _bulk_enabled ($class, $action) {
    return 1 if $action->{scope} eq 'bulk';
    my $bulk = $action->{bulk};
    return 1 if defined($bulk) && !ref($bulk) && "$bulk" =~ /\A(?:1|true)\z/i;
    return ref($bulk) eq 'HASH' && $bulk->{enabled} ? 1 : 0;
}

sub _normalize_options {
    my ($options) = @_;
    my @options;
    if (ref($options) eq 'HASH') {
        @options = map { +{value => "$_", label => _text($options->{$_})} }
            sort { lc(_text($options->{$a})) cmp lc(_text($options->{$b})) } keys %$options;
    } elsif (ref($options) eq 'ARRAY') {
        for my $option (@$options) {
            if (ref($option) eq 'HASH') {
                my $value = _text($option->{value} // $option->{id});
                next if $value eq '';
                push @options, {value => $value, label => _text($option->{label} // $option->{name}) || $value};
            } elsif (defined($option) && !ref($option)) {
                push @options, {value => "$option", label => "$option"};
            }
        }
    }
    return \@options;
}

sub _humanize {
    my ($value) = @_;
    my $text = "$value";
    $text =~ s/[_-]+/ /g;
    $text =~ s/\b([a-z])/uc($1)/eg;
    return $text;
}

sub _text {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    return "$value";
}

1;
