package Selecto::Components::Actions;

use 5.034;
use strict;
use warnings;
use Mojo::Base -base, -signatures;
use Mojo::JSON qw(decode_json);
use Storable qw(dclone);

my @LUCKY_CHARMS_MARKERS = (
    {
        id => 'red_star', label => 'Red star', shape => 'star', color => '#dc2626',
    },
    {
        id => 'green_circle', label => 'Green circle', shape => 'circle', color => '#16a34a',
    },
    {
        id => 'purple_horseshoe', label => 'Purple horseshoe', shape => 'horseshoe', color => '#9333ea',
    },
    {
        id => 'blue_moon', label => 'Blue moon', shape => 'moon', color => '#2563eb',
    },
    {
        id => 'pink_heart', label => 'Pink heart', shape => 'heart', color => '#db2777',
    },
    {
        id => 'green_clover', label => 'Green clover', shape => 'clover', color => '#22c55e',
    },
    {
        id => 'orange_diamond', label => 'Orange diamond', shape => 'diamond', color => '#ea580c',
    },
    {
        id => 'sky_rainbow', label => 'Sky rainbow', shape => 'rainbow', color => '#0891b2',
    },
);

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

sub request ($class, $config, $action, $selected_ids, $raw_inputs, $options = undef) {
    $options = {} unless ref($options) eq 'HASH';
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

    my ($inputs, $input_errors) = _request_inputs($action->{inputs}, $raw_inputs);
    push @errors, @$input_errors;

    my $groups = [];
    if (($action->{selection}{mode} // 'rows') eq 'groups') {
        my ($normalized_groups, $group_errors) = _request_groups(
            $action, \@ids, $options->{group_payload},
        );
        $groups = $normalized_groups;
        push @errors, @$group_errors;
    }

    return {
        valid => @errors ? 0 : 1,
        errors => \@errors,
        action => $action,
        selected_ids => \@ids,
        inputs => $inputs,
        groups => $groups,
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
    $action->{selection} = $class->_normalize_selection(
        $action->{selection}, $config, $controller, $action,
    );
    $action->{submit_label} = _text($action->{submit_label})
        || ($action->{selection}{mode} eq 'groups' ? $action->{label} : 'Apply to selected rows');
    return $action;
}

sub _normalize_selection ($class, $spec, $config, $controller, $action) {
    return {mode => 'rows'} unless ref($spec) eq 'HASH'
        && lc(_text($spec->{mode})) eq 'groups';
    my $palette = lc(_text($spec->{palette}) || 'lucky_charms');
    return {mode => 'rows'} unless $palette eq 'lucky_charms';
    my $maximum = _text($spec->{max_groups});
    $maximum = scalar(@LUCKY_CHARMS_MARKERS)
        unless $maximum =~ /\A\d+\z/ && $maximum >= 1
            && $maximum <= @LUCKY_CHARMS_MARKERS;
    my @markers = map { dclone($_) } @LUCKY_CHARMS_MARKERS[0 .. $maximum - 1];
    return {
        mode => 'groups',
        palette => $palette,
        max_groups => 0 + $maximum,
        markers => \@markers,
        group_inputs => $class->_normalize_inputs(
            $spec->{group_inputs}, $config, $controller, $action,
        ),
    };
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
            (defined($spec->{minimum}) ? (minimum => 0 + $spec->{minimum}) : ()),
            (defined($spec->{maximum}) ? (maximum => 0 + $spec->{maximum}) : ()),
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

sub _request_inputs {
    my ($specs, $raw) = @_;
    $specs = [] unless ref($specs) eq 'ARRAY';
    $raw = {} unless ref($raw) eq 'HASH';
    my (%inputs, @errors);
    for my $input (@$specs) {
        my $id = $input->{id};
        my $value = exists($raw->{$id}) && defined($raw->{$id}) ? "$raw->{$id}" : '';
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
        if ($input->{type} eq 'number' && $value !~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/) {
            push @errors, "$input->{label} must be a number.";
        } elsif ($input->{type} eq 'number') {
            push @errors, "$input->{label} is below its minimum."
                if defined($input->{minimum}) && $value < $input->{minimum};
            push @errors, "$input->{label} is above its maximum."
                if defined($input->{maximum}) && $value > $input->{maximum};
        }
        if (defined($input->{min_length}) && length($value) < $input->{min_length}) {
            push @errors, "$input->{label} is too short.";
        }
        if (defined($input->{max_length}) && length($value) > $input->{max_length}) {
            push @errors, "$input->{label} is too long.";
        }
        $inputs{$id} = $value;
    }
    return (\%inputs, \@errors);
}

sub _request_groups {
    my ($action, $selected_ids, $payload) = @_;
    my @errors;
    my $raw_groups;
    if (!defined($payload) || ref($payload) || length($payload) > 131_072
        || !eval { $raw_groups = decode_json($payload); 1 }
        || ref($raw_groups) ne 'ARRAY') {
        return ([], ['The action groups are invalid.']);
    }
    my $selection = $action->{selection};
    push @errors, 'Create at least one group.' unless @$raw_groups;
    push @errors, 'Too many groups were created.'
        if @$raw_groups > $selection->{max_groups};

    my %selected = map { $_ => 1 } @$selected_ids;
    my (%used_row, %used_index);
    my @groups;
    for my $raw (@$raw_groups) {
        unless (ref($raw) eq 'HASH') {
            push @errors, 'A group is invalid.';
            next;
        }
        my $index = $raw->{index};
        unless (defined($index) && !ref($index) && "$index" =~ /\A\d+\z/
            && $index < $selection->{max_groups} && !$used_index{$index}++) {
            push @errors, 'A group marker is invalid.';
            next;
        }
        my @group_ids;
        my $raw_ids = $raw->{selected_ids};
        if (ref($raw_ids) eq 'ARRAY') {
            for my $value (@$raw_ids) {
                next unless defined($value) && !ref($value);
                my $id = "$value";
                $id =~ s/\A\s+|\s+\z//g;
                if (!$selected{$id} || $used_row{$id}++) {
                    push @errors, 'A selected row appears in an invalid group.';
                    next;
                }
                push @group_ids, $id;
            }
        }
        push @errors, 'Every group must contain at least one row.' unless @group_ids;
        my ($inputs, $input_errors) = _request_inputs(
            $selection->{group_inputs}, $raw->{inputs},
        );
        push @errors, map { $selection->{markers}[$index]{label} . ': ' . $_ } @$input_errors;
        push @groups, {
            index => 0 + $index,
            marker => dclone($selection->{markers}[$index]),
            selected_ids => \@group_ids,
            inputs => $inputs,
        };
    }
    push @errors, 'Every selected row must belong to exactly one group.'
        if grep { !$used_row{$_} } @$selected_ids;
    @groups = sort { $a->{index} <=> $b->{index} } @groups;
    return (\@groups, \@errors);
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
