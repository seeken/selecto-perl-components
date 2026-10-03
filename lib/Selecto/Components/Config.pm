package Selecto::Components::Config;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::DateFormat ();
use Selecto::Components::DateShortcut ();
use Selecto::Components::I18N ();
use Selecto::Components::ExplorerSession ();
use Selecto::Components::Util qw(humanize);
use Selecto::Components::ThemeStylesheet ();
use Selecto::Analytics::UnitRegistry ();
use Selecto::Retarget ();
use Selecto::Limits ();
use File::Spec ();

has [qw(id title path engine_factory)];
has views         => sub { return [qw(detail aggregate graph)] };
has default_view  => 'detail';
has default_row_click_action => '';
has default_fields => sub { return [] };
has default_group  => sub { return [] };
has measures       => sub { return [] };
has default_limit  => 25;
has max_limit      => 100;
has max_filters    => 20;
has max_grid_cells => 50;
has max_grid_result_cells => 10_000;
has max_orders     => 10;
has max_measures   => 10;
has max_action_rows => 1000;
has limits => sub { Selecto::Limits->new };
has show_sql       => 0;
# Hosts can opt in to fetching inactive detail/summary controls on demand.
has lazy_view_controls => 0;
has action_handlers => sub { return {} };
has choice_sources  => sub { return {} };
has filter_fields   => sub { return [] };
has lookup_sources  => sub { return {} };
has co_domain_engines => sub { return {} };
has co_domain_scopes  => sub { return {} };
has action_eligibility_resolvers => sub { return {} };
has action_form_resolvers => sub { return {} };
has 'action_authorizer';
# Optional coderef ($controller, $config) returning true when the request may
# export results (Excel/CSV/TSV/JSON). Without one, exports are allowed.
has 'export_authorizer';
# Positive finite export budgets. Materializing all-rows models are refused.
has max_export_rows => 10_000;
has max_export_bytes => 16_777_216;
has max_export_seconds => 30;
has max_export_temp_bytes => 33_554_432;
has max_concurrent_exports => 4;
has max_actor_exports => 2;
has export_lock_dir => sub { File::Spec->catdir(File::Spec->tmpdir, 'selecto-export-' . $<) };
has 'export_actor';
has 'record_editor_handler';
has record_editor_max_age => 3600;
has 'saved_query_store';
has 'localizer';
has 'theme_resolver';
has 'page_shell_resolver';
has 'api_console_resolver';
has 'websocket_message_cleanup';
has 'websocket_context';
has 'result_cache_namespace';
has websocket_mode => 'protected';
has websocket_enabled => 1;
has websocket_session_options => sub { {} };
has 'query_assistant';

