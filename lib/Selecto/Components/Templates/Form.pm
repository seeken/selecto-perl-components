package Selecto::Components::Templates::Form;

use 5.034;
use strict;
use warnings;

use Selecto::Templates ();

# The owner scope must come from the authenticated host request. The callbacks
# must re-resolve the writable contract and load/write only records authorized
# for that scope; this service never treats browser input as record authority.
sub new {
    my ($class, %args) = @_;
    for my $name (qw(resolve_form load_record write_record)) {
        die "invalid_form_host: $name callback is required\n"
            unless ref($args{$name}) eq 'CODE';
    }
    die "invalid_form_host: instance store is required\n"
        unless $args{store} && $args{store}->can('create')
        && $args{store}->can('load') && $args{store}->can('compare_and_set');
    die "invalid_form_host: lookup_receipt must be a callback\n"
        if defined($args{lookup_receipt}) && ref($args{lookup_receipt}) ne 'CODE';
    return bless {
        store => $args{store},
        resolve_form => $args{resolve_form},
        load_record => $args{load_record},
        write_record => $args{write_record},
        lookup_receipt => $args{lookup_receipt},
        clock => $args{clock} // sub { time },
        ttl_seconds => $args{ttl_seconds} // 1800,
        row_id_generator => $args{row_id_generator} // \&_row_id,
    }, $class;
}

sub open {
    my ($self, %args) = @_;
    my ($owner, $record_id) = @args{qw(owner_scope record_id)};
    my $form = $self->{resolve_form}->($owner, $record_id);
    return {status => 'not_found'} unless $form;
    my $record = $self->{load_record}->($owner, $record_id);
    return {status => 'not_found'} unless $record;
    my $instance = $self->{store}->new_instance_id;
    my $snapshot = Selecto::Templates->open_form(
        $form, $record,
        instance_id => $instance, record_id => $record_id,
        contract_fingerprint => $form->{contract_fingerprint},
    );
    $snapshot->{release_id} = _release($form);
    $snapshot->{status} = 'ready';
    $self->{store}->create(
        owner_scope => $owner, instance_id => $instance,
        release => $snapshot->{release_id}, initial_snapshot => $snapshot,
        expires_at => $self->{clock}->() + $self->{ttl_seconds},
    );
    return {status => 'ok', form => $form, snapshot => $snapshot};
}

