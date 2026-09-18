package Selecto::Components::QueryAssistant::Draft;

use 5.034;
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Storable qw(dclone);
use Selecto::Components::QueryAssistant::Diff ();
use Selecto::Components::QueryAssistant::Target ();
use Selecto::Components::QueryAssistant::Validator ();

sub create {
    my ($class, %args) = @_;
    my $state = $args{state};
    return $args{store}->create({
        owner => $args{owner},
        explorer_id => $args{config}->id,
        context_version => $args{context_version},
        target => Selecto::Components::QueryAssistant::Target->from_state($state),
        input => _pairs_to_input($state->query_pairs),
        undo => undef,
        receipts => {},
    });
}

sub apply {
    my ($class, %args) = @_;
    my $record = $args{store}->get($args{id});
    return {ok => 0, code => 'draft_expired'} unless $record;
    return {ok => 0, code => 'forbidden'}
        unless defined($args{owner}) && $record->{owner} eq $args{owner}
            && $record->{explorer_id} eq $args{config}->id;
    return {ok => 0, code => 'context_changed'}
        unless $record->{context_version} eq $args{context_version};
    my $request_id = $args{request_id} // '';
    if (length($request_id) && ref($record->{receipts}{$request_id}) eq 'HASH') {
        return dclone($record->{receipts}{$request_id});
    }
    return {ok => 0, code => 'revision_conflict', current_revision => $record->{revision}}
        unless defined($args{base_revision}) && $args{base_revision} == $record->{revision};
    my $validation = Selecto::Components::QueryAssistant::Validator->validate(
        config => $args{config}, domain => $args{domain}, engine => $args{engine},
        target => $args{target}, preserve_input => $record->{input},
    );
    return $validation unless $validation->{ok};
    my $normalized = $validation->{normalized_target};
    my $changes = Selecto::Components::QueryAssistant::Diff->between($record->{target}, $normalized);
    return {ok => 1, no_op => 1, revision => $record->{revision}, target => $record->{target}, changes => []}
        unless @$changes;
    my $replacement = dclone($record);
    $replacement->{undo} = {
        token => sha256_hex(join(':', rand(), $$, $record->{revision}, $args{id})),
        target => dclone($record->{target}), input => dclone($record->{input}),
        from_revision => $record->{revision},
    };
    $replacement->{target} = dclone($normalized);
    $replacement->{input} = dclone($validation->{input});
    my $result = {
        ok => 1, revision => $record->{revision} + 1, target => dclone($normalized),
        input => dclone($validation->{input}), changes => $changes,
        undo_token => $replacement->{undo}{token},
    };
    $replacement->{receipts}{$request_id} = dclone($result) if length $request_id;
    if (keys(%{$replacement->{receipts}}) > 32) {
        my @discard = sort keys %{$replacement->{receipts}};
        delete @{$replacement->{receipts}}{@discard[0 .. $#discard - 32]};
    }
    my $cas = $args{store}->compare_and_swap($args{id}, $record->{revision}, $replacement);
    return $cas unless $cas->{ok};
    return $result;
}

sub undo {
    my ($class, %args) = @_;
    my $record = $args{store}->get($args{id});
    return {ok => 0, code => 'draft_expired'} unless $record;
    return {ok => 0, code => 'forbidden'} unless $record->{owner} eq ($args{owner} // '');
    return {ok => 0, code => 'revision_conflict', current_revision => $record->{revision}}
        unless defined($args{base_revision}) && $args{base_revision} == $record->{revision};
    my $undo = $record->{undo};
    return {ok => 0, code => 'undo_conflict'}
        unless ref($undo) eq 'HASH' && $undo->{token} eq ($args{undo_token} // '');
    my $replacement = dclone($record);
    $replacement->{target} = dclone($undo->{target});
    $replacement->{input} = dclone($undo->{input});
    $replacement->{undo} = undef;
    my $cas = $args{store}->compare_and_swap($args{id}, $record->{revision}, $replacement);
    return $cas unless $cas->{ok};
    return {
        ok => 1, revision => $record->{revision} + 1,
        target => dclone($replacement->{target}), input => dclone($replacement->{input}),
        changes => Selecto::Components::QueryAssistant::Diff->between(
            $record->{target}, $replacement->{target},
        ),
    };
}

sub sync {
    my ($class, %args) = @_;
    my $record = $args{store}->get($args{id});
    return {ok => 0, code => 'draft_expired'} unless $record;
    return {ok => 0, code => 'forbidden'} unless $record->{owner} eq ($args{owner} // '');
    return {ok => 0, code => 'revision_conflict', current_revision => $record->{revision}}
        unless defined($args{base_revision}) && $args{base_revision} == $record->{revision};
    my $target = Selecto::Components::QueryAssistant::Target->from_state($args{state});
    my $changes = Selecto::Components::QueryAssistant::Diff->between($record->{target}, $target);
    return {ok => 1, no_op => 1, revision => $record->{revision}, target => $target}
        unless @$changes;
    my $replacement = dclone($record);
    $replacement->{target} = $target;
    $replacement->{input} = dclone($args{input});
    $replacement->{undo} = undef;
    $replacement->{receipts} = {};
    my $cas = $args{store}->compare_and_swap($args{id}, $record->{revision}, $replacement);
    return $cas unless $cas->{ok};
    return {ok => 1, revision => $record->{revision} + 1, target => $target, changes => $changes};
}

sub _pairs_to_input {
    my ($pairs) = @_;
    my %input;
    for (my $index = 0; $index < @$pairs; $index += 2) {
        my ($name, $value) = @$pairs[$index, $index + 1];
        if (exists $input{$name}) {
            $input{$name} = [$input{$name}] unless ref($input{$name}) eq 'ARRAY';
            push @{$input{$name}}, $value;
        } else {
            $input{$name} = $value;
        }
    }
    return \%input;
}

1;
