use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";
use Test::More;
use Selecto::Components::Templates::PublicInputs ();

my $manifest = {inputs => [
    {name => 'status', type => 'string?'},
    {name => 'customer_id', type => 'integer?'},
    {name => 'include_closed', type => 'boolean'},
    {name => 'customer', type => 'source<customers?>'},
]};

is_deeply(
    Selecto::Components::Templates::PublicInputs->configure(
        $manifest, [qw(include_closed status customer_id)], 'orders',
    ),
    [
        {name => 'status', type => 'string?'},
        {name => 'customer_id', type => 'integer?'},
        {name => 'include_closed', type => 'boolean'},
    ],
    'public inputs retain deterministic manifest order',
);
is_deeply(
    Selecto::Components::Templates::PublicInputs->configure(
        $manifest, undef, 'orders',
    ),
    [],
    'public URL inputs are disabled unless the host allowlists them',
);

for my $case (
    ['unknown input', ['missing'], qr/public input missing is not declared/],
    ['source input', ['customer'], qr/public input customer must be string, integer, or boolean/],
    ['duplicate input', [qw(status status)], qr/public input status is configured more than once/],
    ['invalid collection', {}, qr/public_inputs must be an array/],
) {
    my ($label, $public_inputs, $error) = @$case;
    my $caught = '';
    eval {
        Selecto::Components::Templates::PublicInputs->configure(
            $manifest, $public_inputs, 'orders',
        );
        1;
    } or $caught = $@;
    like $caught, $error, "$label fails plugin registration";
}

done_testing;