sub load {
    my ($self, %args) = @_;
    my $loaded = $self->{store}->load(
        owner_scope => $args{owner_scope}, instance_id => $args{instance_id},
    );
    return $loaded unless $loaded->{status} eq 'ok';
    my $snapshot = $loaded->{snapshot};
    my $form = $self->{resolve_form}->($args{owner_scope}, $snapshot->{record_id});
    return {status => 'contract_changed'}
        unless $form && _release($form) eq $loaded->{release}
        && ($snapshot->{form_id} // '') eq ($form->{id} // '');
    return {status => 'invalid_snapshot'}
        unless ($snapshot->{revision} // -1) == $loaded->{revision};
    return {%$loaded, form => $form};
}

sub change {
    my ($self, %args) = @_;
    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';
    my $snapshot = $loaded->{snapshot};
    return {status => 'conflict', revision => $loaded->{revision}}
        unless defined($args{revision}) && !ref($args{revision})
        && "$args{revision}" =~ /\A[0-9]+\z/
        && $args{revision} == $loaded->{revision}
        && ($snapshot->{status} // '') eq 'ready';
    my $form = $loaded->{form};
    my ($next, $error);
    eval {
        if (($args{operation} // '') eq 'edit') {
            $next = Selecto::Templates->edit_form(
                $form, $snapshot, $args{path}, $args{field},
                $args{value}, $args{revision},
            );
        }
        elsif (($args{operation} // '') eq 'add') {
            $next = Selecto::Templates->add_form(
                $form, $snapshot, $args{path}, $args{relationship},
                $self->{row_id_generator}->(), $args{fields}, $args{revision},
            );
        }
        elsif (($args{operation} // '') eq 'remove') {
            $next = Selecto::Templates->remove_form(
                $form, $snapshot, $args{path}, $args{revision},
            );
        }
        elsif (($args{operation} // '') eq 'discard') {
            $next = Selecto::Templates->discard_form($form, $snapshot, $args{revision});
        }
        else { die "invalid_form_operation: rejected\n" }
        1;
    } or $error = $@;
    return {status => 'invalid_change', code => _error_code($error)} if $error;
    my $saved = $self->{store}->compare_and_set(
        owner_scope => $args{owner_scope}, instance_id => $args{instance_id},
        revision => $loaded->{revision}, next_snapshot => $next,
    );
    return $saved unless $saved->{status} eq 'ok';
    return {status => 'ok', form => $form, snapshot => $next};
}

sub save {
    my ($self, %args) = @_;
    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';
    my $snapshot = $loaded->{snapshot};
    if ($self->{lookup_receipt}) {
        return {status => 'saved', snapshot => $snapshot,
            result => $snapshot->{operation_result}}
            if ($snapshot->{status} // '') eq 'saved';
        return $self->_recover_saving($args{owner_scope}, $args{instance_id}, $loaded)
            if ($snapshot->{status} // '') eq 'saving';
    }
    return {status => 'conflict', revision => $loaded->{revision}}
        unless defined($args{revision}) && !ref($args{revision})
        && "$args{revision}" =~ /\A[0-9]+\z/
        && $args{revision} == $loaded->{revision}
        && ($snapshot->{status} // '') eq 'ready';
    return {status => 'unchanged', form => $loaded->{form}, snapshot => $snapshot}
        unless $snapshot->{dirty};

    my $operation_key = join ':', $snapshot->{instance_id}, $loaded->{revision};
    my $saving = {%$snapshot, status => 'saving',
        revision => $loaded->{revision} + 1,
        operation_key => $operation_key};
    my $reserved = $self->{store}->compare_and_set(
        owner_scope => $args{owner_scope}, instance_id => $args{instance_id},
        revision => $loaded->{revision}, next_snapshot => $saving,
    );
    return $reserved unless $reserved->{status} eq 'ok';

    my ($result, $error);
    eval {
        $result = $self->{write_record}->(
            $args{owner_scope}, $snapshot->{record_id},
            $loaded->{form}, $snapshot->{baseline}, $snapshot->{draft},
            $operation_key,
        );
        die "write_rejected: host rejected the draft\n"
            unless ref($result) eq 'HASH' && ($result->{status} // '') eq 'ok';
        1;
    } or $error = $@;
    if ($error && $self->{lookup_receipt}) {
        my ($receipt, $lookup_error) = $self->_lookup_receipt(
            $args{owner_scope}, $operation_key,
        );
        return {status => 'uncertain', snapshot => $saving}
            if $lookup_error;
        if ($receipt) {
            $result = $receipt;
            $error = undef;
        } elsif (_error_code($error) eq 'operation_outcome_unknown'
            || _error_code($error) eq 'form_host_error') {
            return {status => 'uncertain', snapshot => $saving};
        }
    }
    return $self->_finish_save($args{owner_scope}, $args{instance_id},
        $reserved->{revision}, $saving, $result, $error);
}

sub recover {
    my ($self, %args) = @_;
    my $loaded = $self->load(%args);
    return $loaded unless $loaded->{status} eq 'ok';
    my $snapshot = $loaded->{snapshot};
    return {status => 'saved', snapshot => $snapshot,
        result => $snapshot->{operation_result}}
        if ($snapshot->{status} // '') eq 'saved';
    return $self->_recover_saving($args{owner_scope}, $args{instance_id}, $loaded)
        if ($snapshot->{status} // '') eq 'saving';
    return {status => 'ok', form => $loaded->{form}, snapshot => $snapshot};
}

sub _recover_saving {
    my ($self, $owner, $instance, $loaded) = @_;
    my $snapshot = $loaded->{snapshot};
    return {status => 'uncertain', snapshot => $snapshot}
        unless $self->{lookup_receipt} && defined($snapshot->{operation_key});
    my ($receipt, $lookup_error) = $self->_lookup_receipt(
        $owner, $snapshot->{operation_key},
    );
    return {status => 'uncertain', snapshot => $snapshot}
        if $lookup_error || !$receipt;
    return $self->_finish_save($owner, $instance, $loaded->{revision},
        $snapshot, $receipt, undef);
}

sub _lookup_receipt {
    my ($self, $owner, $key) = @_;
    my $receipt = eval { $self->{lookup_receipt}->($owner, $key) };
    return (undef, 1) if $@;
    return (undef, 0) unless defined($receipt);
    return (undef, 1) unless ref($receipt) eq 'HASH'
        && ($receipt->{status} // '') eq 'ok';
    return ($receipt, 0);
}

sub _finish_save {
    my ($self, $owner, $instance, $revision, $saving, $result, $error) = @_;
    my $finished = {%$saving,
        status => $error ? 'ready' : 'saved',
        revision => $revision + 1,
    };
    if ($error) {
        delete $finished->{operation_key};
    } else {
        $finished->{operation_result} = $result;
    }
    my $stored = $self->{store}->compare_and_set(
        owner_scope => $owner, instance_id => $instance,
        revision => $revision, next_snapshot => $finished,
    );
    return $stored unless $stored->{status} eq 'ok';
    return {status => 'write_rejected', code => _error_code($error), snapshot => $finished}
        if $error;
    return {status => 'saved', snapshot => $finished, result => $result};
}

sub _release {
    my ($form) = @_;
    return join ':', 'form', $form->{id} // '', $form->{contract_fingerprint} // '';
}

sub _error_code {
    my ($error) = @_;
    return $1 if ($error // '') =~ /\A([a-z][a-z0-9_]*):/;
    return 'form_host_error';
}

sub _row_id {
    CORE::open my $random, '<:raw', '/dev/urandom' or die "row_id_unavailable\n";
    read($random, my $bytes, 16) == 16 or die "row_id_unavailable\n";
    return 'draft:' . unpack('H*', $bytes);
}

1;
