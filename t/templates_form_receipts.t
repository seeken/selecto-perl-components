use 5.034;
use strict;
use warnings;

use FindBin ();
use JSON::PP ();
use Test::More;
use Selecto::Components::Templates::Form ();
use Selecto::Components::Templates::InstanceStore::Memory ();

{
    package ReceiptInterruptedStore;
    use parent 'Selecto::Components::Templates::InstanceStore::Memory';

    sub compare_and_set {
        my ($self, %args) = @_;
        if (($args{next_snapshot}{status} // '') eq 'saved'
            && delete($self->{interrupt_after_write})) {
            die "simulated worker exit after business commit\n";
        }
        return $self->SUPER::compare_and_set(%args);
    }
}

my $json = JSON::PP->new->utf8(1);
my $fixture_path =
    "$FindBin::Bin/../../selecto-protocol/spec/fixtures/templates/";
sub fixture {
    my ($name) = @_;
    open my $handle, '<:raw', $fixture_path . $name
        or die "missing protocol fixture: $!";
    my $source = do { local $/; <$handle> };
    close $handle;
    return $json->decode($source);
}
my $form = fixture('order-editor.compile.json')->{forms}[0];
my $record = fixture('order-editor.draft.json')->{record};
my $sequence = 0;
my %receipts;
my $writes = 0;
my $unknown_outcome = 0;
my $store = ReceiptInterruptedStore->new(
    id_generator => sub { 'receipt-form-' . ++$sequence },
);
my $service = Selecto::Components::Templates::Form->new(
    store => $store,
    resolve_form => sub { return $form },
    load_record => sub { return $record },
    write_record => sub {
        my ($owner, $id, $declaration, $baseline, $draft, $key) = @_;
        ++$writes;
        die "operation_outcome_unknown: connection ended at commit\n"
            if $unknown_outcome;
        $receipts{$owner->{tenant}}{$key} = {
            status => 'ok', record_id => "$id",
        };
        return $receipts{$owner->{tenant}}{$key};
    },
    lookup_receipt => sub {
        my ($owner, $key) = @_;
        return $receipts{$owner->{tenant}}{$key};
    },
);
my $owner = {tenant => 'alpha', actor => 'editor'};
my $foreign = {tenant => 'beta', actor => 'editor'};
my $opened = $service->open(owner_scope => $owner, record_id => 42);
is $opened->{status}, 'ok', 'owner opens a receipt-aware draft';
my $instance = $opened->{snapshot}{instance_id};
my $edited = $service->change(
    owner_scope => $owner, instance_id => $instance, revision => 0,
    operation => 'edit', path => [], field => 'status', value => 'approved',
);
is $edited->{status}, 'ok', 'draft edit obtains a stable revision';
$store->{interrupt_after_write} = 1;
my $interruption;
eval {
    $service->save(owner_scope => $owner, instance_id => $instance, revision => 1);
    1;
} or $interruption = $@;
like $interruption, qr/simulated worker exit after business commit/,
    'test interrupts between durable write and instance-store completion';
is $writes, 1, 'business write ran once before the response was lost';
my $in_flight = $service->load(owner_scope => $owner, instance_id => $instance);
is $in_flight->{snapshot}{status}, 'saving',
    'instance state retains the pending operation key';
is $in_flight->{snapshot}{operation_key}, "$instance:1",
    'operation key is derived from server-owned instance and revision';
is $service->recover(
    owner_scope => $foreign, instance_id => $instance,
)->{status}, 'not_found', 'another owner cannot inspect the pending receipt';
my $recovered = $service->recover(
    owner_scope => $owner, instance_id => $instance,
);
is $recovered->{status}, 'saved',
    'receipt reconciliation finishes the interrupted save';
is $recovered->{result}{record_id}, '42',
    'reconciliation returns the original business result';
is $recovered->{snapshot}{revision}, 3,
    'reconciliation advances the instance-store revision once';
is $service->save(
    owner_scope => $owner, instance_id => $instance, revision => 1,
)->{status}, 'saved', 'duplicate submission returns the prior outcome';
is $writes, 1, 'duplicate submission cannot repeat the business write';

$unknown_outcome = 1;
my $unknown = $service->open(owner_scope => $owner, record_id => 42);
my $unknown_instance = $unknown->{snapshot}{instance_id};
$service->change(
    owner_scope => $owner, instance_id => $unknown_instance, revision => 0,
    operation => 'edit', path => [], field => 'status', value => 'pending',
);
my $uncertain = $service->save(
    owner_scope => $owner, instance_id => $unknown_instance, revision => 1,
);
is $uncertain->{status}, 'uncertain',
    'an unknown commit without a receipt remains explicit uncertainty';
is $service->recover(
    owner_scope => $owner, instance_id => $unknown_instance,
)->{status}, 'uncertain', 'missing receipt never implies an automatic retry';
is $service->load(
    owner_scope => $owner, instance_id => $unknown_instance,
)->{snapshot}{status}, 'saving',
    'uncertain operation remains protected from further draft changes';
is $writes, 2, 'receipt lookup does not invoke the business writer again';

done_testing;
