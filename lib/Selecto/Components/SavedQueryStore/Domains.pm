package Selecto::Components::SavedQueryStore::Domains;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json decode_json to_json);
use Selecto::Components::Util qw(decode_driver_json);
use Mojo::Util qw(b64_encode b64_decode);
use Mojo::URL ();
use Selecto::Error ();
use Scalar::Util qw(blessed);
use Selecto::Expression ();
use Selecto::Write ();
use Selecto::Components::SavedView ();
use Selecto::Components::InputBudget ();

has sources => sub { [] };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    die "sources must be a nonempty array\n" unless ref($self->sources) eq 'ARRAY' && @{$self->sources};
    my %seen;
    for my $source (@{$self->sources}) {
        die "source must be an object with a unique name and engine_factory\n"
            unless ref($source) eq 'HASH' && ($source->{name} // '') =~ /\A[a-z][a-z0-9_-]{0,159}\z/
                && !$seen{$source->{name}}++ && ref($source->{engine_factory}) eq 'CODE';
        my $fields = $source->{fields};
        die "source fields require name, url or state, and key\n"
            unless ref($fields) eq 'HASH' && $fields->{name} && ($fields->{url} || $fields->{state}) && $fields->{key};
        die "choose either url or state storage\n" if $fields->{url} && $fields->{state};
        die "state storage requires explorer_filter\n" if $fields->{state} && !$source->{explorer_filter};
        die "source field mappings must be identifiers\n" if grep {
            !defined($_) || ref($_) || !/\A[a-zA-Z_][a-zA-Z0-9_]*\z/
        } values %$fields;
        die "unknown source field mapping\n" if grep { !/\A(?:name|url|state|key|folder|parent|kind)\z/ } keys %$fields;
        die "source scope and target labels are required\n"
            unless defined($source->{scope}) && !ref($source->{scope}) && $source->{scope} =~ /\A[a-z][a-z0-9_-]{0,159}\z/
                && defined($source->{target_label}) && !ref($source->{target_label}) && length($source->{target_label});
        for my $callback (qw(write_check explorer_filter destinations list_url)) {
            die "$callback must be a callback\n" if exists($source->{$callback}) && ref($source->{$callback}) ne 'CODE';
        }
    }
    return $self;
}

