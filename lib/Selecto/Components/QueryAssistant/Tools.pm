package Selecto::Components::QueryAssistant::Tools;

use 5.034;
use strict;
use warnings;

sub definitions {
    return [
        {
            name => 'get_query_context', title => 'Read Selecto query context',
            description => 'Read the authorized fields, measures, graph capabilities, and current editable query draft. Does not run the query.',
            inputSchema => _object({draft_id => _string()}, [qw(draft_id)]),
            annotations => {readOnlyHint => 1, consequentialHint => 0},
        },
        {
            name => 'search_choices', title => 'Search Selecto field choices',
            description => 'Search a governed choice source for one published field. This may perform a bounded lookup but does not run the report.',
            inputSchema => _object({draft_id => _string(), field => _string(), text => _string(), limit => {type => 'integer', minimum => 1, maximum => 50}}, [qw(draft_id field text)]),
            annotations => {readOnlyHint => 1, consequentialHint => 0},
        },
        {
            name => 'validate_query_target', title => 'Validate a Selecto query target',
            description => 'Validate and compile a complete Detail, Aggregate, or Graph target without executing it or changing the form.',
            inputSchema => _object({draft_id => _string(), base_revision => {type => 'integer', minimum => 0}, context_version => _string(), target => {type => 'object'}}, [qw(draft_id base_revision context_version target)]),
            annotations => {readOnlyHint => 1, consequentialHint => 0},
        },
        {
            name => 'apply_query_draft', title => 'Edit the Selecto query form',
            description => 'Atomically replace the editable query form with a validated complete target. Does not run the query.',
            inputSchema => _object({draft_id => _string(), base_revision => {type => 'integer', minimum => 0}, context_version => _string(), request_id => _string(), target => {type => 'object'}}, [qw(draft_id base_revision context_version request_id target)]),
            annotations => {readOnlyHint => 0, consequentialHint => 0},
        },
        {
            name => 'undo_query_draft', title => 'Undo the last Selecto assistant edit',
            description => 'Restore the one saved pre-assistant query draft when it is still current. Does not run the query.',
            inputSchema => _object({draft_id => _string(), base_revision => {type => 'integer', minimum => 0}, undo_token => _string()}, [qw(draft_id base_revision undo_token)]),
            annotations => {readOnlyHint => 0, consequentialHint => 0},
        },
    ];
}

sub definition {
    my ($class, $name) = @_;
    my ($definition) = grep { $_->{name} eq ($name // '') } @{$class->definitions};
    return $definition;
}

sub _string { return {type => 'string', minLength => 1}; }
sub _object {
    my ($properties, $required) = @_;
    return {type => 'object', properties => $properties, required => $required, additionalProperties => \0};
}

1;
