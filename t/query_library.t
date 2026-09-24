use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelectoComponents;
use Selecto::Components::Config;
use Selecto::Components::Explorer;
use Selecto::Components::QueryLibrary;
use Selecto::Components::Renderer::Builder;
use Selecto::Components::State;
use Selecto::Domain;

my $domain = TestSelectoComponents::domain();

my $views = Selecto::Components::QueryLibrary->entries($domain, 'views');
is_deeply $views, [{
    id => 'low_stock_products',
    label => 'Low stock products',
    description => 'Reusable inventory review preset.',
    capability => '',
}], 'named-view entries retain presentation metadata without inventing missing values';

my $segments = Selecto::Components::QueryLibrary->entries($domain, 'segments');
is_deeply [map { $_->{label} } @$segments], ['Low stock', 'Premium products'],
    'named segments sort alphabetically by their display labels';

my $active = Selecto::Components::QueryLibrary->active_segment_entries(
    $domain, 'low_stock_products', [qw(low_stock premium)],
);
is_deeply [map { $_->{id} } @$active], [qw(low_stock premium)],
    'view-governed and additional segments are summarized once in stable order';

my $parameters = Selecto::Components::QueryLibrary->parameter_entries(
    $domain, 'low_stock_products', ['premium'],
);
is_deeply [map { $_->{label} } @$parameters], ['Minimum Price', 'Stock threshold'],
    'typed parameters sort by their humanized or explicit label';
is_deeply [map { $_->{type} } @$parameters], [qw(decimal integer)],
    'component parameter entries retain portable types';
is(Selecto::Components::QueryLibrary->input_type('decimal'), 'number',
    'numeric portable types use numeric controls');
is(Selecto::Components::QueryLibrary->input_type('application/status'), 'text',
    'application-specific types fall back to text controls');

my $hidden_contract = $domain->contract;
$hidden_contract->{query_library}{segments}{low_stock}{picker_hidden} = 1;
my $hidden_domain = Selecto::Domain->parse($hidden_contract, strict => 1);
my $config = Selecto::Components::Config->new(
    %{TestSelectoComponents::config()}, id => 'hidden-segment-test',
);
my $default_state = Selecto::Components::State->from_input(
    $config, $hidden_domain, {q => 1, field => 'product_name'},
);
my $default_picker = Selecto::Components::Renderer::Builder
    ->_query_library_filter_controls($default_state, $hidden_domain, $config);
unlike $default_picker, qr/name="query_library_segment" value="low_stock"/,
    'picker-hidden compatibility segments are omitted when not selected';
like $default_picker, qr/name="query_library_segment" value="premium"/,
    'ordinary broad segments remain selectable';
my $selected_state = Selecto::Components::State->from_input(
    $config, $hidden_domain,
    {q => 1, field => 'product_name', query_library_segment => 'low_stock',
        query_library_param_name => 'threshold', query_library_param_value => 8},
);
my $selected_picker = Selecto::Components::Renderer::Builder
    ->_query_library_filter_controls($selected_state, $hidden_domain, $config);
like $selected_picker, qr/name="query_library_segment" value="low_stock"[^>]*checked/,
    'selected compatibility segments remain visible and removable';

my $group_contract = $domain->contract;
$group_contract->{query_library}{segments}{stock_yes} = {
    label => 'Stock: yes', filters => [['not_null', 'id']],
};
$group_contract->{query_library}{segments}{stock_no} = {
    label => 'Stock: no', filters => [['is_null', 'id']],
};
$group_contract->{query_library}{segment_picker_groups}{stock} = {
    label => 'In stock', description => 'Choose whether to restrict stock; Off includes both.', choices => [
        {segment => 'stock_yes', label => 'Yes'},
        {segment => 'stock_no', label => 'No'},
    ],
};
$group_contract->{query_library}{views}{stock_view} = {segments => ['stock_yes']};
my $group_domain = Selecto::Domain->parse($group_contract, strict => 1);
my $off_state = Selecto::Components::State->from_input(
    $config, $group_domain, {q => 1, field => 'product_name'},
);
my $off_picker = Selecto::Components::Renderer::Builder
    ->_query_library_filter_controls($off_state, $group_domain, $config);
