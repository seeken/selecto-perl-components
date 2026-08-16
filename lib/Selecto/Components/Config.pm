package Selecto::Components::Config;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Components::DateShortcut ();

has [qw(id title path engine_factory)];
has views         => sub { return [qw(detail aggregate graph)] };
has default_view  => 'detail';
has default_fields => sub { return [] };
has default_group  => sub { return [] };
has measures       => sub { return [{ id => 'count', label => 'Row count', aggregate => 'count' }] };
has default_limit  => 25;
has max_limit      => 100;
has max_filters    => 20;
has max_orders     => 10;
has show_sql       => 0;

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
        die "unsupported aggregate $aggregate\n"
            unless $aggregate eq 'count' || $aggregate eq 'sum'
                || $aggregate eq 'min' || $aggregate eq 'max';
        die "$aggregate measure $id requires a field\n"
            if $aggregate ne 'count' && (!defined($measure->{field}) || ref($measure->{field}));
        push @measures, {
            id => $id,
            label => defined($measure->{label}) ? "$measure->{label}" : _humanize($id),
            aggregate => $aggregate,
            ($aggregate eq 'count' ? () : (field => "$measure->{field}")),
        };
    }
    die "explorer must configure at least one measure\n" unless @measures;
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

sub field_catalog ($self, $domain) {
    my @catalog;
    my $fields = $domain->fields;
    push @catalog, map {
        { path => $_, label => _humanize($_), type => $fields->{$_}, association => undef }
    } sort keys %$fields;
    my $associations = $domain->associations;
    for my $association_name (sort keys %$associations) {
        my $association = $associations->{$association_name};
        my $association_fields = $association->fields;
        push @catalog, map {
            {
                path => "$association_name.$_",
                label => _humanize($association_name) . ' · ' . _humanize($_),
                type => $association_fields->{$_},
                association => $association_name,
            }
        } sort keys %$association_fields;
    }
    return \@catalog;
}

sub field_map ($self, $domain) {
    return { map { $_->{path} => { %$_ } } @{$self->field_catalog($domain)} };
}

sub resolved_default_fields ($self, $domain) {
    my $map = $self->field_map($domain);
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

sub measure ($self, $id) {
    for my $measure (@{$self->measures}) {
        return { %$measure } if $measure->{id} eq $id;
    }
    return undef;
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
        && "$type" =~ /\A(?:integer|decimal|number|numeric|float|double|real)\z/i ? 1 : 0;
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
    for my $field (@{$self->default_fields}, @{$self->default_group}) {
        die "configured explorer field $field is outside the domain\n" unless $map->{$field};
    }
    for my $measure (@{$self->measures}) {
        next if $measure->{aggregate} eq 'count';
        die "configured measure field $measure->{field} is outside the domain\n"
            unless $map->{$measure->{field}};
    }
    return $self;
}

sub _last_index ($catalog, $maximum) {
    my $last = @$catalog - 1;
    return $last < $maximum - 1 ? $last : $maximum - 1;
}

sub _humanize ($value) {
    my $text = "$value";
    $text =~ s/_/ /g;
    $text =~ s/\b([a-z])/uc($1)/eg;
    return $text;
}

1;