sub _engine ($self, $source, $context, $config, $destination = undef) {
    my $engine = $destination
        ? $source->{engine_factory}->($context, $config, $source, $destination)
        : $source->{engine_factory}->($context, $config, $source);
    die "source engine_factory must return Selecto::Engine\n"
        unless blessed($engine) && $engine->isa('Selecto::Engine');
    die "saved-view sources cannot use DuckDB\n" if $engine->adapter->name eq 'duckdb';
    $engine->assert_tenant_boundary(access => 'read');
    my $domain = $engine->domain;
    for my $field (values %{$source->{fields}}) {
        die "source mapping names an unavailable field\n" unless $domain->fields->{$field};
    }
    die "source key must be the domain primary key\n" unless $source->{fields}{key} eq ($domain->primary_key // '');
    die "source must declare writes.row_revision\n" unless $domain->writes->{row_revision};
    return $engine;
}

sub _writable ($self, $source, $engine, $context, $config, $op, $row = undef) {
    return 0 if $source->{readonly};
    my $grant = $engine->domain->writes->{operations}{$op};
    return 0 unless ref($grant) eq 'HASH' && $grant->{enabled};
    # The host may narrow the domain's grants per destination or per row.
    # Only an explicit true result authorizes a callback-protected source.
    return 1 unless $source->{write_check};
    return $source->{write_check}->($context, $config, $op, $row, $engine, $source) ? 1 : 0;
}

sub _rows ($self, $source, $engine, $predicate = undef) {
    my %seen;
    my @fields = grep { !$seen{$_}++ } values %{$source->{fields}};
    # Paginate rather than silently truncating the saved-view menu.
    my @rows;
    my $offset = 0;
    while (1) {
        my $query = $engine->query->select(@fields)->order_by($source->{fields}{key})->limit(200)->offset($offset);
        $query = $query->where($predicate) if $predicate;
        my $result = $engine->all($query);
        for my $i (0 .. $#{$result->{rows}}) {
            my %row;
            @row{@{$result->{columns}}} = @{$result->{rows}[$i]};
            $row{row_revision} = $result->{row_revisions}[$i];
            push @rows, \%row;
        }
        last if @{$result->{rows}} < 200;
        $offset += 200;
    }
    return \@rows;
}

sub _belongs ($self, $source, $row, $context, $config) {
    return $source->{explorer_filter}->($row, $context, $config, $source) ? 1 : 0
        if $source->{explorer_filter};
    my $fields = $source->{fields};
    return 0 if $fields->{kind} && ($row->{$fields->{kind}} // '') ne ($source->{view_kind} // 'view');
    if ($fields->{state}) {
        # State columns cannot imply their owning Explorer; require a host
        # filter for them instead of mixing unrelated rows into the menu.
        return 0;
    }
    my $url = Mojo::URL->new($row->{$fields->{url}} // '');
    return Selecto::Components::SavedView::_local_view($config, $url);
}

sub _url ($self, $source, $row, $context, $config) {
    my $fields = $source->{fields};
    return $row->{$fields->{url}} if $fields->{url};
    my $state = decode_driver_json($row->{$fields->{state}});
    # Listing must retain unreadable shared selections. Do not run check here.
    my $url = Mojo::URL->new($config->path);
    $url->query([map { my $key = $_; map { ($key => $_) }
        ref($state->{$key}) eq 'ARRAY' ? @{$state->{$key}} : $state->{$key} } sort keys %$state]);
    return $url->to_string;
}

sub _id ($source, $key) {
    my $encoded = b64_encode(encode_json(["$key"]), '');
    $encoded =~ tr!+/!-_!;
    $encoded =~ s/=+\z//;
    return $source->{name} . '.' . $encoded;
}

# The old form contract carries a string. The native row_revision member
# retains its exact value; this envelope also transports null, empty and zero.
sub _revision ($value) { return 'rv1.' . b64_encode(encode_json([$value]), '') }

sub _identity ($self, $id) {
    _fail('FORBIDDEN', 'Choose a valid saved view.') unless defined($id) && !ref($id)
        && $id =~ /\A([a-z][a-z0-9_-]*)\.([A-Za-z0-9_-]+)\z/ && length($id) <= 4096;
    my ($name, $encoded) = ($1, $2);
    my ($source) = grep { $_->{name} eq $name } @{$self->sources};
    _fail('FORBIDDEN', 'Choose a valid saved view.') unless $source;
    $encoded =~ tr!-_!+/!;
    my $key = eval { decode_json(b64_decode($encoded)) };
    _fail('FORBIDDEN', 'Choose a valid saved view.') unless ref($key) eq 'ARRAY' && @$key == 1
        && defined($key->[0]) && !ref($key->[0]) && _id($source, $key->[0]) eq $id;
    return ($source, $key->[0]);
}

sub list ($self, $context, $config) {
    my @rows;
    for my $source (@{$self->sources}) {
        my $engine = $self->_engine($source, $context, $config);
        my $stored = $self->_rows($source, $engine);
        my $fields = $source->{fields};
        my %parents = map { $_->{$fields->{key}} => $_ } @$stored;
        for my $row (@$stored) {
            next unless $self->_belongs($source, $row, $context, $config);
            my %folder;
            if ($fields->{folder}) { %folder = (folder => $row->{$fields->{folder}}) }
            elsif ($fields->{parent} && defined(my $parent = $row->{$fields->{parent}})) {
                # The complete scoped read supplies labels, including parents
                # which the Explorer menu filter itself does not display.
                next unless exists $parents{$parent};
                next if $fields->{kind} && ($parents{$parent}{$fields->{kind}} // '') ne ($source->{folder_kind} // 'folder');
                %folder = (folder => $parents{$parent}{$fields->{name}});
            }
            my $url = $self->_url($source, $row, $context, $config);
            $url = $source->{list_url}->($url, $row, $context, $config, $source) if $source->{list_url};
            push @rows, {id => _id($source, $row->{$fields->{key}}),
                name => $row->{$fields->{name}}, url => $url,
                scope => $source->{scope}, revision => _revision($row->{row_revision}), row_revision => $row->{row_revision},
                (defined($source->{scope_label}) ? (scope_label => $source->{scope_label}) : ()),
                readonly => $self->_writable($source, $engine, $context, $config, 'update', $row)
                    && $self->_writable($source, $engine, $context, $config, 'delete', $row) ? 0 : 1,
                %folder,
                ($fields->{parent} ? (parent => $row->{$fields->{parent}}) : ())};
        }
    }
    return \@rows;
}

sub targets ($self, $context, $config) {
    my @targets;
    for my $source (@{$self->sources}) {
        my $engine = $self->_engine($source, $context, $config);
        if ($source->{destinations}) {
            for my $destination (@{$self->_destinations($source, $engine, $context, $config)}) {
                my $chosen = $self->_engine($source, $context, $config, $destination);
                push @targets, {id => "$source->{name}.$destination->{key}", label => $destination->{label}}
                    if $self->_writable($source, $chosen, $context, $config, 'insert');
            }
        } elsif ($self->_writable($source, $engine, $context, $config, 'insert')) {
            push @targets, {id => $source->{name}, label => $source->{target_label}};
        }
    }
    return \@targets;
}

sub _destinations ($self, $source, $engine, $context, $config) {
    my $destinations = $source->{destinations}->($context, $config, $source, $engine);
    die "destinations must return an array\n" unless ref($destinations) eq 'ARRAY';
    my %seen;
    for my $destination (@$destinations) {
        die "destination requires a unique key, label and values\n"
            unless ref($destination) eq 'HASH' && defined($destination->{key}) && !ref($destination->{key})
                && $destination->{key} =~ /\A[a-zA-Z0-9_-]{1,160}\z/ && !$seen{$destination->{key}}++
                && defined($destination->{label}) && !ref($destination->{label}) && length($destination->{label})
                && ref($destination->{values}) eq 'HASH';
        die "destination values must name declared root fields\n" if grep {
            !/\A[a-zA-Z_][a-zA-Z0-9_]*\z/ || !$engine->domain->fields->{$_}
        } keys %{$destination->{values}};
    }
    return $destinations;
}

sub save_new ($self, $context, $config, $request) {
    my $target = $request->{target};
    _fail('FORBIDDEN', 'This destination is not writable.') unless defined($target) && !ref($target);
    my ($source) = grep { $_->{destinations} ? index($target, "$_->{name}.") == 0 : $_->{name} eq $target } @{$self->sources};
    _fail('FORBIDDEN', 'This destination is not writable.') unless $source;
    my $destination;
    if ($source->{destinations}) {
        my $engine = $self->_engine($source, $context, $config);
        ($destination) = grep { "$source->{name}.$_->{key}" eq $target }
            @{$self->_destinations($source, $engine, $context, $config)};
        _fail('FORBIDDEN', 'This destination is not writable.') unless $destination;
    }
    return $self->_mutate($source, $context, $config, $request, 'insert', undef, $destination);
}

sub update ($self, $context, $config, $request) {
    my ($source, $key) = $self->_identity($request->{id});
    return $self->_mutate($source, $context, $config, $request, 'update', $key);
}

sub delete ($self, $context, $config, $request) {
    my ($source, $key) = $self->_identity($request->{id});
    return $self->_mutate($source, $context, $config, $request, 'delete', $key);
}

sub _mutate ($self, $source, $context, $config, $request, $operation, $key = undef, $destination = undef) {
    my $result;
    my $ok = eval {
        my $engine = $self->_engine($source, $context, $config, $destination);
        my $fields = $source->{fields};
        my $predicate = defined($key) ? Selecto::Expression->eq($fields->{key}, $key) : undef;
        my $row = $predicate ? $self->_rows($source, $engine, $predicate)->[0] : undef;
        _fail('STALE', 'This saved view no longer exists.') if $predicate && !$row;
        _fail('FORBIDDEN', 'This saved view is not writable.')
            if $row && !$self->_belongs($source, $row, $context, $config);
        _fail('FORBIDDEN', 'This destination or saved view is not writable.')
            unless $self->_writable($source, $engine, $context, $config, $operation, $row);
        my $has_revision = exists($request->{row_revision}) || exists($request->{revision});
        my $revision = exists($request->{row_revision}) ? $request->{row_revision} : $request->{revision};
        if (!exists($request->{row_revision}) && defined($revision) && !ref($revision) && $revision =~ /\Arv1\.(.+)\z/) {
            my $decoded = eval { decode_json(b64_decode($1)) };
            _fail('STALE', 'Read this saved view again before changing it.') unless ref($decoded) eq 'ARRAY' && @$decoded == 1;
            $revision = $decoded->[0];
        }
        _fail('STALE', 'Read this saved view again before changing it.')
            if $predicate && (!$has_revision || ref($revision));
        my %values;
        if ($operation ne 'delete') {
            my $checked = Selecto::Components::SavedView->check($config, $context, $request->{url} // $request->{state});
            Selecto::Error->throw('SAVED_QUERY_INVALID', 'The saved view is invalid.', {errors => $checked->{errors}})
                unless $checked->{ok};
            my $name = $request->{name};
            _fail('INVALID', 'Enter a valid saved-view name.')
                unless defined($name) && !ref($name) && $name =~ /\S/ && length($name) <= 255 && $name !~ /[\x00-\x1f\x7f]/;
            $values{$fields->{name}} = $name;
            if ($fields->{url}) { $values{$fields->{url}} = $checked->{url} }
            else { $values{$fields->{state}} = to_json(Mojo::URL->new($checked->{url})->query->to_hash) }
            if ($operation eq 'insert') {
                $values{$fields->{kind}} = $source->{view_kind} // 'view' if $fields->{kind};
                # Destination metadata comes only from the host callback.
                # Owner/actor fills still belong to the engine.
                if ($destination) {
                    for my $field (keys %{$destination->{values}}) {
                        _fail('FORBIDDEN', 'Destination cannot replace saved-view content.') if exists $values{$field};
                        my $value = $destination->{values}{$field};
                        my $binding = $engine->domain->writes->{host_bound_fields}{$field};
                        if ($binding) {
                            # Never manufacture a caller assignment for a
                            # host-bound field. Core fills it from the factory's
                            # trusted context; the destination must agree.
                            my $trusted = $engine->write_context->{$binding->{source}[1]};
                            _fail('FORBIDDEN', 'Destination requires trusted host context.')
                                unless defined($trusted) && !ref($trusted) && defined($value) && !ref($value)
                                    && "$trusted" eq "$value";
                        } else { $values{$field} = $value }
                    }
                } else {
                    for my $name (qw(folder parent)) {
                        $values{$fields->{$name}} = $request->{$name} if $fields->{$name} && exists($request->{$name});
                    }
                }
            }
        }
        if ($operation eq 'delete' && $fields->{parent}) {
            my $children = $self->_rows($source, $engine, Selecto::Expression->eq($fields->{parent}, $key));
            _fail('CONFLICT', 'This folder still has children.') if @$children;
        }
        my $command = Selecto::Write::Command->new(operation => $operation, relation => $engine->domain->table,
            assignments => \%values, ($predicate ? (predicate => $predicate) : ()),
            metadata => {returning => [$fields->{key}], ($predicate ? (row_revision => $revision) : ())});
        my $written = $engine->execute_write($command);
        my $returned = $written->values;
        my $saved_key = $key // $returned->{$fields->{key}};
        $result = {ok => 1, (defined($saved_key) ? (id => _id($source, $saved_key)) : ())};
        1;
    };
    _rethrow($@) unless $ok;
    return $result;
}

sub _fail ($code, $message) { die "SAVED_QUERY_$code: $message\n" }

sub _rethrow ($error) {
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    my $code = $error->code;
    _fail('CONFLICT', 'A saved view with this name already exists.') if $code eq 'database_unique_violation';
    _fail('CONFLICT', 'This folder still has children.') if $code eq 'database_foreign_key_violation';
    _fail('STALE', 'This saved view changed or no longer exists. Reload it and retry.')
        if $code =~ /\A(?:stale_revision|row_revision_required|invalid_row_revision)\z/;
    _fail('FORBIDDEN', 'This destination or saved view is not writable.')
        if $code =~ /\A(?:host_bound_field|missing_host_context|write_policy_missing|write_operation_not_enabled|write_field_not_writable|action_capability_denied|missing_capability_resolver|foreign_key_source_mismatch|cardinality_mismatch|tenant_mismatch|missing_tenant_scope)\z/;
    die $error;
}

1;

__END__

=head1 NAME

Selecto::Components::SavedQueryStore::Domains - Saved queries in governed domains

=head1 DESCRIPTION

Implements C<list>, C<targets>, C<save_new>, C<update> and C<delete> using
independent host-configured domain engine factories. See F<docs/saved-views.md>
for source configuration, revision transport and error mapping.

=head1 DESTINATIONS AND LISTING

An optional source C<destinations> callback receives
C<($context, $config, $source, $engine)> and returns an array of
C<{key, label, values}> objects. Keys are distinct ASCII letters, digits,
underscores or hyphens (1 to 160 characters). C<targets> exposes only
C<< <source>.<key> >> and the label. C<save_new> resolves the submitted id
against a fresh callback result, refusing absent targets as
C<SAVED_QUERY_FORBIDDEN>. Sources without the callback retain their single
source-name target and existing factory signature.

For destination inserts the engine factory receives the resolved object as a
fourth argument. It sets trusted write context for ownership and parent guards.
C<values> uses declared root field identifiers. Ordinary assignments pass
through governed insert grants and constraints. A host-bound value must match
the factory's trusted context; the store omits that assignment so core performs
the host fill. Request values never supply destination assignments or trusted
context. Name, URL/state and the generated view kind cannot be replaced by a
destination. Updates and deletes still use the ordinary scoped factory.

An optional C<list_url> callback receives
C<($url, $row, $context, $config, $source)> after Explorer filtering and returns
the listed URL. Listing never calls SavedView check and retains the stored
row's revision. With C<parent> mapped and C<folder> absent, a child receives
its visible parent's name as C<folder>. Missing/out-of-scope parents omit the
child; a mapped parent kind must equal C<folder_kind> (default C<folder>).
Parent visibility uses the full same-source read scope before menu filtering.

=cut