like $off_picker, qr/name="query_library_segment_choice_stock" value=""[^>]*checked/,
    'segment group defaults to Off';
like $off_picker, qr/class="sc-query-library-choice-group" role="group"[^>]*>.*?<strong[^>]*>In stock<\/strong><small>Choose whether to restrict stock; Off includes both\.<\/small>/s,
    'group title and explanation use the same inline label structure as ordinary segments';
unlike $off_picker, qr/type="checkbox" name="query_library_segment" value="stock_yes"/,
    'group choices are radios rather than independent checkboxes';
my $yes_state = Selecto::Components::State->from_input(
    $config, $group_domain,
    {q => 1, field => 'product_name', query_library_segment_choice_stock => 'stock_yes'},
);
ok $yes_state->valid, 'a grouped choice is accepted by the normal form-state parser';
is_deeply $yes_state->query_library_segments, ['stock_yes'],
    'a grouped choice becomes the existing canonical segment ID';
my $yes_picker = Selecto::Components::Renderer::Builder
    ->_query_library_filter_controls($yes_state, $group_domain, $config);
like $yes_picker, qr/name="query_library_segment_choice_stock" value="stock_yes"[^>]*checked/,
    'the selected radio survives rerendering';
my $cleared_state = Selecto::Components::State->from_input(
    $config, $group_domain,
    {q => 1, field => 'product_name', query_library_segment => 'stock_yes',
        query_library_segment_choice_stock => ''},
);
is_deeply $cleared_state->query_library_segments, [],
    'Off clears a previously selected group segment';
my $conflict_state = Selecto::Components::State->from_input(
    $config, $group_domain,
    {q => 1, field => 'product_name', query_library_segment => [qw(stock_yes stock_no)]},
);
ok !$conflict_state->valid, 'conflicting legacy group choices are rejected rather than silently collapsed';
my $inherited_state = Selecto::Components::State->from_input(
    $config, $group_domain,
    {q => 1, field => 'product_name', query_library_view => 'stock_view'},
);
my $inherited_picker = Selecto::Components::Renderer::Builder
    ->_query_library_filter_controls($inherited_state, $group_domain, $config);
like $inherited_picker, qr/name="query_library_segment_choice_stock" value="stock_yes"[^>]*disabled[^>]*checked/,
    'a named-view group choice is shown and locked rather than misleadingly defaulting to Off';
my $view_conflict = Selecto::Components::State->from_input(
    $config, $group_domain,
    {q => 1, field => 'product_name', query_library_view => 'stock_view',
        query_library_segment_choice_stock => 'stock_no'},
);
ok !$view_conflict->valid, 'the form rejects a choice conflicting with a named view';

{
    package TestSegmentGroupController;
    sub new { bless {values => $_[1]}, $_[0] }
    sub req { $_[0] }
    sub params { $_[0] }
    sub names { [keys %{$_[0]{values}}] }
    sub every_param {
        my $value = $_[0]{values}{$_[1]};
        return ref($value) eq 'ARRAY' ? @$value : defined($value) ? ($value) : ();
    }
    sub param { $_[0]{values}{$_[1]} }
}
my $form_input = Selecto::Components::Explorer->new(config => $config)->input_from_controller(
    TestSegmentGroupController->new({q => 1, query_library_segment_choice_stock => 'stock_no'}),
);
is $form_input->{query_library_segment_choice_stock}, 'stock_no',
    'Explorer accepts a domain-declared radio group through its regular request boundary';
my $duplicate_choice = Selecto::Components::State->from_input(
    $config, $group_domain,
    {q => 1, field => 'product_name', query_library_segment_choice_stock => [qw(stock_yes stock_no)]},
);
ok !$duplicate_choice->valid, 'forged multiple values for one radio group are rejected';

done_testing;
