package Selecto::Components::Templates::AuthoringPreview;

use 5.034;
use strict;
use warnings;
use Encode qw(encode_utf8);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Templates ();
use Selecto::Components::Templates::Renderer ();
use Selecto::Components::Util qw(html_escape);

# This host accepts synthetic fixtures and public contracts only. It has no
# query executor, adapter, operation dispatcher, or application credentials.
sub new {
    my ($class, %args) = @_;
    return bless {registrations => $args{registrations} // _builtins()}, $class;
}

sub _selected {
    my ($self, $locks) = @_;
    my %selected;
    for my $kind (qw(components elements)) {
        for my $name (keys %{$locks ? $locks->{$kind} // {} : $self->{registrations}{$kind} // {}}) {
            my $installed = $self->{registrations}{$kind}{$name};
            my $version = $locks ? $locks->{$kind}{$name}{version}
                : $installed->{default} // $installed->{version};
            my $entry = $installed && ($installed->{versions} ? $installed->{versions}{$version}
                : ($installed->{version} // '') eq ($version // '') ? $installed : undef);
            _fail('unavailable_native_component', "Perl has no installed $name version " . ($version // '')) unless $entry;
            die "invalid installed preview component\n" unless ref($entry->{render}) eq 'CODE'
                && ref($entry->{contract}) eq 'HASH' && $version =~ /\A\d+\.\d+\.\d+\z/;
            $selected{$kind}{$name} = {%$entry, version => $version, targets => $entry->{targets} // ['elixir', 'perl']};
        }
    }
    return \%selected;
}

sub registrations {
    my ($self, $selected) = @_;
    $selected //= $self->_selected;
    return {map {
        my $kind = $_;
        $kind => {map {
            my $name = $_;
            my $entry = $selected->{$kind}{$name};
            $name => {version => $entry->{version}, contract => $entry->{contract},
                targets => [sort @{$entry->{targets}}],
                fingerprint => Selecto::Templates->fingerprint($entry->{contract})}
        } sort keys %{$selected->{$kind} // {}}}
    } qw(components elements)};
}

sub observe {
    my ($self, $request) = @_;
    my $result = {schema => 'selecto.template.authoring-observation.v1', runtime => 'perl',
        implementation_version => $Selecto::Templates::VERSION, ok => JSON::PP::false};
    eval {
        _request($request);
        my $selected = $self->_selected($request->{registrations});
        my $registrations = $self->registrations($selected);
        if ($request->{registrations}) {
            _fail('native_component_contract_mismatch', 'Pinned native renderer metadata differs from the installed implementation')
                unless Selecto::Templates->fingerprint($request->{registrations}) eq Selecto::Templates->fingerprint($registrations);
        }
        $result->{registrations} = $registrations;
        _check_contracts($request->{capabilities}, $registrations);
        my %domains = map { $_ => Selecto::Domain->parse($request->{domains}{$_}, strict => 1) }
            keys %{$request->{domains}};
        my $document = _document($request->{source});
        $result->{ast} = $document->{ast};
        $result->{source_fingerprint} = Selecto::Templates->fingerprint($document);
        $result->{formatted} = Selecto::Templates->format($document);
        my %raw;
        for my $id (sort keys %{$request->{templates} // {}}) {
            my $child = _document($request->{templates}{$id});
            $raw{$id} = Selecto::Templates->compile($child,
                domains => \%domains, capabilities => $request->{capabilities});
            _fail('template_identity_mismatch', 'Included source name differs from its catalog key')
                unless $raw{$id}{template}{name} eq $id;
        }
        my $manifest = Selecto::Templates->compile($document,
            domains => \%domains, capabilities => $request->{capabilities}, included_manifests => \%raw);
        my %dependencies = map {$_ => Selecto::Templates->compose_includes(
            manifest => $raw{$_}, included_manifests => \%raw,
            domains => \%domains, capabilities => $request->{capabilities})} keys %raw;
        $result->{manifest} = $manifest;
        $result->{dependencies} = \%dependencies;
        my $snapshot = _snapshot($manifest, $request->{samples}, $request->{inputs} // {}, 'studio-layout-preview');
        $result->{snapshot} = $snapshot;
        $result->{html} = $self->_render($manifest, $snapshot, \%dependencies, $request->{samples}, {}, 0, $selected);
        $result->{ok} = JSON::PP::true;
        1;
    } or do {
        my $error = $@;
        $result->{diagnostic} = blessed($error) && $error->can('as_hash') ? $error->as_hash
            : ref($error) eq 'HASH' ? $error
            : {code => 'preview_failed', message => 'The Perl preview could not render this artifact.'};
    };
    return $result;
}

sub _render {
    my ($self, $manifest, $snapshot, $dependencies, $samples, $slots, $depth, $selected) = @_;
    _fail('preview_depth_limit', 'Preview include nesting exceeds 16 levels') if $depth > 16;
    my $registry = {map {
        my $kind = $_;
        $kind => {map {$_ => $selected->{$kind}{$_}{render}}
            keys %{$selected->{$kind} // {}}}
    } qw(components elements)};
    $registry->{include} = sub {
        my ($node) = @_;
        my $child = $dependencies->{$node->{template}};
        _fail('missing_include', 'The included preview artifact is unavailable') unless $child;
        my $state = _snapshot($child, $samples, $node->{bindings}, $node->{dom_id});
        return _safe($self->_render($child, $state, $dependencies, $samples, $node->{slots} // {}, $depth + 1, $selected));
    };
    return Selecto::Components::Templates::Renderer->render(
        manifest => $manifest, snapshot => $snapshot, registry => $registry, slots => $slots);
}

sub _snapshot {
    my ($manifest, $samples, $inputs, $instance) = @_;
    my $observation = Selecto::Templates->mount_runtime($manifest,
        instance_id => $instance, release_id => $manifest->{template}{fingerprint}, inputs => $inputs);
    my $snapshot = $observation->{snapshot};
    for my $effect (@{$observation->{effects}}) {
        _fail('preview_effect_unavailable', 'This preview only supplies synthetic read results')
            unless $effect->{kind} eq 'load_source';
        my ($source) = grep {$_->{id} eq $effect->{source}} @{$manifest->{sources}};
        my $rows = $samples->{$source->{domain}} // [];
        # Fixtures already describe the public result shape. No SQL or authored
        # ordering, filtering, pagination, or application authority is simulated.
        $observation = Selecto::Templates->complete_runtime($manifest, $snapshot, {
            schema => 'selecto.template.runtime-completion.v1',
            instance_id => $instance, release_id => $snapshot->{release_id},
            effect_id => $effect->{effect_id}, source => $effect->{source},
            generation => $effect->{generation}, outcome => 'ok', result => $rows,
        });
        $snapshot = $observation->{snapshot};
    }
    return $snapshot;
}

sub _request {
    my ($request) = @_;
    _fail('invalid_preview_request', 'Expected public contracts and synthetic preview data')
        unless ref($request) eq 'HASH'
        && ($request->{schema} // '') eq 'selecto.template.authoring-request.v1'
        && ref($request->{domains}) eq 'HASH' && ref($request->{capabilities}) eq 'HASH'
        && ref($request->{samples}) eq 'HASH'
        && ref($request->{templates} // {}) eq 'HASH' && ref($request->{inputs} // {}) eq 'HASH';
    my %allowed = map {$_ => 1} qw(schema source domains capabilities samples templates inputs registrations);
    _fail('invalid_preview_request', 'Unknown preview request field') if grep {!$allowed{$_}} keys %$request;
    _fail('preview_catalog_limit', 'The preview catalog is too large')
        if keys(%{$request->{domains}}) > 32 || keys(%{$request->{templates} // {}}) > 32
        || length(encode_utf8(JSON::PP->new->canonical->encode($request))) > 1_048_576;
    for my $rows (values %{$request->{samples}}) {
        _fail('preview_fixture_limit', 'Each synthetic fixture must contain at most 100 rows')
            unless ref($rows) eq 'ARRAY' && @$rows <= 100 && !grep {ref($_) ne 'HASH'} @$rows;
    }
}

sub _document {
    my ($source) = @_;
    _fail('source_too_large', 'Template source must be UTF-8 text of at most 64 KiB')
        if !defined($source) || ref($source) || length(encode_utf8($source)) > 65_536;
    my $document = Selecto::Templates->parse($source);
    my @pending = map {[$_, 0]} @{$document->{tree}};
    my $count = 0;
    while (@pending) {
        my ($node, $depth) = @{pop @pending};
        _fail('authoring_structure_limit', 'The syntax tree exceeds the authoring limits')
            if ++$count > 2048 || $depth > 32;
        push @pending, map {[$_, $depth + 1]} @{$node->{children} // []};
    }
    return $document;
}

sub _check_contracts {
    my ($capabilities, $installed) = @_;
    for my $kind (qw(components elements)) {
        my $requested = $capabilities->{renderer}{$kind};
        _fail('invalid_capabilities', 'A renderer contract is required') unless ref($requested) eq 'HASH';
        for my $name (keys %$requested) {
            my $entry = $installed->{$kind}{$name};
            _fail('unavailable_native_component', "Perl has no installed $kind renderer named $name") unless $entry;
            my %targets = map {$_ => 1} @{$entry->{targets}};
            _fail('native_only_component', "Renderer $name is not portable") unless $targets{elixir} && $targets{perl};
            _fail('native_component_contract_mismatch', "Perl renderer $name has a different typed contract")
                unless Selecto::Templates->fingerprint($requested->{$name}) eq $entry->{fingerprint};
        }
    }
}

sub _builtins {
    my $empty = {props => {}, required_props => [], events => {}, children => JSON::PP::true};
    my $table = {props => {rows => 'rows'}, required_props => ['rows'], events => {}, children => JSON::PP::false};
    my $elements = {attributes => {}, children => JSON::PP::true};
    return {
        components => {
            Card => {version => '1.0.0', contract => $empty, render => sub {
                return _safe('<section class="card">' . $_[0]{children} . '</section>');
            }},
            OrderTable => {version => '1.0.0', contract => $table, render => sub {
                my ($node) = @_;
                my $html = '<table aria-label="Synthetic purchase orders"><thead><tr><th>ID</th><th>Order</th><th>Status</th></tr></thead><tbody>';
                for my $row (@{$node->{props}{rows}}) {
                    $html .= '<tr>' . join('', map {'<td>' . html_escape($row->{$_} // '') . '</td>'} qw(id order_number status)) . '</tr>';
                }
                return _safe($html . '</tbody></table>');
            }},
        },
        elements => {map {
            my $name = $_;
            $name => {version => '1.0.0', contract => $elements, render => sub {
                return _safe("<$name>" . $_[0]{children} . "</$name>");
            }}
        } qw(h2 p div span strong)},
    };
}

sub _safe { Selecto::Components::Templates::Renderer->safe_html($_[0]) }
sub _fail { die {code => $_[0], message => $_[1]} }

1;
