package Selecto::Components::I18N;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(refaddr);
use Selecto::Components::Util qw(humanize);

sub localize ($class, $localizer, $domain, $semantic, $default, $context = undef, $cache = undef) {
    $default = _text($default);
    return $default unless ref($localizer) eq 'CODE' && length($default);
    my $spec = $class->term($domain, $semantic, $default, $cache);
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

sub term ($class, $domain, $semantic, $default = undef, $cache = undef) {
    return undef unless ref($domain) && eval { $domain->can('contract') };
    my $metadata;
    if (ref($cache) eq 'HASH') {
        my $key = refaddr($domain) // '';
        my $fingerprint = $domain->can('fingerprint') ? $domain->fingerprint : '';
        my $entry = $cache->{$key};
        unless ($entry && $entry->{fingerprint} eq $fingerprint) {
            # The caller owns this request-local cache. Retain the domain to
            # prevent address reuse; cache only metadata, never translations.
            $entry = $cache->{$key} = {
                domain => $domain, fingerprint => $fingerprint,
                metadata => _metadata($domain),
            };
        }
        $metadata = $entry->{metadata};
    } else {
        $metadata = _metadata($domain);
    }
    return undef unless $metadata;
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
    my $contract = $domain->contract // {};
    my $source = ref($contract->{source}) eq 'HASH' ? $contract->{source} : {};
    for my $name (sort keys %{$domain->associations}) {
        my $association = $domain->associations->{$name};
        next unless $association->can('join_mode') && $association->join_mode eq 'star_dimension';
        my $label = $association->display_name;
        $label = humanize($name) unless defined($label) && length("$label");
        my $key = $association->dimension_key;
        my $column = ref($source->{columns}) eq 'HASH'
            ? $source->{columns}{$key} : undef;
        $by_key{$key} = _column_label($column, "$label ID");
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

__END__

=head1 NAME

Selecto::Components::I18N - Request-time localization of domain presentation text

=head1 SYNOPSIS

    # Domain contract:
    extensions => {
        i18n => {
            namespace => 'selecto.products',
            terms => {
                'domain.title' => {default => 'Product Explorer'},
                'measures.product_count.label' => {default => 'Product count'},
            },
        },
    },

    # Explorer configuration:
    localizer => sub ($key, $default, $context) {
        return MyApp::Dictionary->translate($key, $default, $context->{controller});
    },

    # Export every term for a translation workflow:
    my $terms = Selecto::Components::I18N->terms($domain, {title => 'Products'});
    # [{namespace, semantic, key, default}, ...]

=head1 DESCRIPTION

A canonical domain can opt into localized presentation without changing its
field paths, query semantics or saved-query URLs. The domain fingerprint
ignores language. The domain declares a stable C<extensions.i18n.namespace>.
Each piece of presentation text then has a semantic path, for example
C<fields.unit_price.label>, C<query_library.segments.low_stock.label>,
C<actions.add_note.inputs.comment.label> or C<domain.title>. Its dictionary
key is C<< <namespace>.<semantic> >>, unless the domain's C<terms> map the
path to another key or give it a default.

The explorer's C<localizer> is called with that key, the fallback text, and a
context containing the C<controller>, C<namespace>, C<semantic>, C<domain>
and details about the term. If the callback dies, returns a reference or an
empty string, or returns text with control characters, the fallback is used.
Localization happens before labels are sorted. Metadata is cached per
request; translations are not.

=head1 METHODS

=head2 terms

    my $terms = Selecto::Components::I18N->terms($domain, {title => $title, measures => \@measures});

Every localizable term of the domain: its title, fields, associations,
query-library entries, actions (with their inputs, options, group inputs
and row details), curated measures and declared terms. Each term is
C<< {namespace, semantic, key, default} >>. Returns an empty list for a
domain without an C<i18n> namespace.
L<Selecto::Components::Config/localization_terms> fills in an explorer's
title and measures.

=head2 term

    my $term = Selecto::Components::I18N->term($domain, 'fields.unit_price.label', 'Unit price');

One term, or C<undef> when the domain has no namespace or there is no
default text.

=head2 localize

    my $text = Selecto::Components::I18N->localize($localizer, $domain, $semantic, $default, \%context);

Runs C<$localizer> for one term with the fallbacks described above.

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::Components::Config>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
