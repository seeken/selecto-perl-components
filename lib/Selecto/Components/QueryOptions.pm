package Selecto::Components::QueryOptions;

use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(to_json from_json);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Selecto::Error ();
use Selecto::Components::State ();

sub validate ($class, $config) {
    my $options = $config->query_options;
    die "query_options must be an array\n" unless ref($options) eq 'ARRAY' && @$options <= 32;
    my %reserved = map { ($_ => 1) } (@{Selecto::Components::State->parameter_names}, qw(
        format csrf_token return_to selected_id action_groups editor expand_saved expand_saved_type
        selecto_request_id selecto_patch selecto_refresh render_scope reuse_count
    ));
    my %seen;
    for my $option (@$options) {
        die "query option must be an object\n" unless ref($option) eq 'HASH';
        my $name = $option->{name} // '';
        die "query option name is invalid or reserved\n"
            if ref($name) || $name !~ /\A[a-z][a-z0-9_]{0,63}\z/
                || $reserved{$name} || $name =~ /\A(?:selecto_|query_library_|saved_query_|input_|f_)/ || $seen{$name}++;
        die "query option $name needs a label\n"
            unless defined($option->{label}) && !ref($option->{label}) && length($option->{label});
        my $choices = $option->{choices};
        die "query option $name needs choices\n" unless ref($choices) eq 'ARRAY' && @$choices >= 2 && @$choices <= 100;
        my %values;
        for my $choice (@$choices) {
            die "query option $name has an invalid choice\n"
                unless ref($choice) eq 'ARRAY' && @$choice == 2
                    && defined($choice->[0]) && !ref($choice->[0]) && length($choice->[0]) <= 200
                    && defined($choice->[1]) && !ref($choice->[1]) && length($choice->[1])
                    && !$values{$choice->[0]}++;
        }
        die "query option $name needs a declared default\n"
            unless defined($option->{default}) && !ref($option->{default}) && $values{$option->{default}};
        my $control = $option->{control} //= 'select';
        die "query option $name control must be select or a two-choice checkbox\n"
            unless !ref($control) && ($control eq 'select' || ($control eq 'checkbox' && @$choices == 2
                && $option->{default} eq $choices->[0][0]));
        die "query option $name offered must be a callback or boolean\n"
            if defined($option->{offered}) && ref($option->{offered}) && ref($option->{offered}) ne 'CODE';
        die "query option $name checkbox_label must be text\n"
            if defined($option->{checkbox_label}) && ref($option->{checkbox_label});
        if (my $link = $option->{help_link}) {
            die "query option $name help_link must be a local labelled link\n"
                unless ref($link) eq 'HASH' && defined($link->{href}) && !ref($link->{href})
                    && $link->{href} =~ m{\A/(?![/\\])[^\s"'<>\\]*\z}
                    && defined($link->{label}) && !ref($link->{label}) && length($link->{label});
        }
    }
    return;
}

sub offered ($class, $config, $option, $controller = undef) {
    return 1 unless exists $option->{offered};
    return ref($option->{offered}) eq 'CODE'
        ? !!$option->{offered}->($controller, $config) : !!$option->{offered};
}

# Independent of the engine domain. Keep defaults in the host context, but
# only non-defaults in State's serialized pairs.
sub parse ($class, $config, $input, $controller = undef) {
    my (%values, @errors, %offered);
    for my $option (@{$config->query_options}) {
        my $name = $option->{name};
        $offered{$name} = $class->offered($config, $option, $controller);
        my $value = exists($input->{$name}) ? $input->{$name} : $option->{default};
        if (ref($value) eq 'ARRAY') {
            # HTML checkboxes submit the hidden default before the checked value.
            $value = !@$value ? $option->{default} : @$value == 1 ? $value->[0]
                : @$value == 2 && $option->{control} eq 'checkbox'
                    && !ref($value->[0]) && $value->[0] eq $option->{default} ? $value->[1] : $value;
        }
        my ($choice) = grep { defined($value) && !ref($value) && $_->[0] eq $value } @{$option->{choices}};
        if (!$choice) {
            push @errors, "$option->{label} ($name) has an invalid value.";
            $value = $option->{default};
        } elsif (!$offered{$name} && $value ne $option->{default}) {
            push @errors, "$option->{label} $choice->[1] isn't available here.";
            $value = $option->{default};
        }
        $values{$name} = $value;
    }
    return {values => \%values, errors => \@errors, offered => \%offered};
}

sub context ($class, $config, $controller, $input = undef) {
    $input //= $controller->stash('selecto_components_query_input')
        if $controller && $controller->can('stash');
    if (!defined $input) {
        $input = eval { $controller->req->params->to_hash } if $controller;
        unless (ref($input) eq 'HASH') {
            $input = {};
            if ($controller && $controller->can('every_param')) {
                for my $name (@{Selecto::Components::State->parameter_names}, map { $_->{name} } @{$config->query_options}) {
                    my @values = $controller->every_param($name);
                    $input->{$name} = @values == 1 ? $values[0] : \@values if @values;
                }
            }
        }
    }
    die "query input must be an object\n" unless ref($input) eq 'HASH';
    my $parsed = $class->parse($config, $input, $controller);
    $controller->stash(selecto_components_query_options => $parsed->{values},
        selecto_components_query_input => $input) if $controller && $controller->can('stash');
    $config->{_query_options_context} = $parsed if $config->{_request_config};
    Selecto::Error->throw('invalid_query', join(' ', @{$parsed->{errors}}))
        if @{$parsed->{errors}};
    return {query_options => {%{$parsed->{values}}}, input => from_json(to_json($input))};
}

sub fingerprint ($class, $config) {
    my $values = ($config->{_query_options_context} // {})->{values} // {};
    return '' unless keys %$values;
    return sha256_hex(encode('UTF-8', to_json([map { [$_, $values->{$_}] } sort keys %$values])));
}

# Declaring query options opts the host into the two-argument factory API.
sub call_factory ($class, $factory, $controller, $context, $has_options) {
    return $has_options ? $factory->($controller, $context) : $factory->($controller);
}

1;

__END__

=head1 NAME

Selecto::Components::QueryOptions - Internal host option validation and factory context

=head1 DESCRIPTION

Internal support for L<Selecto::Components::Config/query_options>. Validates
closed host choices before engine construction, supplies a deep copy of raw input,
and passes factory context only when query options are declared. Hosts should use
the configuration API rather than this module directly.

=cut
