package Selecto::Components::I18N;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Selecto::Components::Util qw(humanize);

sub localize ($class, $localizer, $domain, $semantic, $default, $context = undef) {
    $default = _text($default);
    return $default unless ref($localizer) eq 'CODE' && length($default);
    my $spec = $class->term($domain, $semantic, $default);
    return $default unless $spec;

    my $localized;
    my $ok = eval {
        $localized = $localizer->(
            $spec->{key}, $spec->{default}, {
                namespace => $spec->{namespace},
                semantic => $spec->{semantic},
                domain => $domain,
                (ref($context) eq 'HASH' ? (%$context) : ()),
            },
        );
        1;
    };
    return $default unless $ok && defined($localized) && !ref($localized);
    $localized = "$localized";
    return $default if !length($localized) || $localized =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    return $localized;
}

sub term ($class, $domain, $semantic, $default = undef) {
    my $metadata = _metadata($domain) or return undef;
    $semantic = _semantic($semantic);
    my $entry = $metadata->{terms}{$semantic};
    my ($key, $entry_default);
    if (defined($entry) && !ref($entry)) {
        $key = _dictionary_key($entry);
    } elsif (ref($entry) eq 'HASH') {
        $key = _dictionary_key($entry->{key}) if exists($entry->{key});
        $entry_default = _text($entry->{default}) if exists($entry->{default});
    } elsif (defined($entry)) {
        die "Selecto i18n term $semantic must be a string or object\n";
    }
    $key //= _dictionary_key($metadata->{namespace} . '.' . $semantic);
    $default = length($entry_default // '') ? $entry_default : _text($default);
    return undef unless length($default);
    return {
        namespace => $metadata->{namespace},
        semantic => $semantic,
        key => $key,
        default => $default,
    };
}

sub terms ($class, $domain, $options = undef) {
    $options //= {};
    die "Selecto i18n term options must be an object\n" unless ref($options) eq 'HASH';
    my $metadata = _metadata($domain) or return [];
    my %terms;
    my $add = sub ($semantic, $default) {
        my $term = $class->term($domain, $semantic, $default);
        $terms{$term->{semantic}} = $term if $term;
    };

    my $contract = $domain->contract;
    $add->('domain.title', $options->{title} // $contract->{name});
    _field_terms($domain, $contract, $add);
    _query_library_terms($contract->{query_library}, $add);
    _action_terms($contract->{actions}, $add);

    for my $measure (@{$options->{measures} // []}) {
        next unless ref($measure) eq 'HASH';
        my $id = _id($measure->{id});
        next unless length($id);
        $add->("measures.$id.label", $measure->{label} // humanize($id));
    }

    for my $semantic (sort keys %{$metadata->{terms}}) {
        my $entry = $metadata->{terms}{$semantic};
        my $default = ref($entry) eq 'HASH' ? $entry->{default} : undef;
        $add->($semantic, $default);
    }
    return [map { $terms{$_} } sort keys %terms];
}

sub _field_terms ($domain, $contract, $add) {
    my $source = ref($contract->{source}) eq 'HASH' ? $contract->{source} : {};
    my ($by_key, $by_display) = _star_dimension_labels($domain);
    for my $field (sort keys %{$domain->fields}) {
        my $column = ref($source->{columns}) eq 'HASH' ? $source->{columns}{$field} : undef;
        my $default = $by_key->{$field} // _column_label($column, humanize($field));
        $add->("fields.$field.label", $default);
    }
    for my $association_name (sort keys %{$domain->associations}) {
        my $association = $domain->associations->{$association_name};
        $add->("associations.$association_name.label", humanize($association_name));
        my $association_spec = ref($source->{associations}) eq 'HASH'
            ? $source->{associations}{$association_name} : undef;
        my $queryable = ref($association_spec) eq 'HASH' ? $association_spec->{queryable} : undef;
        my $schema = defined($queryable) && ref($contract->{schemas}) eq 'HASH'
            ? $contract->{schemas}{$queryable} : undef;
        for my $field (sort keys %{$association->fields}) {
            my $path = "$association_name.$field";
            my $column = ref($schema) eq 'HASH' && ref($schema->{columns}) eq 'HASH'
                ? $schema->{columns}{$field} : undef;
            my $default = $by_display->{$path}
                // humanize($association_name) . ' - ' . _column_label($column, humanize($field));
            $add->("fields.$path.label", $default);
            $add->("fields.$path.nested_label", _column_label($column, humanize($field)))
                if $association->cardinality eq 'many';
        }
    }
}

sub _star_dimension_labels ($domain) {
    my (%by_key, %by_display);
    for my $name (sort keys %{$domain->associations}) {
        my $association = $domain->associations->{$name};
        next unless $association->can('join_mode') && $association->join_mode eq 'star_dimension';
        my $label = $association->display_name;
        $label = humanize($name) unless defined($label) && length("$label");
        $by_key{$association->dimension_key} = "$label";
        $by_display{$name . '.' . $association->display_field} = "$label";
    }
    return (\%by_key, \%by_display);
}

sub _query_library_terms ($library, $add) {
    return unless ref($library) eq 'HASH';
    for my $registry (qw(segments projections orderings views)) {
        my $definitions = $library->{$registry};
        next unless ref($definitions) eq 'HASH';
        for my $id (sort keys %$definitions) {
            my $spec = $definitions->{$id};
            next unless ref($spec) eq 'HASH';
            my $safe_id = _id($id);
            $add->("query_library.$registry.$safe_id.label", $spec->{label} // humanize($id));
            $add->("query_library.$registry.$safe_id.description", $spec->{description})
                if defined($spec->{description});
            _parameter_terms($spec->{parameters}, $add);
        }
    }
}

sub _parameter_terms ($parameters, $add) {
    return unless ref($parameters) eq 'HASH';
    for my $id (sort keys %$parameters) {
        my $spec = $parameters->{$id};
        next unless ref($spec) eq 'HASH';
        my $safe_id = _id($id);
        $add->("query_library.parameters.$safe_id.label", $spec->{label} // humanize($id));
        $add->("query_library.parameters.$safe_id.description", $spec->{description})
            if defined($spec->{description});
    }
}

sub _action_terms ($actions, $add) {
    return unless ref($actions) eq 'HASH';
    for my $id (sort keys %$actions) {
        my $spec = $actions->{$id};
        next unless ref($spec) eq 'HASH';
        my $safe_id = _id($id);
        my $prefix = "actions.$safe_id";
        $add->("$prefix.label", $spec->{label} // $spec->{name} // humanize($id));
        $add->("$prefix.description", $spec->{description}) if defined($spec->{description});
        my $submit_default = $spec->{submit_label};
        if (!defined($submit_default)) {
            my $groups = ref($spec->{selection}) eq 'HASH'
                && ($spec->{selection}{mode} // '') eq 'groups';
            $submit_default = $groups
                ? ($spec->{label} // $spec->{name} // humanize($id))
                : 'Apply to selected rows';
        }
        $add->("$prefix.submit_label", $submit_default);
        _input_terms($spec->{inputs}, "$prefix.inputs", $add);
        if (ref($spec->{selection}) eq 'HASH') {
            _input_terms($spec->{selection}{group_inputs}, "$prefix.selection.group_inputs", $add);
            _row_detail_terms($spec->{selection}{row_details}, "$prefix.selection.row_details", $add);
        }
    }
}

sub _input_terms ($inputs, $prefix, $add) {
    my @inputs = ref($inputs) eq 'ARRAY' ? @$inputs
        : ref($inputs) eq 'HASH'
            ? map { +{id => $_, %{$inputs->{$_}}} } sort keys %$inputs
            : ();
    for my $spec (@inputs) {
        next unless ref($spec) eq 'HASH';
        my $id = _id($spec->{id});
        next unless length($id);
        $add->("$prefix.$id.label", $spec->{label} // humanize($id));
        my $options = $spec->{options};
        if (ref($options) eq 'ARRAY') {
            for my $option (@$options) {
                next unless ref($option) eq 'HASH';
                my $value = _id($option->{value} // $option->{id});
                next unless length($value);
                $add->("$prefix.$id.options.$value.label",
                    $option->{label} // $option->{name} // $option->{value});
            }
        } elsif (ref($options) eq 'HASH') {
            for my $value (sort keys %$options) {
                $add->("$prefix.$id.options." . _id($value) . '.label', $options->{$value});
            }
        }
    }
}

sub _row_detail_terms ($details, $prefix, $add) {
    return unless ref($details) eq 'ARRAY';
    for my $spec (@$details) {
        next unless ref($spec) eq 'HASH';
        my $id = _id($spec->{id});
        next unless length($id);
        $add->("$prefix.$id.label", $spec->{label} // humanize($id));
    }
}

sub _metadata ($domain) {
    return undef unless ref($domain) && eval { $domain->can('contract') };
    my $contract = $domain->contract;
    my $metadata = ref($contract) eq 'HASH' && ref($contract->{extensions}) eq 'HASH'
        ? $contract->{extensions}{i18n} : undef;
    return undef unless defined($metadata);
    die "Selecto i18n extension must be an object\n" unless ref($metadata) eq 'HASH';
    my $namespace = _text($metadata->{namespace});
    die "Selecto i18n namespace must be a lowercase dotted identifier\n"
        unless $namespace =~ /\A[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*\z/ && length($namespace) <= 80;
    my $terms = $metadata->{terms} // {};
    die "Selecto i18n terms must be an object\n" unless ref($terms) eq 'HASH';
    return {namespace => $namespace, terms => $terms};
}

sub _dictionary_key ($value) {
    my $key = _text($value);
    die "Selecto dictionary key must be a non-empty scalar no longer than 200 characters\n"
        unless length($key) && length($key) <= 200 && $key !~ /[\x00-\x1f\x7f]/;
    return $key;
}

sub _semantic ($value) {
    my $semantic = _text($value);
    die "Selecto i18n semantic key must be a lowercase dotted identifier\n"
        unless $semantic =~ /\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\z/;
    return $semantic;
}

sub _id ($value) {
    my $id = lc(_text($value));
    $id =~ s/[^a-z0-9_]+/_/g;
    $id =~ s/\A_+|_+\z//g;
    return $id;
}

sub _column_label ($column, $fallback) {
    return _text($column->{label}) if ref($column) eq 'HASH' && defined($column->{label});
    return $fallback;
}

sub _text ($value) {
    return '' unless defined($value) && !ref($value);
    return "$value";
}

1;
