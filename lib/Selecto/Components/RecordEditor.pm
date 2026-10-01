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

__END__

=head1 NAME

Selecto::Components::RecordEditor - Load, validate and save a single-record edit dialog

=head1 SYNOPSIS

    # Domain contract:
    writes => {
        operations => {update => {enabled => 1}},
        fields => {product_name => {updatable => 1}, unit_price => {updatable => 1}},
    },
    editors => {
        product_profile => {
            label => 'Edit product',
            fields => [
                {field => 'id', readonly => 1},
                {field => 'product_name', required => 1},
                {field => 'unit_price', control => 'number', nullable => 1},
            ],
            actions => ['retire_product'],
        },
    },
    detail_actions => {
        edit_product => {
            name => 'Edit product', type => 'record_editor',
            required_fields => [qw(id product_name)],
            payload => {editor => 'product_profile', target_field => 'id',
                        title => 'Edit {{product_name}}', size => 'lg'},
        },
    },

    # Optional explorer hook, for example to audit or wrap in a transaction:
    record_editor_handler => sub ($c, $edit) {
        my $result = $edit->{default_save}->();
        MyApp::Audit->record($c, $edit->{target_id}, $edit->{assignments});
        return $result;
    },

=head1 DESCRIPTION

A C<record_editor> row action
(L<Selecto::Components::RowActions>) opens a lazily loaded dialog for one
row, served by C<GET/POST E<lt>explorer-pathE<gt>/records/:id/edit>.

The editor loads the record through the request's governed engine, so a row
outside the user's scope is not found. It signs the original editable values
into the form with the application's first secret; until the host sets
C<< $app->secrets >> (Mojolicious defaults to the guessable moniker) the
editor neither opens nor saves. The signature also binds the session (its
CSRF token), the engine's tenant, the domain fingerprint and the time the
form was opened, so a form cannot be replayed in another session or tenant
or after C<record_editor_max_age> (default one hour). When a save arrives,
it checks the CSRF token, the form's age, the signature and the submitted
field names, then validates each
value against its domain type and control. It updates only the changed
fields with C<< expected_count => 1 >>, using the original values as an
optimistic-concurrency predicate. A competing edit therefore returns HTTP 409
instead of being overwritten. After a save, the browser fetches the row again
through the explorer's query. A row that no longer matches stays visible as a
disabled placeholder. A row the user may no longer see is reduced to its
identity.

Editor C<actions> are shown as separate operations. They are never chained to
the profile save. C<record_editor_handler>, when configured, receives
C<< {engine, domain, editor, target_id, original, assignments, default_save} >>
and must return a hash. Returning C<< close_dialog => 1 >> closes the dialog
after success. By default the dialog stays open and reloads.

=head2 Editor field options

C<field> (required), C<label>, C<required>, C<nullable>, C<readonly>,
C<control> (C<text>, C<textarea>, C<number>, C<date>, C<datetime-local>,
C<checkbox> or C<select>; the default depends on the field type), C<options>,
C<section> and C<help>. Editors may also declare read-only C<collections>.

=head1 METHODS

These class methods are the building blocks the controller uses. They are
also available to hosts that edit through another surface.

=head2 find

    my $editor = Selecto::Components::RecordEditor->find($domain, $editor_id);

=head2 load

    my $record = Selecto::Components::RecordEditor->load($engine, $editor, $target_id);

Returns the record, or C<undef> unless exactly one row matches.

=head2 normalize

    my $r = Selecto::Components::RecordEditor->normalize($domain, $editor, \%params, $original);
    # {valid, values, errors => {field => message}}

=head2 changed

    my $assignments = Selecto::Components::RecordEditor->changed($editor, $original, $values);

=head2 save

    my $result = Selecto::Components::RecordEditor->save($engine, $target_id, $original, $assignments);

Performs the guarded update. A C<Selecto::Error> with code
C<cardinality_mismatch> means the record changed in the meantime.

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::Components::RowActions>, L<Selecto::Write>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
