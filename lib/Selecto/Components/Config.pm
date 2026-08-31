package Selecto::Components::Config;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Components::DateShortcut ();
use Selecto::Components::Util qw(humanize);

has [qw(id title path engine_factory)];
has views         => sub { return [qw(detail aggregate graph)] };
has default_view  => 'detail';
has default_fields => sub { return [] };
has default_group  => sub { return [] };
has measures       => sub { return [] };
has default_limit  => 25;
has max_limit      => 100;
has max_filters    => 20;
has max_orders     => 10;
has max_measures   => 10;
has max_action_rows => 1000;
has show_sql       => 0;
has action_handlers => sub { return {} };
has choice_sources  => sub { return {} };
has 'action_authorizer';
has 'saved_query_store';

my @DATE_FORMATS = (
    { id => 'day', label => 'Day' },
    { id => 'day_hour', label => 'Day + Hour' },
    { id => 'week', label => 'Week' },
    { id => 'month', label => 'Month' },
    { id => 'quarter', label => 'Quarter' },
    { id => 'year', label => 'Year' },
    { id => 'month_of_year', label => 'Month of Year' },
    { id => 'day_of_month', label => 'Day of Month' },
    { id => 'day_of_week', label => 'Day of Week' },
    { id => 'hour', label => 'Hour of Day' },
);

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    die "explorer id must be a lowercase identifier\n"
        unless defined($self->id) && $self->id =~ /\A[a-z][a-z0-9_-]*\z/;
    die "explorer title is required\n"
        unless defined($self->title) && !ref($self->title) && length($self->title);
    die "explorer path must start with /\n"
        unless defined($self->path) && $self->path =~ m{\A/[A-Za-z0-9/_-]*\z};
    die "explorer engine_factory must be a coderef\n" unless ref($self->engine_factory) eq 'CODE';
    die "default_limit must be a positive integer\n"
        unless $self->default_limit =~ /\A\d+\z/ && $self->default_limit > 0;
    die "max_limit must be at least default_limit\n"
        unless $self->max_limit =~ /\A\d+\z/ && $self->max_limit >= $self->default_limit;
    die "max_filters must be between 1 and 20\n"
        unless $self->max_filters =~ /\A\d+\z/ && $self->max_filters >= 1 && $self->max_filters <= 20;
    die "max_orders must be between 1 and 20\n"
        unless $self->max_orders =~ /\A\d+\z/ && $self->max_orders >= 1 && $self->max_orders <= 20;
    die "max_measures must be between 1 and 20\n"
        unless $self->max_measures =~ /\A\d+\z/ && $self->max_measures >= 1 && $self->max_measures <= 20;
    die "max_action_rows must be between 1 and 1000\n"
        unless $self->max_action_rows =~ /\A\d+\z/
            && $self->max_action_rows >= 1 && $self->max_action_rows <= 1000;
    die "action_handlers must be an object\n" unless ref($self->action_handlers) eq 'HASH';
    die "choice_sources must be an object\n" unless ref($self->choice_sources) eq 'HASH';
    die "action_authorizer must be a coderef\n"
        if defined($self->action_authorizer) && ref($self->action_authorizer) ne 'CODE';
    if (defined(my $store = $self->saved_query_store)) {
        die "saved_query_store must be an object\n" unless blessed($store);
        for my $method (qw(list save delete)) {
            die "saved_query_store must provide $method\n" unless $store->can($method);
        }
    }
    for my $id (keys %{$self->action_handlers}) {
        die "action handler id must be a lowercase identifier\n"
            unless $id =~ /\A[a-z][a-z0-9_-]*\z/;
        die "action handler $id must be a coderef\n"
            unless ref($self->action_handlers->{$id}) eq 'CODE';
    }
    for my $id (keys %{$self->choice_sources}) {
        die "choice source id must be a lowercase identifier\n"
            unless $id =~ /\A[a-z][a-z0-9_-]*\z/;
        die "choice source $id must be a coderef\n"
            unless ref($self->choice_sources->{$id}) eq 'CODE';
    }

    my %known_view = map { $_ => 1 } qw(detail aggregate graph);
    my %seen_view;
    my @views = grep { !$seen_view{$_}++ } map { "$_" } @{$self->views // []};
    die "explorer must enable at least one view\n" unless @views;
    die "unsupported explorer view\n" if grep { !$known_view{$_} } @views;
    die "default_view must be enabled\n" unless grep { $_ eq $self->default_view } @views;
    $self->views(\@views);

    my %seen_measure;
    my @measures;
    for my $measure (@{$self->measures // []}) {
        die "measure must be an object\n" unless ref($measure) eq 'HASH';
        my $id = defined($measure->{id}) ? "$measure->{id}" : '';
        my $aggregate = defined($measure->{aggregate}) ? lc("$measure->{aggregate}") : '';
        die "measure id must be an identifier\n" unless $id =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
        die "duplicate measure id $id\n" if $seen_measure{$id}++;
        die "unsupported aggregate $aggregate\n" unless grep { $_ eq $aggregate } qw(
            count count_distinct avg sum min max true_count false_count buckets age_buckets
        );
        die "$aggregate measure $id requires a field\n"
            if $aggregate ne 'count' && (!defined($measure->{field}) || ref($measure->{field}));
        push @measures, {
            id => $id,
            label => defined($measure->{label}) ? "$measure->{label}" : _humanize($id),
            aggregate => $aggregate,
            (defined($measure->{field}) && !ref($measure->{field})
                ? (field => "$measure->{field}") : ()),
        };
    }
    $self->measures(\@measures);
    return $self;
}

sub engine ($self, $controller) {
    my $engine = $self->engine_factory->($controller);
    die "engine_factory did not return a Selecto::Engine\n"
        unless blessed($engine) && $engine->isa('Selecto::Engine');
    return $engine;
}

sub allows_view ($self, $view) {
    return scalar grep { $_ eq $view } @{$self->views};
}

sub action_handler ($self, $id) {
    return $self->action_handlers->{$id};
}

sub choice_source ($self, $id) {
    return $self->choice_sources->{$id};
}

sub saved_queries_enabled ($self, $domain) {
    return defined($self->saved_query_store) && $self->query_params_enabled($domain) ? 1 : 0;
}

sub has_bulk_actions ($self, $domain) {
    return @{$self->bulk_action_catalog($domain)} ? 1 : 0;
}

sub action_column_path ($self, $id) {
    return 'action:' . $id;
}

sub action_id_from_column ($self, $path) {
    return undef unless defined($path) && !ref($path)
        && "$path" =~ /\Aaction:([a-z][a-z0-9_-]*)\z/;
    return $1;
}

sub bulk_action_catalog ($self, $domain, $available = undef) {
    my @actions;
    if (defined($available)) {
        @actions = grep { ref($_) eq 'HASH' && defined($_->{id}) } @{$available // []};
    } else {
        my $specs = $domain->actions;
        return [] unless ref($specs) eq 'HASH';
        for my $id (sort keys %$specs) {
            my $spec = $specs->{$id};
            next unless $self->action_handler($id) && _bulk_action_spec($spec);
            push @actions, {%$spec, id => $id};
        }
    }
    return [map {
        my $id = "$_->{id}";
        my $label = defined($_->{label}) && !ref($_->{label}) ? "$_->{label}"
            : defined($_->{name}) && !ref($_->{name}) ? "$_->{name}" : _humanize($id);
        $label = 'Action: ' . $label unless $label =~ /\AAction\s*:/i;
        {
            path => $self->action_column_path($id),
            label => $label,
            type => 'action',
            action_id => $id,
        }
    } sort { $a->{id} cmp $b->{id} } @actions];
}

sub detail_column_catalog ($self, $domain, $available = undef) {
    return [
        @{$self->bulk_action_catalog($domain, $available)},
        @{$self->field_catalog($domain)},
    ];
}

sub detail_column_map ($self, $domain, $available = undef) {
    return {map { $_->{path} => {%$_} } @{$self->detail_column_catalog($domain, $available)}};
}

sub primary_key ($self, $domain) {
    my $contract = $domain->contract;
    my $primary_key = ref($contract) eq 'HASH' && ref($contract->{source}) eq 'HASH'
        ? $contract->{source}{primary_key} : undef;
    $primary_key = 'id' unless defined($primary_key) && !ref($primary_key)
        && "$primary_key" =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
    return "$primary_key";
}

sub field_catalog ($self, $domain, $options = undef) {
    $options //= {};
    die "field catalog options must be an object\n" unless ref($options) eq 'HASH';
    my $include_internal = $options->{include_internal} ? 1 : 0;
    my @catalog;
    my $fields = $domain->fields;
    my ($dimensions_by_key, $dimensions_by_display) = _star_dimensions($domain);
    my $contract = $domain->contract;
    my $source = ref($contract) eq 'HASH' && ref($contract->{source}) eq 'HASH'
        ? $contract->{source} : {};
    for my $path (sort keys %$fields) {
        next if !$include_internal && !$domain->field_is_public($path);
        my $link = _field_link($domain, $path, $source->{columns}{$path});
        my $html_format = _field_html_format($path, $source->{columns}{$path});
        my $label = _field_label($path, $source->{columns}{$path});
        my $dimension = $dimensions_by_key->{$path};
        push @catalog, {
            path => $path,
            label => $dimension ? $dimension->{label} : $label,
            type => $fields->{$path},
            association => undef,
            internal => $domain->field_is_public($path) ? 0 : 1,
            (defined($link) ? (link => $link) : ()),
            (defined($html_format) ? (html_format => $html_format) : ()),
            ($dimension ? (dimension => {%$dimension}) : ()),
        };
    }
    my $associations = $domain->associations;
    for my $association_name (sort keys %$associations) {
        my $association = $associations->{$association_name};
        my $association_fields = $association->fields;
        my $association_spec = ref($source->{associations}) eq 'HASH'
            ? $source->{associations}{$association_name} : undef;
        my $queryable = ref($association_spec) eq 'HASH'
            ? $association_spec->{queryable} : undef;
        my $schema = defined($queryable) && ref($contract) eq 'HASH'
            && ref($contract->{schemas}) eq 'HASH'
            ? $contract->{schemas}{$queryable} : undef;
        for my $field (sort keys %$association_fields) {
            my $path = "$association_name.$field";
            next if !$include_internal && !$domain->field_is_public($path);
            my $link = _field_link(
                $domain,
                $path,
                ref($schema) eq 'HASH' ? $schema->{columns}{$field} : undef,
            );
            my $html_format = _field_html_format(
                $path,
                ref($schema) eq 'HASH' ? $schema->{columns}{$field} : undef,
            );
            my $dimension = $dimensions_by_display->{$path};
            my $field_label = _field_label(
                $path,
                ref($schema) eq 'HASH' ? $schema->{columns}{$field} : undef,
                _humanize($field),
            );
            my $label = _humanize($association_name) . ' - ' . $field_label;
            push @catalog, {
                path => $path,
                label => $dimension ? $dimension->{label} : $label,
                type => $association_fields->{$field},
                association => $association_name,
                internal => $domain->field_is_public($path) ? 0 : 1,
                denormalizing => $association->cardinality eq 'many' ? 1 : 0,
                (defined($link) ? (link => $link) : ()),
                (defined($html_format) ? (html_format => $html_format) : ()),
                ($dimension ? (dimension => {%$dimension}) : ()),
            };
        }
    }
    return \@catalog;
}

sub _star_dimensions ($domain) {
    my (%by_key, %by_display);
    my $associations = $domain->associations;
    for my $name (sort keys %$associations) {
        my $association = $associations->{$name};
        next unless $association->can('join_mode')
            && $association->join_mode eq 'star_dimension';
        my $key_field = $association->dimension_key;
        my $display_field = $name . '.' . $association->display_field;
        my $display_type = $association->fields->{$association->display_field};
        my $label = $association->display_name;
        $label = _humanize($name) unless defined($label) && length($label);
        my $dimension = {
            association => $name,
            key_field => $key_field,
            display_field => $display_field,
            display_type => $display_type,
            label => $label,
        };
        die "more than one star dimension uses key $key_field\n" if $by_key{$key_field};
        $by_key{$key_field} = $dimension;
        $by_display{$display_field} = $dimension;
    }
    return (\%by_key, \%by_display);
}

sub _field_link ($domain, $path, $column) {
    return undef unless ref($column) eq 'HASH' && exists($column->{link});
    my $link = $column->{link};
    die "link metadata for $path must be an object\n" unless ref($link) eq 'HASH';
    my $template = $link->{url_template};
    die "link URL template for $path must be a safe application path containing {{id}}\n"
        unless defined($template) && !ref($template)
            && "$template" =~ m{\A/(?!/)[^\x00-\x20\x7f]*\{\{id\}\}[^\x00-\x20\x7f]*\z}
            && do { my $rest = "$template"; $rest =~ s/\{\{id\}\}//g; $rest !~ /[{}]/ };
    my $id_field = exists($link->{id_field}) ? $link->{id_field} : 'id';
    die "link id field for $path must be a relative field name\n"
        unless defined($id_field) && !ref($id_field)
            && "$id_field" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    my ($association) = "$path" =~ /\A([^.]+)\./;
    my $resolved_id_field = defined($association) ? "$association.$id_field" : "$id_field";
    my $resolved = eval { $domain->resolve($resolved_id_field) };
    die "link id field $resolved_id_field for $path is not queryable\n" unless $resolved;
    return {
        url_template => "$template",
        id_field => $resolved_id_field,
    };
}

sub _field_html_format ($path, $column) {
    return undef unless ref($column) eq 'HASH' && exists($column->{html_format});
    my $format = $column->{html_format};
    die "HTML format for $path must be vin_last_six\n"
        unless defined($format) && !ref($format) && "$format" eq 'vin_last_six';
    return "$format";
}

sub _field_label ($path, $column, $fallback = undef) {
    $fallback //= _humanize($path);
    return $fallback unless ref($column) eq 'HASH' && exists($column->{label});
    my $label = $column->{label};
    die "label for $path must be a non-empty scalar no longer than 80 characters\n"
        if !defined($label) || ref($label) || !length("$label") || length("$label") > 80
        || "$label" =~ /[\x00-\x1f\x7f]/;
    return "$label";
}

sub field_map ($self, $domain) {
    return { map { $_->{path} => { %$_ } } @{$self->field_catalog($domain)} };
}

sub query_field_map ($self, $domain) {
    return {
        map { $_->{path} => { %$_ } }
        @{$self->field_catalog($domain, {include_internal => 1})}
    };
}

sub resolved_default_fields ($self, $domain) {
    my $map = $self->detail_column_map($domain);
    my @configured = grep { $map->{$_} } @{$self->default_fields // []};
    return \@configured if @configured;
    return [map { $_->{path} } @{$self->field_catalog($domain)}[0 .. _last_index($self->field_catalog($domain), 6)]];
}

sub resolved_default_group ($self, $domain) {
    my $map = $self->field_map($domain);
    my @configured = grep { $map->{$_} } @{$self->default_group // []};
    return \@configured if @configured;
    my ($first) = grep { $_->{type} !~ /\A(?:integer|decimal|number|float|boolean)\z/i }
        @{$self->field_catalog($domain)};
    $first //= $self->field_catalog($domain)->[0];
    return [$first->{path}];
}

sub measure ($self, $id, $domain = undef) {
    my $measures = defined($domain) ? $self->measures_for_domain($domain) : $self->measures;
    for my $measure (@$measures) {
        return { %$measure } if $measure->{id} eq $id;
    }
    return undef;
}

sub measures_for_domain ($self, $domain) {
    my $fields = $self->field_map($domain);
    my @measures = map {
        my $measure = $_;
        +{
            %$measure,
            type => defined($measure->{field}) ? $fields->{$measure->{field}}{type} : 'rows',
            curated => 1,
        }
    } @{$self->measures};
    my %seen = map { $_->{id} => 1 } @measures;
    unless (grep { !defined($_->{field}) && $_->{aggregate} eq 'count' } @measures) {
        push @measures, {
            id => '__row_count__', label => 'Row count', aggregate => 'count',
            type => 'rows', curated => 0, builtin => 1,
        };
        $seen{'__row_count__'} = 1;
    }
    for my $column (@{$self->field_catalog($domain)}) {
        my $id = $seen{$column->{path}} ? 'field:' . $column->{path} : $column->{path};
        push @measures, {
            id => $id,
            label => $column->{label},
            aggregate => _default_measure_function($column->{type}),
            field => $column->{path},
            type => $column->{type},
            curated => 0,
        };
        $seen{$id} = 1;
    }
    return \@measures;
}

sub default_measure ($self, $domain) {
    my $measures = $self->measures_for_domain($domain);
    return { %{$measures->[0]} };
}

sub measure_catalog ($self, $domain) {
    return [map {
        my $measure = $_;
        {
            path => $measure->{id},
            label => $measure->{label},
            type => $measure->{type},
            field => $measure->{field},
            default_function => $measure->{aggregate},
        }
    } @{$self->measures_for_domain($domain)}];
}

sub measure_functions ($self, $type, $row_count = 0) {
    return [[count => 'Count']] if $row_count;
    return [
        [count => 'Count'], [count_distinct => 'Count distinct'],
        [avg => 'Average'], [sum => 'Sum'], [min => 'Minimum'], [max => 'Maximum'],
        [buckets => 'Buckets'],
    ] if $self->numeric_type($type);
    return [
        [count => 'Count'], [count_distinct => 'Count distinct'],
        [min => 'Minimum'], [max => 'Maximum'], [age_buckets => 'Age buckets'],
    ] if $self->temporal_type($type);
    return [
        [count => 'Count'], [true_count => 'True count'], [false_count => 'False count'],
    ] if $self->boolean_type($type);
    return [
        [count => 'Count'], [count_distinct => 'Count distinct'],
        [min => 'Minimum'], [max => 'Maximum'],
    ];
}

sub allows_measure_function ($self, $type, $function, $row_count = 0) {
    return scalar grep { $_->[0] eq $function } @{$self->measure_functions($type, $row_count)};
}

sub group_formats ($self, $type) {
    return [
        [default => 'Default'],
        (map { [$_->{id}, $_->{label}] } @DATE_FORMATS),
        [age_buckets => 'Age buckets'],
        [custom_buckets => 'Relative date buckets'],
        [year_buckets => 'Year buckets'],
    ] if $self->temporal_type($type);
    return [[default => 'Default'], [buckets => 'Buckets']] if $self->numeric_type($type);
    return [[default => 'Default'], [text_prefix => 'Text prefix']]
        if defined($type) && !ref($type) && "$type" =~ /(?:string|text|char|citext)/i;
    return [[default => 'Default']];
}

sub allows_group_format ($self, $type, $format) {
    $format = 'default' unless defined($format) && length("$format");
    return scalar grep { $_->[0] eq "$format" } @{$self->group_formats($type)};
}

sub date_formats ($self) { return [map { { %$_ } } @DATE_FORMATS]; }

sub allows_date_format ($self, $format) {
    return 1 unless defined($format) && length("$format");
    return scalar grep { $_->{id} eq "$format" } @DATE_FORMATS;
}

sub temporal_type ($self, $type) {
    return defined($type) && !ref($type) && "$type" =~ /(?:date|time)/i ? 1 : 0;
}

sub numeric_type ($self, $type) {
    return defined($type) && !ref($type)
        && "$type" =~ /\A(?:integer|int|smallint|bigint|id|decimal|number|numeric|float|double|real)\z/i
        ? 1 : 0;
}

sub boolean_type ($self, $type) {
    return defined($type) && !ref($type) && "$type" =~ /\A(?:bool|boolean)\z/i ? 1 : 0;
}

sub filter_operators ($self, $type) {
    return [
        [eq => 'is'],
        [is_null => 'is empty'],
        [not_null => 'is not empty'],
    ] if $self->boolean_type($type);
    return [
        [eq => 'on'], [ne => 'not on'],
        [gt => 'after'], [gte => 'on or after'],
        [lt => 'before'], [lte => 'on or before'],
        [between => 'between'], [date_shortcut => 'quick select'],
        [is_null => 'is empty'], [not_null => 'is not empty'],
    ] if $self->temporal_type($type);
    return [
        [eq => 'equals'], [ne => 'does not equal'],
        [gte => 'at least'], [gt => 'greater than'],
        [lte => 'at most'], [lt => 'less than'],
        [between => 'between'], [in => 'one of'],
        [is_null => 'is empty'], [not_null => 'is not empty'],
    ] if $self->numeric_type($type);
    return [
        [eq => 'equals'], [ne => 'does not equal'], [in => 'one of'],
        [is_null => 'is empty'], [not_null => 'is not empty'],
    ];
}

sub allows_filter_operator ($self, $type, $operator) {
    return scalar grep { $_->[0] eq $operator } @{$self->filter_operators($type)};
}

sub filter_input_type ($self, $type) {
    return 'date' if defined($type) && !ref($type) && lc("$type") eq 'date';
    return 'datetime-local' if $self->temporal_type($type);
    return 'number' if $self->numeric_type($type);
    return 'text';
}

sub date_shortcuts ($self) { return Selecto::Components::DateShortcut->choices; }

sub query_params_enabled ($self, $domain) {
    return 1 unless blessed($domain) && $domain->can('components');
    my $components = $domain->components;
    return 1 unless ref($components) eq 'HASH' && exists $components->{query_params};
    return $components->{query_params} ? 1 : 0;
}

sub validate_domain ($self, $domain) {
    my $map = $self->field_map($domain);
    my $detail_map = $self->detail_column_map($domain);
    for my $field (@{$self->default_fields}) {
        die "configured explorer field $field is outside the domain\n" unless $detail_map->{$field};
    }
    for my $field (@{$self->default_group}) {
        die "configured explorer field $field is outside the domain\n" unless $map->{$field};
    }
    for my $measure (@{$self->measures}) {
        next unless defined $measure->{field};
        die "configured measure field $measure->{field} is outside the domain\n"
            unless $map->{$measure->{field}};
        die "configured measure function $measure->{aggregate} is unavailable for $measure->{field}\n"
            unless $self->allows_measure_function(
                $map->{$measure->{field}}{type}, $measure->{aggregate}, 0
            );
    }
    return $self;
}

sub _last_index ($catalog, $maximum) {
    my $last = @$catalog - 1;
    return $last < $maximum - 1 ? $last : $maximum - 1;
}

sub _bulk_action_spec ($spec) {
    return 0 unless ref($spec) eq 'HASH';
    return 1 if lc($spec->{scope} // '') eq 'bulk';
    my $bulk = $spec->{bulk};
    return 1 if defined($bulk) && !ref($bulk) && "$bulk" =~ /\A(?:1|true)\z/i;
    return ref($bulk) eq 'HASH' && $bulk->{enabled} ? 1 : 0;
}

sub _humanize ($value) { return humanize($value); }

sub _default_measure_function ($type) {
    return 'avg' if defined($type) && !ref($type) && "$type" =~ /\A(?:float|double|real)\z/i;
    return 'count';
}

1;