my @DATE_FORMATS = @{Selecto::DateFormat->choices};

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    die "limits must be a Selecto::Limits object\n" unless blessed($self->limits) && $self->limits->isa('Selecto::Limits');
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
    die "max_grid_cells must be between 1 and 100\n"
        unless $self->max_grid_cells =~ /\A\d+\z/
            && $self->max_grid_cells >= 1 && $self->max_grid_cells <= 100;
    die "max_grid_result_cells must be between 100 and 100000\n"
        unless $self->max_grid_result_cells =~ /\A\d+\z/
            && $self->max_grid_result_cells >= 100
            && $self->max_grid_result_cells <= 100_000;
    die "max_orders must be between 1 and 20\n"
        unless $self->max_orders =~ /\A\d+\z/ && $self->max_orders >= 1 && $self->max_orders <= 20;
    die "max_measures must be between 1 and 20\n"
        unless $self->max_measures =~ /\A\d+\z/ && $self->max_measures >= 1 && $self->max_measures <= 20;
    die "max_action_rows must be between 1 and 1000\n"
        unless $self->max_action_rows =~ /\A\d+\z/
            && $self->max_action_rows >= 1 && $self->max_action_rows <= 1000;
    die "action_handlers must be an object\n" unless ref($self->action_handlers) eq 'HASH';
    die "choice_sources must be an object\n" unless ref($self->choice_sources) eq 'HASH';
    die "filter_fields must be an array of field paths\n"
        unless ref($self->filter_fields) eq 'ARRAY'
            && !grep { !defined($_) || ref($_) || $_ !~ /\A[a-z][a-z0-9_.]*\z/ }
                @{$self->filter_fields};
    die "lookup_sources must be an object\n" unless ref($self->lookup_sources) eq 'HASH';
    die "co_domain_engines must be an object\n"
        unless ref($self->co_domain_engines) eq 'HASH';
    die "co_domain_scopes must be an object\n"
        unless ref($self->co_domain_scopes) eq 'HASH';
    die "action_eligibility_resolvers must be an object\n"
        unless ref($self->action_eligibility_resolvers) eq 'HASH';
    die "action_form_resolvers must be an object\n"
        unless ref($self->action_form_resolvers) eq 'HASH';
    for my $id (keys %{$self->action_form_resolvers}) {
        die "Invalid action form resolver\n" unless $id =~ /\A[a-z][a-z0-9_-]*\z/
            && ref($self->action_form_resolvers->{$id}) eq 'CODE';
    }
    die "localizer must be a coderef\n"
        if defined($self->localizer) && ref($self->localizer) ne 'CODE';
    die "theme_resolver must be a coderef\n"
        if defined($self->theme_resolver) && ref($self->theme_resolver) ne 'CODE';
    die "page_shell_resolver must be a coderef\n"
        if defined($self->page_shell_resolver) && ref($self->page_shell_resolver) ne 'CODE';
    die "api_console_resolver must be a coderef\n"
        if defined($self->api_console_resolver) && ref($self->api_console_resolver) ne 'CODE';
    die "websocket_message_cleanup must be a coderef\n"
        if defined($self->websocket_message_cleanup)
            && ref($self->websocket_message_cleanup) ne 'CODE';
    die "result_cache_namespace must be a coderef\n"
        if defined($self->result_cache_namespace) && ref($self->result_cache_namespace) ne 'CODE';
    die "websocket_context must be a coderef\n"
        if defined($self->websocket_context) && ref($self->websocket_context) ne 'CODE';
    die "websocket_mode must be protected or public\n"
        unless $self->websocket_mode =~ /\A(?:protected|public)\z/;
    Selecto::Components::ExplorerSession->validate_options($self->websocket_session_options);
    if (defined(my $assistant = $self->query_assistant)) {
        die "query_assistant must be an object\n" unless ref($assistant) eq 'HASH';
        die "query_assistant store is required\n"
            unless blessed($assistant->{store})
                && $assistant->{store}->can('create')
                && $assistant->{store}->can('get')
                && $assistant->{store}->can('compare_and_swap');
        for my $callback (qw(actor context_authorizer choice_resolver)) {
            die "query_assistant $callback must be a coderef\n"
                if defined($assistant->{$callback}) && ref($assistant->{$callback}) ne 'CODE';
        }
        die "query_assistant requires actor or explicit allow_anonymous => 1\n"
            unless $assistant->{actor} || $assistant->{allow_anonymous};
        die "query_assistant choice_range_fields must be an object\n"
            if defined($assistant->{choice_range_fields}) && ref($assistant->{choice_range_fields}) ne 'HASH';
        die "query_assistant choice_fields must be an object\n"
            if defined($assistant->{choice_fields}) && ref($assistant->{choice_fields}) ne 'HASH';
    }
    die "default_row_click_action must be empty or a lowercase identifier\n"
        if !defined($self->default_row_click_action)
            || ref($self->default_row_click_action)
            || length($self->default_row_click_action)
                && $self->default_row_click_action !~ /\A[a-z][a-z0-9_-]*\z/;
    die "action_authorizer must be a coderef\n"
        if defined($self->action_authorizer) && ref($self->action_authorizer) ne 'CODE';
    die "export_authorizer must be a coderef\n"
        if defined($self->export_authorizer) && ref($self->export_authorizer) ne 'CODE';
    for my $key (qw(max_export_bytes max_export_temp_bytes max_export_seconds max_concurrent_exports max_actor_exports)) {
        my $value = $self->$key;
        die "Invalid $key\n" unless defined($value) && !ref($value) && "$value" =~ /\A[1-9][0-9]{0,8}\z/;
    }
    die "export concurrency cannot exceed 64\n" if $self->max_concurrent_exports > 64 || $self->max_actor_exports > 64;
    die "export_actor must be a coderef\n" if defined($self->export_actor) && ref($self->export_actor) ne 'CODE';
    die "max_export_rows must be a positive integer up to 10000000\n"
        if !defined($self->max_export_rows)
            || ($self->max_export_rows !~ /\A[1-9]\d{0,7}\z/ || $self->max_export_rows > 10_000_000);
    die "record_editor_handler must be a coderef\n"
        if defined($self->record_editor_handler)
            && ref($self->record_editor_handler) ne 'CODE';
    die "record_editor_max_age must be between 1 and 86400 seconds\n"
        unless $self->record_editor_max_age =~ /\A[1-9]\d*\z/ && $self->record_editor_max_age <= 86_400;
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
    for my $id (keys %{$self->lookup_sources}) {
        die "lookup source id must be a lowercase identifier\n"
            unless $id =~ /\A[a-z][a-z0-9_-]*\z/;
        die "lookup source $id must be a coderef\n"
            unless ref($self->lookup_sources->{$id}) eq 'CODE';
    }
    for my $id (keys %{$self->co_domain_engines}) {
        die "co-domain engine id must be a lowercase identifier\n"
            unless $id =~ /\A[a-z][a-z0-9_]*\z/;
        die "co-domain engine $id must be a coderef\n"
            unless ref($self->co_domain_engines->{$id}) eq 'CODE';
    }
    for my $id (keys %{$self->co_domain_scopes}) {
        die "co-domain scope id must be a lowercase identifier\n"
            unless $id =~ /\A[a-z][a-z0-9_]*\z/;
        die "co-domain scope $id must be a coderef\n"
            unless ref($self->co_domain_scopes->{$id}) eq 'CODE';
    }
    for my $id (keys %{$self->action_eligibility_resolvers}) {
        die "action eligibility resolver id must be a lowercase identifier\n"
            unless $id =~ /\A[a-z][a-z0-9_-]*\z/;
        die "action eligibility resolver $id must be a coderef\n"
            unless ref($self->action_eligibility_resolvers->{$id}) eq 'CODE';
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
            count count_distinct avg sum min max true_count false_count true_percentage buckets age_buckets
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

sub query_assistant_enabled ($self) {
    return ref($self->query_assistant) eq 'HASH'
        && ($self->query_assistant->{enabled} // 1) ? 1 : 0;
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

sub lookup_source ($self, $id) {
    return $self->lookup_sources->{$id};
}

sub co_domain_engine ($self, $id, $controller, $request = undef) {
    my $factory = $self->co_domain_engines->{$id};
    return undef unless $factory;
    my $engine = $factory->($controller);
    die "co-domain engine $id did not return a Selecto::Engine\n"
        unless blessed($engine) && $engine->isa('Selecto::Engine');
    return $engine;
}

sub co_domain_scope ($self, $id) {
    return $self->co_domain_scopes->{$id};
}

sub action_eligibility_resolver ($self, $id) {
    return $self->action_eligibility_resolvers->{$id};
}

sub saved_queries_enabled ($self, $domain) {
    return defined($self->saved_query_store) && $self->query_params_enabled($domain) ? 1 : 0;
}

sub localize ($self, $domain, $semantic, $default, $context = undef) {
    $context = ref($context) eq 'HASH' ? {%$context} : {};
    $context->{controller} = $self->{_localization_controller}
        if defined($self->{_localization_controller}) && !exists($context->{controller});
    return Selecto::Components::I18N->localize(
        $self->localizer, $domain, $semantic, $default, $context,
        $self->{_i18n_metadata_cache},
    );
}

sub for_request ($self, $controller) {
    my $copy = bless {%$self}, ref($self);
    $copy->{_localization_controller} = $controller;
    delete $copy->{_resolved_theme};
    delete $copy->{_resolved_page_shell};
    delete $copy->{_export_allowed};
    # Catalog construction walks the complete domain and localizes every label.
    # A single model/render cycle asks for the same catalogs through several
    # convenience methods, so keep those immutable results on the request copy.
    $copy->{_catalog_cache} = {};
    $copy->{_i18n_metadata_cache} = {};
    return $copy;
}

# Whether this request may export results (see export_authorizer). Only a
# request copy (for_request) remembers the answer; the shared configuration
# asks the authorizer every time.
sub export_allowed ($self, $controller = undef) {
    my $authorizer = $self->export_authorizer or return 1;
    my $request_copy = defined $self->{_localization_controller};
    return $self->{_export_allowed}
        if $request_copy && exists $self->{_export_allowed};
    $controller //= $self->{_localization_controller};
    my $allowed = $authorizer->($controller, $self) ? 1 : 0;
    $self->{_export_allowed} = $allowed if $request_copy;
    return $allowed;
}

sub api_console_url ($self, $model = undef) {
    my $resolver = $self->api_console_resolver;
    return '' unless $resolver;
    my $url = $resolver->($self->{_localization_controller}, $self, $model);
    return '' unless defined($url) && length("$url");
    die "api_console_resolver must return an absolute same-origin path\n"
        if ref($url) || "$url" !~ m{\A/(?!/)[A-Za-z0-9/_-]+\z};
    return "$url";
}

# The validated colours as CSS declarations, e.g. "--sc-brand:#123456".
sub theme_style ($self) {
    return join ';', map { "$_->[0]:$_->[1]" }
        @{Selecto::Components::ThemeStylesheet->declarations('explorer', $self->_resolved_theme)};
}

# Same-origin stylesheet URL for the theme colours ('' without colours); the
# page links it instead of an inline style so a strict style-src policy holds.
sub theme_stylesheet ($self) {
    return Selecto::Components::ThemeStylesheet->href('explorer', $self->_resolved_theme);
}

sub theme_scheme ($self) {
    my $theme = $self->_resolved_theme;
    return '' unless defined $theme->{scheme};
    die "theme scheme must be light or dark\n"
        if ref($theme->{scheme}) || "$theme->{scheme}" !~ /\A(?:light|dark)\z/;
    return "$theme->{scheme}";
}

sub _resolved_theme ($self) {
    return $self->{_resolved_theme} if exists $self->{_resolved_theme};
    my $resolver = $self->theme_resolver;
    return $self->{_resolved_theme} = {} unless $resolver;
    my $theme = $resolver->($self->{_localization_controller}, $self);
    $theme = {} unless defined $theme;
    die "theme_resolver must return an object\n" unless ref($theme) eq 'HASH';
    return $self->{_resolved_theme} = {%$theme};
}

sub page_shell ($self, $model = undef) {
    return $self->{_resolved_page_shell} if exists $self->{_resolved_page_shell};
    my $resolver = $self->page_shell_resolver;
    return $self->{_resolved_page_shell} = {} unless $resolver;
    my $shell = $resolver->($self->{_localization_controller}, $self, $model);
    $shell = {} unless defined $shell;
    die "page_shell_resolver must return an object\n" unless ref($shell) eq 'HASH';

    my %resolved;
    for my $key (qw(head_start_html head_html body_start_html)) {
        next unless defined $shell->{$key};
        die "page shell $key must be a scalar\n" if ref($shell->{$key});
        $resolved{$key} = "$shell->{$key}";
    }
    for my $key (qw(body_class content_class)) {
        next unless defined $shell->{$key};
        die "page shell $key must contain CSS class names\n"
            if ref($shell->{$key})
                || "$shell->{$key}" !~ /\A[A-Za-z0-9_-]+(?:\s+[A-Za-z0-9_-]+)*\z/;
        $resolved{$key} = "$shell->{$key}";
    }
    return $self->{_resolved_page_shell} = \%resolved;
}

sub localization_terms ($self, $domain) {
    return Selecto::Components::I18N->terms($domain, {
        title => $self->title,
        measures => $self->measures,
    });
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
        $label = $self->localize(
            $domain, "actions.$id.label", $label,
            {kind => 'action', id => $id, attribute => 'label'},
        );
        $label = 'Action: ' . $label unless $label =~ /\AAction\s*:/i;
        {
            path => $self->action_column_path($id),
            label => $label,
            type => 'action',
            action_id => $id,
        }
    } sort { $a->{id} cmp $b->{id} } @actions];
}

sub detail_column_catalog ($self, $domain, $available = undef, $rows_of = undef) {
    # Bulk actions act on root rows, so a retargeted grain offers none.
    return [@{$self->field_catalog($domain, {rows_of => $rows_of})}] if defined $rows_of;
    return [
        @{$self->bulk_action_catalog($domain, $available)},
        @{$self->field_catalog($domain)},
    ];
}

sub detail_column_map ($self, $domain, $available = undef, $rows_of = undef) {
    return {map { $_->{path} => {%$_} }
        @{$self->detail_column_catalog($domain, $available, $rows_of)}};
}

# A retarget ("Rows of") target: the relation at an association path that the
# domain allows as a row grain. Undefined when the path is not one. Catalog
# paths for a target stay root-relative: the target's fields are prefixed with
# its path, and the query builder re-roots them.
sub retarget_target ($self, $domain, $path) {
    return undef unless defined($path) && !ref($path)
        && "$path" =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
    my $cache_key = join "\x1f", 'retarget', $domain->fingerprint, $path;
    my $cache = $self->{_catalog_cache};
    return $cache->{$cache_key} if ref($cache) eq 'HASH' && exists $cache->{$cache_key};
    my $target = eval { Selecto::Retarget->target($domain, "$path") };
    unless ($target) {
        my $error = $@;
        die $error unless blessed($error) && $error->isa('Selecto::Error');
        $cache->{$cache_key} = undef if ref($cache) eq 'HASH';
        return undef;
    }
    my $retarget = $domain->retarget_config // {};
    my $declared = ref($retarget->{targets}) eq 'HASH' ? $retarget->{targets} : {};
    my $spec = ref($declared->{$path}) eq 'HASH' ? $declared->{$path} : {};
    my @associations = @{$domain->resolve_association("$path")->{associations}};
    my ($last) = "$path" =~ /([^.]+)\z/;
    my $resolved = {
        path => "$path",
        label => $self->localize(
            $domain, "retarget.targets.$path.label", $spec->{label} // _humanize($last),
            {kind => 'retarget_target', path => "$path", attribute => 'label'},
        ),
        domain => Selecto::Retarget->relation_domain($domain, $target),
        primary_key => $target->{primary_key},
        to_many => (grep { $_->cardinality eq 'many' } @associations) ? 1 : 0,
        declared => exists($declared->{$path}) ? 1 : 0,
        default_selected => [map { "$path.$_" } @{$spec->{default_selected} // []}],
    };
    $cache->{$cache_key} = $resolved if ref($cache) eq 'HASH';
    return $resolved;
}

# The targets a "Rows of" picker offers: the domain's declared targets.
sub retarget_targets ($self, $domain) {
    my $retarget = $domain->retarget_config;
    return [] unless ref($retarget) eq 'HASH' && ref($retarget->{targets}) eq 'HASH';
    return [grep { defined } map { $self->retarget_target($domain, $_) }
        sort keys %{$retarget->{targets}}];
}

sub _retarget_or_die ($self, $domain, $path) {
    return $self->retarget_target($domain, $path)
        // die "retarget target $path is not available\n";
}

# Root-relative copy of a target catalog entry.
sub _prefixed_catalog_entry ($entry, $prefix) {
    my %copy = %$entry;
    $copy{path} = "$prefix.$entry->{path}";
    $copy{picker_group_key} = defined($entry->{association})
        ? (split /\./, $entry->{association})[0] : '';
    $copy{association} = defined($entry->{association})
        ? "$prefix.$entry->{association}" : $prefix;
    $copy{link} = {%{$entry->{link}}, id_field => "$prefix.$entry->{link}{id_field}"}
        if ref($entry->{link}) eq 'HASH' && defined $entry->{link}{id_field};
    if (ref($entry->{dimension}) eq 'HASH') {
        my %dimension = %{$entry->{dimension}};
        for my $key (qw(key_field display_field association)) {
            $dimension{$key} = "$prefix.$dimension{$key}" if defined $dimension{$key};
        }
        $copy{dimension} = \%dimension;
    }
    return \%copy;
}

sub primary_key ($self, $domain, $rows_of = undef) {
    if (defined $rows_of) {
        my $target = $self->_retarget_or_die($domain, $rows_of);
        return "$target->{path}.$target->{primary_key}";
    }
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
    my $rows_of = $options->{rows_of};
    my $cache_key = join "\x1f", 'fields', $domain->fingerprint,
        $include_internal ? 'internal' : 'public', $rows_of // '';
    my $cache = $self->{_catalog_cache};
    return $cache->{$cache_key} if ref($cache) eq 'HASH' && exists $cache->{$cache_key};
    if (defined $rows_of) {
        my $target = $self->_retarget_or_die($domain, $rows_of);
        my $catalog = [map { _prefixed_catalog_entry($_, $target->{path}) } @{$self->field_catalog(
            $target->{domain}, {include_internal => $include_internal},
        )}];
        $cache->{$cache_key} = $catalog if ref($cache) eq 'HASH';
        return $catalog;
    }
    my @catalog;
    my $fields = $domain->fields;
    my ($dimensions_by_key, $dimensions_by_display) = _star_dimensions($domain);
    my $contract = $domain->contract;
    my $source = ref($contract) eq 'HASH' && ref($contract->{source}) eq 'HASH'
        ? $contract->{source} : {};
    my $components = $domain->components;
    my %visible_id = map { $_ => 1 }
        @{$components->{picker_visible_id_paths} // []};
    my $source_associations = ref($source->{associations}) eq 'HASH'
        ? $source->{associations} : {};
    my %reference_keys;
    for my $name (keys %$source_associations) {
        my $spec = $source_associations->{$name};
        next unless ref($spec) eq 'HASH';
        my $owner_key = $spec->{owner_key};
        next unless defined($owner_key) && $owner_key ne ($source->{primary_key} // 'id');
        $reference_keys{$owner_key} = 1;
    }
    for my $path (sort keys %$fields) {
        next if !$include_internal && !$domain->field_is_public($path);
        my $link = _field_link($domain, $path, $source->{columns}{$path});
        my $html_format = _field_html_format($path, $source->{columns}{$path});
        my $label = _field_label($path, $source->{columns}{$path});
        my $dimension = $dimensions_by_key->{$path};
        $label = $dimension ? $dimension->{key_label} : $label;
        $label = $self->localize(
            $domain, "fields.$path.label", $label,
            {kind => 'field', path => $path, attribute => 'label'},
        );
        push @catalog, {
            path => $path,
            label => $label,
            type => $fields->{$path},
            association => undef,
            internal => $domain->field_is_public($path) ? 0 : 1,
            (_picker_hidden_id($path, $source->{primary_key}, $dimension,
                \%visible_id, \%reference_keys)
                ? (picker_hidden => 1) : ()),
            (defined($domain->field_unit($path))
                ? (unit => $domain->field_unit($path)) : ()),
            (defined($domain->field_behavior($path))
                ? (behavior => $domain->field_behavior($path)) : ()),
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
        my $group_label = _picker_group_label($self, $domain, $contract, $association_name);
        my $queryable = ref($association_spec) eq 'HASH'
            ? $association_spec->{queryable} : undef;
        my $schema = defined($queryable) && ref($contract) eq 'HASH'
            && ref($contract->{schemas}) eq 'HASH'
            ? $contract->{schemas}{$queryable} : undef;
        $schema = {} unless ref($schema) eq 'HASH';
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
            my $dimension = $dimensions_by_key->{$path}
                // $dimensions_by_display->{$path};
            my $field_label = _field_label(
                $path,
                ref($schema) eq 'HASH' ? $schema->{columns}{$field} : undef,
                _humanize($field),
            );
            my $label = $dimension ? $dimension->{label}
                : _humanize($association_name) . ' - ' . $field_label;
            $label = $self->localize(
                $domain, "fields.$path.label", $label,
                {kind => 'field', path => $path, attribute => 'label'},
            );
            push @catalog, {
                path => $path,
                label => $label,
                type => $association_fields->{$field},
                association => $association_name,
                picker_group_label => $group_label,
                internal => $domain->field_is_public($path) ? 0 : 1,
                denormalizing => $association->cardinality eq 'many' ? 1 : 0,
                (_picker_hidden_id($path, $schema->{primary_key}, $dimension,
                    \%visible_id, {})
                    ? (picker_hidden => 1) : ()),
                (defined($domain->field_unit($path))
                    ? (unit => $domain->field_unit($path)) : ()),
                (defined($domain->field_behavior($path))
                    ? (behavior => $domain->field_behavior($path)) : ()),
                (defined($link) ? (link => $link) : ()),
                (defined($html_format) ? (html_format => $html_format) : ()),
                ($dimension ? (dimension => {%$dimension}) : ()),
            };
        }
    }
    # A filtered relationship may itself contain a star dimension.  These
    # paths are especially useful for tenant-defined option groups: the
    # relationship holds the stable ID, while Explorer presents only the
    # dimension's descriptive value.  Direct star dimensions were already
    # added by the loop above; add only nested display paths here.
    for my $path (sort keys %$dimensions_by_display) {
        next unless $path =~ /\A[^.]+\.[^.]+\.[^.]+\z/;
        my $dimension = $dimensions_by_display->{$path};
        next if !$include_internal && (
            !$domain->field_is_public($path) || $dimension->{denormalizing}
        );
        my $label = $self->localize(
            $domain, "fields.$path.label", $dimension->{label},
            {kind => 'field', path => $path, attribute => 'label'},
        );
        push @catalog, {
            path => $path,
            label => $label,
            type => $dimension->{display_type},
            association => $dimension->{association},
            picker_group_label => _picker_group_label(
                $self, $domain, $contract, $dimension->{association},
            ),
            internal => $domain->field_is_public($path) ? 0 : 1,
            denormalizing => $dimension->{denormalizing} ? 1 : 0,
            (defined($domain->field_unit($path))
                ? (unit => $domain->field_unit($path)) : ()),
            (defined($domain->field_behavior($path))
                ? (behavior => $domain->field_behavior($path)) : ()),
            dimension => {%$dimension},
        };
    }
    @catalog = sort {
        lc($a->{label}) cmp lc($b->{label})
            || $a->{label} cmp $b->{label}
            || $a->{path} cmp $b->{path}
    } @catalog;
    my $catalog = \@catalog;
    $cache->{$cache_key} = $catalog if ref($cache) eq 'HASH';
    return $catalog;
}

# Technical ids stay out of the pickers: a field named id or ending in _id,
# and a root association owner key, except the root primary key. A domain
# keeps identifiers its users know (client or account numbers) visible by
# listing them in components.picker_visible_id_paths.
sub _picker_hidden_id ($path, $primary_key, $dimension, $visible, $reference_keys) {
    return 0 if $visible->{$path};
    return 1 if $dimension && $path eq $dimension->{key_field};
    my ($field) = $path =~ /([^.]+)\z/;
    return 0 unless $field eq 'id' || $field =~ /_id\z/
        || (index($path, '.') < 0 && $reference_keys->{$field});
    return 0 if index($path, '.') < 0 && $field eq ($primary_key // 'id');
    return 1;
}

sub _picker_group_label ($self, $domain, $contract, $association_path) {
    my ($first) = split /\./, $association_path;
    my $join = ref($contract->{joins}) eq 'HASH' ? $contract->{joins}{$first} : undef;
    my $default = ref($join) eq 'HASH' && defined($join->{name})
        ? $join->{name} : _humanize($first);
    return $self->localize(
        $domain, "associations.$first.label", $default,
        {kind => 'association', path => $first, attribute => 'label'},
    );
}

sub _star_dimensions ($domain) {
    my (%by_key, %by_display);
    my $associations = $domain->associations;
    my $contract = $domain->contract;
    my $source_associations = ref($contract) eq 'HASH'
        && ref($contract->{source}) eq 'HASH'
        && ref($contract->{source}{associations}) eq 'HASH'
        ? $contract->{source}{associations} : {};
    my $schemas = ref($contract) eq 'HASH'
        && ref($contract->{schemas}) eq 'HASH' ? $contract->{schemas} : {};
    for my $name (sort keys %$associations) {
        my $association = $associations->{$name};
        _record_star_dimension(
            $domain, \%by_key, \%by_display, $association, $name, '', 0,
        );
        my %nested_names = map { $_ => 1 } keys %{$association->associations};
        my $association_spec = $source_associations->{$name};
        my $queryable = ref($association_spec) eq 'HASH'
            ? $association_spec->{queryable} : undef;
        my $schema = defined($queryable) ? $schemas->{$queryable} : undef;
        $nested_names{$_} = 1 for keys %{
            ref($schema) eq 'HASH' && ref($schema->{associations}) eq 'HASH'
                ? $schema->{associations} : {}
        };
        for my $nested_name (sort keys %nested_names) {
            my $resolved = eval {
                $domain->resolve_association("$name.$nested_name")
            };
            next unless $resolved && $resolved->{association};
            _record_star_dimension(
                $domain, \%by_key, \%by_display, $resolved->{association},
                "$name.$nested_name", $name,
                $association->cardinality eq 'many' ? 1 : 0,
            );
        }
    }
    return (\%by_key, \%by_display);
}

sub _record_star_dimension (
    $domain, $by_key, $by_display, $association, $association_path,
    $parent_path, $ancestor_denormalizing
) {
    return unless $association->can('join_mode')
        && $association->join_mode eq 'star_dimension';
    my $key_field = length($parent_path)
        ? "$parent_path." . $association->dimension_key
        : $association->dimension_key;
    my $display_field = $association_path . '.' . $association->display_field;
    my $display_type = $association->fields->{$association->display_field};
    my $label = $association->display_name;
    $label = _humanize($association_path =~ s/.*\.//r)
        unless defined($label) && length($label);
    my $key_metadata = $domain->field_metadata($key_field);
    my $key_label = _field_label($key_field, $key_metadata, $label . ' ID');
    my $dimension = {
        association => $association_path,
        key_field => $key_field,
        display_field => $display_field,
        display_type => $display_type,
        label => $label,
        key_label => $key_label,
        denormalizing => (
            $ancestor_denormalizing || $association->cardinality eq 'many'
        ) ? 1 : 0,
    };
    die "more than one star dimension uses key $key_field\n" if $by_key->{$key_field};
    $by_key->{$key_field} = $dimension;
    $by_display->{$display_field} = $dimension;
}

sub _field_link ($domain, $path, $column) {
    return undef unless ref($column) eq 'HASH' && exists($column->{link});
    my $link = $column->{link};
    die "link metadata for $path must be an object\n" unless ref($link) eq 'HASH';
    my $template = $link->{url_template};
    die "link URL template for $path must be a safe application path containing {{id}}\n"
        unless defined($template) && !ref($template)
            && "$template" =~ m{\A/(?!/)[^\x00-\x20\x7f\\]*\{\{id\}\}[^\x00-\x20\x7f\\]*\z}
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

sub field_map ($self, $domain, $rows_of = undef) {
    my $cache_key = join "\x1f", 'field-map', $domain->fingerprint, $rows_of // '';
    my $cache = $self->{_catalog_cache};
    return $cache->{$cache_key} if ref($cache) eq 'HASH' && exists $cache->{$cache_key};
    my $map = { map { $_->{path} => { %$_ } }
        @{$self->field_catalog($domain, {rows_of => $rows_of})} };
    $cache->{$cache_key} = $map if ref($cache) eq 'HASH';
    return $map;
}

# Filters always describe root rows (a retarget's context). A retargeted
# grain adds its own fields, prefixed with the target path, which the root
# domain resolves through the same join.
sub filter_catalog ($self, $domain, $rows_of = undef) {
    my $catalog = $self->_root_filter_catalog($domain);
    return $catalog unless defined $rows_of;
    my %present = map { $_->{path} => 1 } @$catalog;
    return [@$catalog, grep { !$present{$_->{path}} }
        @{$self->field_catalog($domain, {rows_of => $rows_of})}];
}

sub _root_filter_catalog ($self, $domain) {
    my %extra = map { $_ => 1 } @{$self->filter_fields};
    my $components = $domain->components;
    my $choice_specs = ref($components->{filter_choices}) eq 'HASH'
        ? $components->{filter_choices} : {};
    my $hidden_paths = ref($components->{filter_picker_hidden_paths}) eq 'ARRAY'
        ? $components->{filter_picker_hidden_paths} : [];
    my @catalog = map {
        my $field = $_;
        my %filter_field = %$field;
        delete $filter_field{picker_hidden};
        my $choice = $choice_specs->{$field->{path}};
        my $picker_hidden = (ref($choice) eq 'HASH' && $choice->{picker_hidden})
            || grep {
                /\.\z/ ? index($field->{path}, $_) == 0 : $field->{path} eq $_
            } @$hidden_paths;
        ref($choice) eq 'HASH' ? {
            %filter_field,
            label => $self->localize(
                $domain, "components.filter_choices.$field->{path}.label",
                $choice->{label},
                {kind => 'filter_choice', path => $field->{path}, attribute => 'label'},
            ),
            filter_choices => [map { {%$_} } @{$choice->{choices}}],
            # An internal field the host did not list is filterable only
            # through its declared choices.
            ($field->{internal} && !$extra{$field->{path}} ? (choices_only => 1) : ()),
            ($picker_hidden ? (picker_hidden => 1) : ()),
        } : {%filter_field, ($picker_hidden ? (picker_hidden => 1) : ())}
    } grep { !$_->{internal} || $extra{$_->{path}} || $choice_specs->{$_->{path}} }
        @{$self->field_catalog($domain, {include_internal => 1})};
    for my $path (sort keys %$choice_specs) {
        my $choice = $choice_specs->{$path};
        next unless ref($choice->{conditional}) eq 'HASH';
        my $conditional = $choice->{conditional};
        my $when = $domain->resolve($conditional->{when_field});
        my $present = $domain->resolve($conditional->{present_field});
        my $absent = $domain->resolve($conditional->{absent_field});
        die "conditional filter $path references an unavailable field\n"
            unless $when && $present && $absent;
        die "conditional filter $path must compare the same field type\n"
            unless $present->{type} eq $absent->{type};
        push @catalog, {
            path => $path,
            label => $self->localize(
                $domain, "components.filter_choices.$path.label", $choice->{label},
                {kind => 'filter_choice', path => $path, attribute => 'label'},
            ),
            type => $present->{type},
            filter_choices => [map { {%$_} } @{$choice->{choices}}],
            conditional => {%$conditional},
            ((grep { !$domain->field_is_public($conditional->{$_}) }
                qw(when_field present_field absent_field)) ? (choices_only => 1) : ()),
            ($choice->{picker_hidden} ? (picker_hidden => 1) : ()),
        };
    }
    return \@catalog;
}

sub filter_map ($self, $domain, $rows_of = undef) {
    return {map { $_->{path} => { %$_ } } @{$self->filter_catalog($domain, $rows_of)}};
}

sub query_field_map ($self, $domain, $rows_of = undef) {
    my $cache_key = join "\x1f", 'query-field-map', $domain->fingerprint, $rows_of // '';
    my $cache = $self->{_catalog_cache};
    return $cache->{$cache_key} if ref($cache) eq 'HASH' && exists $cache->{$cache_key};
    my $map = {
        map { $_->{path} => { %$_ } }
        @{$self->field_catalog($domain, {include_internal => 1, rows_of => $rows_of})}
    };
    $cache->{$cache_key} = $map if ref($cache) eq 'HASH';
    return $map;
}

sub resolved_default_fields ($self, $domain, $rows_of = undef) {
    my $map = $self->detail_column_map($domain, undef, $rows_of);
    my @defaults = defined($rows_of)
        ? @{$self->_retarget_or_die($domain, $rows_of)->{default_selected}}
        : @{$self->default_fields // []};
    my @configured = grep { $map->{$_} } @defaults;
    return \@configured if @configured;
    my $catalog = [grep { !$_->{picker_hidden} }
        @{$self->field_catalog($domain, {rows_of => $rows_of})}];
    return [map { $_->{path} } @{$catalog}[0 .. _last_index($catalog, 6)]];
}

sub resolved_default_group ($self, $domain, $rows_of = undef) {
    my $map = $self->field_map($domain, $rows_of);
    my @configured = grep { $map->{$_} } @{$self->default_group // []};
    return \@configured if @configured;
    my $catalog = $self->field_catalog($domain, {rows_of => $rows_of});
    my ($first) = grep { $_->{type} !~ /\A(?:integer|decimal|number|float|boolean)\z/i }
        grep { !$_->{picker_hidden} } @$catalog;
    ($first) = grep { !$_->{picker_hidden} } @$catalog
        unless $first;
    $first //= $catalog->[0];
    return [$first->{path}];
}

sub measure ($self, $id, $domain = undef, $rows_of = undef) {
    my $measures = defined($domain)
        ? $self->measures_for_domain($domain, $rows_of) : $self->measures;
    for my $measure (@$measures) {
        return { %$measure } if $measure->{id} eq $id;
    }
    return undef;
}

sub measures_for_domain ($self, $domain, $rows_of = undef) {
    my $cache_key = join "\x1f", 'measures', $domain->fingerprint, $rows_of // '';
    my $cache = $self->{_catalog_cache};
    return $cache->{$cache_key} if ref($cache) eq 'HASH' && exists $cache->{$cache_key};
    my $fields = $self->field_map($domain, $rows_of);
    my @measures = map {
        my $measure = $_;
        my $source = defined($measure->{field}) ? $fields->{$measure->{field}} : undef;
        my $source_unit = ref($source) eq 'HASH' ? $source->{unit} : undef;
        my $unit = Selecto::Analytics::UnitRegistry->aggregate_unit(
            $source_unit, $measure->{aggregate},
        );
        +{
            %$measure,
            label => $self->localize(
                $domain, "measures.$measure->{id}.label", $measure->{label},
                {kind => 'measure', id => $measure->{id}, attribute => 'label'},
            ),
            type => defined($measure->{field}) ? $fields->{$measure->{field}}{type} : 'rows',
            curated => 1,
            (defined($source_unit) ? (source_unit => $source_unit) : ()),
            (ref($source) eq 'HASH' && defined($source->{behavior})
                ? (source_behavior => $source->{behavior}) : ()),
            (ref($source) eq 'HASH' && defined($source->{picker_group_label})
                ? (picker_group_label => $source->{picker_group_label}) : ()),
            (ref($source) eq 'HASH' && defined($source->{picker_group_key})
                ? (picker_group_key => $source->{picker_group_key}) : ()),
            (defined($unit) ? (unit => $unit) : ()),
        }
    } grep {
        !defined($_->{field}) || exists($fields->{$_->{field}})
    } @{$self->measures};
    my %seen = map { $_->{id} => 1 } @measures;
    unless (grep { !defined($_->{field}) && $_->{aggregate} eq 'count' } @measures) {
        push @measures, {
            id => '__row_count__',
            label => $self->localize(
                $domain, 'measures.row_count.label', 'Row count',
                {kind => 'measure', id => '__row_count__', attribute => 'label'},
            ),
            aggregate => 'count',
            type => 'rows', curated => 0, builtin => 1,
            unit => {kind => 'count'},
        };
        $seen{'__row_count__'} = 1;
    }
    for my $column (@{$self->field_catalog($domain, {rows_of => $rows_of})}) {
        my $id = $seen{$column->{path}} ? 'field:' . $column->{path} : $column->{path};
        my $aggregate = _default_measure_function($column->{type});
        my $unit = Selecto::Analytics::UnitRegistry->aggregate_unit(
            $column->{unit}, $aggregate,
        );
        push @measures, {
            id => $id,
            label => $column->{label},
            aggregate => $aggregate,
            field => $column->{path},
            type => $column->{type},
            curated => 0,
            ($column->{picker_hidden} ? (picker_hidden => 1) : ()),
            (defined($column->{picker_group_label})
                ? (picker_group_label => $column->{picker_group_label}) : ()),
            (defined($column->{picker_group_key})
                ? (picker_group_key => $column->{picker_group_key}) : ()),
            (defined($column->{unit}) ? (source_unit => $column->{unit}) : ()),
            (defined($column->{behavior})
                ? (source_behavior => $column->{behavior}) : ()),
            (defined($unit) ? (unit => $unit) : ()),
        };
        $seen{$id} = 1;
    }
    my $measures = \@measures;
    $cache->{$cache_key} = $measures if ref($cache) eq 'HASH';
    return $measures;
}

sub default_measure ($self, $domain, $rows_of = undef) {
    my $measures = $self->measures_for_domain($domain, $rows_of);
    return { %{$measures->[0]} };
}

sub measure_catalog ($self, $domain, $rows_of = undef) {
    return [map {
        my $measure = $_;
        {
            path => $measure->{id},
            label => $measure->{label},
            type => $measure->{type},
            field => $measure->{field},
            default_function => $measure->{aggregate},
            ($measure->{picker_hidden} ? (picker_hidden => 1) : ()),
            (defined($measure->{picker_group_label})
                ? (picker_group_label => $measure->{picker_group_label}) : ()),
            (defined($measure->{picker_group_key})
                ? (picker_group_key => $measure->{picker_group_key}) : ()),
            (defined($measure->{source_unit})
                ? (source_unit => $measure->{source_unit}) : ()),
            (defined($measure->{source_behavior})
                ? (source_behavior => $measure->{source_behavior}) : ()),
            (defined($measure->{unit}) ? (unit => $measure->{unit}) : ()),
        }
    } @{$self->measures_for_domain($domain, $rows_of)}];
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
        [true_percentage => 'Percent true'],
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
        [between => 'between'], [in => 'one of'], [not_in => 'not one of'],
        [is_null => 'is empty'], [not_null => 'is not empty'],
    ] if $self->numeric_type($type);
    return [
        [eq => 'equals'], [ne => 'does not equal'], [in => 'one of'],
        [not_in => 'not one of'],
        (($type // '') =~ /\A(?:string|text)\z/ ? (
            [text_contains_ci => 'contains (ignore case)'],
            [starts_with_ci => 'starts with (ignore case)'],
            [ends_with_ci => 'ends with (ignore case)'],
            [text_contains => 'contains (match case)'],
            [starts_with => 'starts with (match case)'],
            [ends_with => 'ends with (match case)'],
        ) : ()),
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

__END__

=head1 NAME

Selecto::Components::Config - Validated configuration for one Selecto explorer

=head1 SYNOPSIS

    use Selecto::Components::Config;

    my $config = Selecto::Components::Config->new(
        id             => 'products',
        title          => 'Products',
        path           => '/explore/products',
        engine_factory => sub ($c) { $engine },
        default_limit  => 50,
    );

    my $request_config = $config->for_request($c);
    my $catalog = $request_config->field_catalog($engine->domain);

=head1 DESCRIPTION

This class holds one explorer's options and validates them. Hosts normally
never construct it themselves: the L<Selecto::Components> plugin builds one
for each entry of its C<explorers> hash. It fills in C<id>, a default C<path>
and a default C<title>, and copies the plugin-level C<websocket_context>,
C<websocket_session_options> and C<lazy_view_controls> defaults.

Every option, with its default, range and callback signature, is documented
in L<Selecto::Components/EXPLORER OPTIONS>. C<new> dies with a
one-line message for any invalid value.

=head1 METHODS

The methods most useful to hosts and to code that works with an explorer
model (C<< $model->{config} >>) are listed here. Other methods serve the
renderer and may change.

=head2 new

    my $config = Selecto::Components::Config->new(%options);

Validates and returns the configuration. C<id>, C<title>, C<path> and
C<engine_factory> are required.

=head2 for_request

    my $request_config = $config->for_request($controller);

Returns a shallow copy bound to one request. The copy resolves the theme,
page shell, export permission and localized catalogs once and caches them.
L<Selecto::Components::Explorer/model> does this for you.

=head2 engine

    my $engine = $config->engine($controller);

Calls C<engine_factory> and checks that it returned a L<Selecto::Engine>.

=head2 export_allowed

    my $ok = $request_config->export_allowed;

Returns the C<export_authorizer> decision, or true without one. A request
copy asks once and remembers the answer.

=head2 query_params_enabled

    my $shareable = $config->query_params_enabled($domain);

False when the domain sets C<< components => {query_params => 0} >>.

=head2 field_catalog, filter_catalog, measure_catalog

    my $fields = $request_config->field_catalog($domain);

These return the localized, sorted pickers the UI offers: each entry has a
C<path>, a C<label> and a C<type>, plus presentation metadata.
C<< field_catalog($domain, {include_internal => 1}) >> adds internal fields.

=head2 localize

    my $text = $request_config->localize($domain, 'fields.unit_price.label', 'Unit price');

Runs the configured C<localizer> for one semantic term. See
L<Selecto::Components::I18N>.

=head2 localization_terms

    my $terms = $config->localization_terms($domain);

Lists every term this explorer can localize, including its title and curated
measures.

=head1 SECURITY-RELEVANT OPTIONS

=over 4

=item show_sql

Defaults to false. When true, every explorer response renders the Query Debug
panel with the generated SQL B<and its bound parameters>. Bound parameters
include the values of required predicates and scope filters, such as tenant
IDs, owner IDs and other row-level security inputs, as well as every filter
value a user typed. B<show_sql must be off in production.> Enable it only in
trusted development environments. The plugin logs a warning at registration
when an explorer enables it while the application runs in C<production> mode.

=item export_authorizer, max_export_rows

Decide who may export, and cap the size of every all-rows query.

=item action_authorizer

Required for any action that declares a C<capability>. Without it, such
actions stay hidden.

=back

=head1 SEE ALSO

L<Selecto::Components>, L<Selecto::Components::Explorer>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
