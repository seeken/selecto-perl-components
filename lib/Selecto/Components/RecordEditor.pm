package Selecto::Components::RecordEditor;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed looks_like_number);
use Selecto::API::EngineHandler ();

sub find ($class, $domain, $id) {
    return undef unless defined($id) && !ref($id)
        && "$id" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    my $editors = $domain->editors;
    return undef unless ref($editors) eq 'HASH' && ref($editors->{$id}) eq 'HASH';
    return {id => "$id", %{$editors->{$id}}};
}

sub load ($class, $engine, $editor, $target) {
    return undef unless defined($target) && !ref($target) && "$target" ne '';
    my $primary_key = $engine->domain->primary_key;
    my @fields = ($primary_key, map { $_->{field} } @{$editor->{fields} // []});
    my %seen;
    @fields = grep { !$seen{$_}++ } @fields;
    my $result = Selecto::API::EngineHandler->new(
        max_limit => 2, default_limit => 2,
    )->query($engine, {
        select => \@fields,
        filters => [{field => $primary_key, op => 'eq', value => "$target"}],
        limit => 2,
        row_format => 'objects',
    });
    return undef unless @{$result->{rows}} == 1;
    my $record = {%{$result->{rows}[0]}};
    my %collections;
    for my $collection (@{$editor->{collections} // []}) {
        my @select = map { $_->{field} } @{$collection->{fields}};
        my $collection_result = Selecto::API::EngineHandler->new(
            max_fields => scalar(@select) + 5,
            max_limit => 100, default_limit => $collection->{limit},
        )->query($engine, {
            select => \@select,
            filters => [{field => $primary_key, op => 'eq', value => "$target"}],
            order_by => $collection->{order_by},
            limit => $collection->{limit},
            row_format => 'objects',
        });
        my @rows = grep {
            my $row = $_;
            grep { defined($row->{$_}) && "$row->{$_}" ne '' } @select;
        } @{$collection_result->{rows}};
        $collections{$collection->{id}} = \@rows;
    }
    $record->{__selecto_editor_collections} = \%collections;
    return $record;
}

sub normalize ($class, $domain, $editor, $params, $original = undef) {
    my (%values, %errors);
    for my $spec (@{$editor->{fields} // []}) {
        next if $spec->{readonly};
        my $field = $spec->{field};
        my $definition = $domain->resolve($field);
        my $type = lc($definition->{type} // 'string');
        my $options = $spec->{options}
            // $domain->field_metadata($field)->{options};
        my $control = $spec->{control}
            // (ref($options) eq 'ARRAY' && @$options
                ? 'select' : _control_for_type($type));
        my $present = exists $params->{$field};
        my $value = $present ? $params->{$field} : undef;
        $value = $value->[-1] if ref($value) eq 'ARRAY';
        if ($control eq 'checkbox') {
            $value = $present && defined($value) && "$value" ne '0' ? 1 : 0;
        } elsif (defined($value) && !ref($value)) {
            $value = "$value";
            $value =~ s/\A\s+|\s+\z//g unless $control eq 'textarea';
        }
        my $submitted_value = $value;
        $value = $domain->normalize_field_value($field, $value);

        if (!defined($value) || (!ref($value) && $value =~ /\A\s*\z/)) {
            if ($spec->{required}) {
                $errors{$field} = 'This field is required.';
                next;
            }
            $values{$field} = undef if $spec->{nullable};
            $values{$field} = '' unless $spec->{nullable};
            next;
        }
        if (ref($value)) {
            $errors{$field} = 'Enter a single value.';
            next;
        }
        if ($control eq 'select' && ref($options) eq 'ARRAY') {
            my %allowed = map { ("" . $_->{value}) => 1 } @$options;
            my $unchanged_legacy = ref($original) eq 'HASH'
                && exists($original->{$field})
                && defined($original->{$field})
                && defined($submitted_value)
                && "$submitted_value" eq "$original->{$field}";
            $value = $original->{$field}
                if !$allowed{"$value"} && $unchanged_legacy;
            unless ($allowed{"$value"} || $unchanged_legacy) {
                $errors{$field} = 'Choose an available value.';
                next;
            }
        }
        if ($type =~ /\A(?:integer|bigint|smallint)\z/ && "$value" !~ /\A-?\d+\z/) {
            $errors{$field} = 'Enter a whole number.';
            next;
        }
        if ($type =~ /\A(?:decimal|number|float|double|numeric)\z/
            && !looks_like_number($value)) {
            $errors{$field} = 'Enter a number.';
            next;
        }
        if (($type eq 'date' || $control eq 'date')
            && "$value" !~ /\A\d{4}-\d{2}-\d{2}\z/) {
            $errors{$field} = 'Enter a date as YYYY-MM-DD.';
            next;
        }
        if ($control eq 'datetime-local'
            && "$value" !~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\z/) {
            $errors{$field} = 'Enter a date and time.';
            next;
        }
        # DBI accepts validated numeric strings directly. Keep the submitted
        # representation intact so exact decimals and large integers are not
        # rounded through Perl's native numeric types before the write.
        $values{$field} = $value;
    }
    return {valid => keys(%errors) ? 0 : 1, values => \%values, errors => \%errors};
}

sub changed ($class, $editor, $original, $values) {
    my %changed;
    for my $spec (@{$editor->{fields} // []}) {
        next if $spec->{readonly};
        my $field = $spec->{field};
        my $before = $original->{$field};
        my $after = $values->{$field};
        my $different = defined($before) != defined($after)
            || defined($before) && "$before" ne "$after";
        $changed{$field} = $after if $different;
    }
    return \%changed;
}

sub save ($class, $engine, $target, $original, $assignments) {
    return {operation => 'update', affected_rows => 0} unless keys %$assignments;
    my $primary_key = $engine->domain->primary_key;
    my @filters = ({field => $primary_key, op => 'eq', value => "$target"});
    for my $field (sort keys %$original) {
        push @filters, defined($original->{$field})
            ? {field => $field, op => 'eq', value => $original->{$field}}
            : {field => $field, op => 'is_null'};
    }
    return Selecto::API::EngineHandler->new(
        max_filters => scalar(keys(%$original)) + 1,
    )->write($engine, {
        operation => 'update',
        assignments => $assignments,
        filters => \@filters,
        expected_count => 1,
    });
}

sub _control_for_type ($type) {
    return 'checkbox' if $type eq 'boolean';
    return 'number' if $type =~ /\A(?:integer|bigint|smallint|decimal|number|float|double|numeric)\z/;
    return 'date' if $type eq 'date';
    return 'datetime-local' if $type =~ /datetime/;
    return 'text';
}

1;
