package Selecto::Components::Templates::Renderer;

use 5.034;
use strict;
use warnings;
use B qw(SVp_IOK SVp_NOK SVp_POK svref_2object);
use Encode qw(encode_utf8);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Components::Util qw(html_escape);

sub render {
    my ($class, %args) = @_;
    my ($manifest, $snapshot, $registry, $context) = _render_input(%args);
    return join '', map {
        _render_region($_, $context, $registry)
    } @{$manifest->{view}{nodes}};
}

sub render_regions {
    my ($class, %args) = @_;
    my ($manifest, $snapshot, $registry, $context) = _render_input(%args);
    my $node_ids = $args{node_ids};
    _die('invalid_render_regions', 'template render regions are invalid')
        unless ref($node_ids) eq 'ARRAY' && @$node_ids <= 256;
    my %requested;
    for my $node_id (@$node_ids) {
        _die('invalid_render_regions', 'template render regions are invalid')
            unless defined($node_id) && !ref($node_id) && length($node_id)
            && length($node_id) <= 512 && !$requested{"$node_id"}++;
    }
    my %available = map { $_->{node_id} => $_ } @{$manifest->{view}{nodes}};
    _die('unknown_render_region', 'template render region is unavailable')
        if grep { !exists($available{$_}) } keys %requested;
    return [map {
        my $node = $_;
        my $region_id = _region_dom_id($context->{instance_id}, $node->{node_id});
        +{
            node_id => "$node->{node_id}",
            target => "#$region_id",
            html => _render_region($node, $context, $registry),
        }
    } grep { $requested{$_->{node_id}} } @{$manifest->{view}{nodes}}];
}

sub _render_input {
    my (%args) = @_;
    my $manifest = $args{manifest};
    my $snapshot = $args{snapshot};
    my $registry = $args{registry};
    _die('invalid_render_input', 'template render input is invalid')
        unless ref($manifest) eq 'HASH'
        && ref($manifest->{view}) eq 'HASH'
        && ($manifest->{view}{schema} // '') eq 'selecto.template.view.v1'
        && ref($manifest->{view}{nodes}) eq 'ARRAY'
        && ref($snapshot) eq 'HASH' && ref($registry) eq 'HASH';
    my $context = _render_context($snapshot, $manifest);
    my $slots = $args{slots} // {};
    _die('invalid_render_input', 'template slots are invalid')
        unless ref($slots) eq 'HASH'
        && !grep {
            ref($slots->{$_}) ne 'Selecto::Components::Templates::Renderer::SafeHTML'
        } keys %$slots;
    $context->{slots} = $slots;
    return ($manifest, $snapshot, $registry, $context);
}

sub _render_region {
    my ($node, $context, $registry) = @_;
    my $node_id = ref($node) eq 'HASH' ? $node->{node_id} : undef;
    _die('invalid_render_node', 'compiled render node is invalid', $node_id)
        unless defined($node_id) && length($node_id);
    my $region_id = _region_dom_id($context->{instance_id}, $node_id);
    return '<div id="' . html_escape($region_id) . '"' .
        ' data-selecto-template-node="' . html_escape($node_id) . '">' .
        _render_node($node, $context, $registry) . '</div>';
}

sub validate_manifest {
    my ($class, $manifest) = @_;
    return 1 unless ref($manifest) eq 'HASH'
        && ref($manifest->{view}) eq 'HASH'
        && ref($manifest->{view}{nodes}) eq 'ARRAY';
    my @pending = @{$manifest->{view}{nodes}};
    while (@pending) {
        my $node = shift @pending;
        next unless ref($node) eq 'HASH';
        if (($node->{kind} // '') eq 'element' && ref($node->{attributes}) eq 'HASH') {
            _validate_attribute_bindings($node->{attributes}, $node->{node_id});
        }
        for my $list (qw(children then else)) {
            push @pending, @{$node->{$list}} if ref($node->{$list}) eq 'ARRAY';
        }
        if (ref($node->{slots}) eq 'HASH') {
            push @pending, map { ref($_) eq 'ARRAY' ? @$_ : () }
                values %{$node->{slots}};
        }
    }
    return 1;
}

sub _validate_attribute_bindings {
    my ($attributes, $node_id) = @_;
    for my $name (sort keys %$attributes) {
        next unless _literal_only_attribute($name);
        my $value = $attributes->{$name};
        next if ref($value) eq 'HASH' && ($value->{kind} // '') eq 'literal';
        _die(
            'unsafe_attribute_binding',
            "element attribute $name only accepts a literal template value",
            $node_id,
        );
    }
}

sub _literal_only_attribute {
    my ($name) = @_;
    return 0 unless defined($name) && !ref($name);
    my $local = lc "$name";
    $local =~ s/\A.*://s;
    return $local =~ /\Aon/ || $local eq 'srcdoc' || $local eq 'style';
}

sub safe_html {
    my ($class, $html) = @_;
    _die('invalid_safe_html', 'safe HTML must be a scalar')
        if !defined($html) || ref($html);
    return Selecto::Components::Templates::Renderer::SafeHTML->new("$html");
}

sub _render_nodes {
    my ($nodes, $context, $registry) = @_;
    my $html = '';
    $html .= _render_node($_, $context, $registry) for @$nodes;
    return $html;
}

sub _render_node {
    my ($node, $context, $registry) = @_;
    my $node_id = ref($node) eq 'HASH' ? $node->{node_id} : undef;
    _die('invalid_render_node', 'compiled render node is invalid', $node_id)
        unless ref($node) eq 'HASH' && defined($node_id) && length($node_id);
    my $kind = $node->{kind} // '';
    if ($kind eq 'text') {
        _die('invalid_render_node', 'compiled text node is invalid', $node_id)
            if !defined($node->{value}) || ref($node->{value});
        return html_escape($node->{value});
    }
    if ($kind eq 'expression') {
        my $value = _resolve_value($node->{value}, $context, $node_id);
        return _display($value, $node_id);
    }
    if ($kind eq 'component') {
        _die('invalid_render_node', 'compiled component node is invalid', $node_id)
            unless defined($node->{name}) && ref($node->{props}) eq 'HASH'
            && ref($node->{events}) eq 'HASH' && ref($node->{children}) eq 'ARRAY';
        my $renderer = _registry_renderer(
            $registry, 'components', $node->{name}, $node_id,
        );
        my $props = _resolve_values($node->{props}, $context, $node_id);
        _validate_component_urls($props, $registry, $node->{name}, $node_id);
        return _invoke_renderer($renderer, {
            node_id => "$node_id",
            dom_id => _dom_id($context->{instance_id}, $node_id),
            name => "$node->{name}",
            props => $props,
            events => {%{$node->{events}}},
            children => __PACKAGE__->safe_html(
                _render_nodes($node->{children}, $context, $registry),
            ),
        }, $node_id);
    }
    if ($kind eq 'element') {
        _die('invalid_render_node', 'compiled element node is invalid', $node_id)
            unless defined($node->{name}) && ref($node->{attributes}) eq 'HASH'
            && ref($node->{children}) eq 'ARRAY';
        _validate_attribute_bindings($node->{attributes}, $node_id);
        my $renderer = _registry_renderer(
            $registry, 'elements', $node->{name}, $node_id,
        );
        my $attributes = _resolve_values($node->{attributes}, $context, $node_id);
        _validate_url_attributes($attributes, $node_id);
        return _invoke_renderer($renderer, {
            node_id => "$node_id",
            dom_id => _dom_id($context->{instance_id}, $node_id),
            name => "$node->{name}",
            attributes => $attributes,
            children => __PACKAGE__->safe_html(
                _render_nodes($node->{children}, $context, $registry),
            ),
        }, $node_id);
    }
    if ($kind eq 'condition') {
        _die('invalid_render_node', 'compiled condition node is invalid', $node_id)
            unless ref($node->{then}) eq 'ARRAY' && ref($node->{else}) eq 'ARRAY';
        my $test = _resolve_value($node->{test}, $context, $node_id);
        _die('render_type_mismatch', 'condition is not boolean', $node_id)
            unless JSON::PP::is_bool($test);
        return _render_nodes(
            $test ? $node->{then} : $node->{else}, $context, $registry,
        );
    }
    if ($kind eq 'slot') {
        _die('invalid_render_node', 'compiled slot node is invalid', $node_id)
            unless defined($node->{name}) && !ref($node->{name})
            && ref($node->{children}) eq 'ARRAY';
        return "$context->{slots}{$node->{name}}"
            if exists $context->{slots}{$node->{name}};
        return _render_nodes($node->{children}, $context, $registry);
    }
    if ($kind eq 'include') {
        _die('invalid_render_node', 'compiled include node is invalid', $node_id)
            unless defined($node->{template}) && length($node->{template})
            && ref($node->{bindings}) eq 'HASH';
        my $renderer = $registry->{include};
        _die('unavailable_include_renderer', 'include renderer is unavailable', $node_id)
            unless ref($renderer) eq 'CODE';
        return _render_include($node, $context, $registry, $renderer);
    }
    _die('invalid_render_node', 'compiled render node is invalid', $node_id);
}

sub _render_include {
    my ($node, $context, $registry, $renderer) = @_;
    my $node_id = $node->{node_id};
    my $fills = $node->{slots} // {};
    _die('invalid_render_node', 'compiled slots are invalid', $node_id)
        unless ref($fills) eq 'HASH';
    my %slots;
    for my $name (keys %$fills) {
        _die('invalid_render_node', 'compiled slots are invalid', $node_id)
            unless ref($fills->{$name}) eq 'ARRAY';
        $slots{$name} = __PACKAGE__->safe_html(
            _render_nodes($fills->{$name}, $context, $registry),
        );
    }
    my %source_bindings = map {
        my $value = $node->{bindings}{$_};
        ref($value) eq 'HASH' && ($value->{kind} // '') eq 'binding'
            && ($value->{type} // '') eq 'source'
            ? ($_ => $value) : ()
    } keys %{$node->{bindings}};
    if (!%source_bindings) {
        my $assigns = {
            node_id => "$node_id",
            dom_id => _dom_id($context->{instance_id}, $node_id),
            template => "$node->{template}",
            bindings => _resolve_values($node->{bindings}, $context, $node_id),
        };
        $assigns->{slots} = \%slots if %slots;
        return _invoke_renderer($renderer, $assigns, $node_id);
    }

    my $source;
    my %relationships;
    for my $name (keys %source_bindings) {
        my $expression = $source_bindings{$name}{expression};
        _die('render_type_mismatch', 'include source binding is invalid', $node_id)
            unless defined($expression) && !ref($expression);
        my ($candidate, $relationship);
        if ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\z/) {
            $candidate = $1;
        }
        elsif ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\z/
            && $2 ne 'rows') {
            ($candidate, $relationship) = ($1, $2);
        }
        _die('render_type_mismatch', 'include source binding is invalid', $node_id)
            unless defined($candidate) && exists($context->{sources}{$candidate});
        _die('render_type_mismatch', 'include source bindings are incompatible', $node_id)
            if defined($source) && $source ne $candidate;
        $source = $candidate;
        $relationships{$name} = $relationship;
    }

    my %fixed = map {
        $_ => _resolve_value($node->{bindings}{$_}, $context, $node_id)
    } grep { !exists($source_bindings{$_}) } keys %{$node->{bindings}};
    my $rows = $context->{sources}{$source};
    return '' unless defined $rows;
    _die('render_type_mismatch', 'include source rows are invalid', $node_id)
        unless ref($rows) eq 'ARRAY';

    my $html = '';
    for my $index (0 .. $#$rows) {
        my $row = $rows->[$index];
        _die('render_type_mismatch', 'include source row is invalid', $node_id)
            unless ref($row) eq 'HASH';
        my %resolved = %fixed;
        for my $name (keys %relationships) {
            my $value = defined($relationships{$name})
                ? $row->{$relationships{$name}} : $row;
            _die('render_type_mismatch', 'include relationship is not an object', $node_id)
                if defined($value) && ref($value) ne 'HASH';
            $resolved{$name} = $value;
        }
        my $item_id = "$node_id.row.$index";
        my $assigns = {
            node_id => $item_id,
            dom_id => _dom_id($context->{instance_id}, $item_id),
            template => "$node->{template}", bindings => \%resolved,
        };
        $assigns->{slots} = \%slots if %slots;
        $html .= _invoke_renderer($renderer, $assigns, $item_id);
    }
    return $html;
}

sub _render_context {
    my ($snapshot, $manifest) = @_;
    _die('invalid_render_snapshot', 'template snapshot is invalid')
        unless defined($snapshot->{instance_id}) && length($snapshot->{instance_id})
        && ref($snapshot->{inputs}) eq 'HASH'
        && ref($snapshot->{state}) eq 'HASH'
        && ref($snapshot->{sources}) eq 'HASH';
    my %sources = map {
        my $source = $snapshot->{sources}{$_};
        my $result = ref($source) eq 'HASH' ? $source->{result} : undef;
        $_ => _public_rows($result);
    } keys %{$snapshot->{sources}};
    my %source_totals = map {
        my $source = $snapshot->{sources}{$_};
        my $result = ref($source) eq 'HASH' ? $source->{result} : undef;
        $_ => (ref($result) eq 'HASH' ? $result->{totals} : undef);
    } keys %{$snapshot->{sources}};
    my %source_ready = map {
        my $source = $snapshot->{sources}{$_};
        $_ => (ref($source) eq 'HASH' && ($source->{status} // '') eq 'ready');
    } keys %{$snapshot->{sources}};
    my %source_page_sizes = map {
        $_->{id} => $_->{query}{limit}
    } @{$manifest->{sources} // []};
    return {
        instance_id => "$snapshot->{instance_id}",
        inputs => $snapshot->{inputs},
        state => $snapshot->{state},
        sources => \%sources,
        source_totals => \%source_totals,
        source_ready => \%source_ready,
        source_page_sizes => \%source_page_sizes,
    };
}

sub _public_rows {
    my ($result) = @_;
    return $result if ref($result) eq 'ARRAY';
    return $result->{rows}
        if ref($result) eq 'HASH'
        && ref($result->{rows}) eq 'ARRAY'
        && (!exists($result->{pages}) || ref($result->{pages}) eq 'ARRAY');
    return undef;
}

sub _resolve_values {
    my ($values, $context, $node_id) = @_;
    my %resolved = map {
        $_ => _resolve_value($values->{$_}, $context, $node_id)
    } keys %$values;
    return \%resolved;
}

sub _validate_url_attributes {
    my ($attributes, $node_id) = @_;
    my %url_names = map { $_ => 1 }
        qw(href src poster action formaction xlink:href);
    for my $name (keys %$attributes) {
        next unless $url_names{$name};
        _die('invalid_url_attribute', 'element URL attribute is invalid', $node_id)
            unless _valid_url($name, $attributes->{$name});
    }
}

sub _validate_component_urls {
    my ($props, $registry, $component, $node_id) = @_;
    my $policies = $registry->{url_props};
    return unless defined $policies;
    _die('invalid_render_input', 'component URL policy is invalid', $node_id)
        unless ref($policies) eq 'HASH';
    my $policy = $policies->{$component};
    return unless defined $policy;
    _die('invalid_render_input', 'component URL policy is invalid', $node_id)
        unless ref($policy) eq 'HASH';
    my %url_names = map { $_ => 1 }
        qw(href src poster action formaction xlink:href);
    for my $prop (keys %$policy) {
        my $attribute = $policy->{$prop};
        _die('invalid_render_input', 'component URL policy is invalid', $node_id)
            unless defined($attribute) && !ref($attribute) && $url_names{$attribute};
        next unless exists $props->{$prop};
        _die('invalid_url_attribute', 'component URL prop is invalid', $node_id)
            unless _valid_url($attribute, $props->{$prop});
    }
}

sub _valid_url {
    my ($name, $value) = @_;
    return 1 unless defined $value;
    return 0 if ref($value) || !length($value)
        || length(encode_utf8("$value")) > 2048
        || $value =~ /[\x00-\x20\x7F\\]/;
    return 1 if $value =~ m{\A/(?!/)};
    return 1 if ($name eq 'href' || $name eq 'xlink:href')
        && $value =~ /\A[?#].+/s;
    return 1 if $name eq 'href' && $value =~ /\A(?:mailto|tel):.+/s;
    return 0 if $name eq 'action' || $name eq 'formaction';
    if ($value =~ m{\Ahttps?://([^/?#]+)(?:[/?#].*)?\z}s) {
        my $authority = $1;
        return $authority !~ /@/
            && $authority =~ /\A(?:[A-Za-z0-9]|\[)[A-Za-z0-9.:\-\[\]]*\z/;
    }
    return 0;
}

sub _resolve_value {
    my ($value, $context, $node_id) = @_;
    _die('invalid_render_value', 'compiled render value is invalid', $node_id)
        unless ref($value) eq 'HASH';
    my $kind = $value->{kind} // '';
    my $type = $value->{type} // '';
    if ($kind eq 'literal' && exists($value->{value})) {
        _die('render_type_mismatch', 'literal render value has the wrong type', $node_id)
            unless _value_matches_type($value->{value}, $type);
        return $value->{value};
    }
    if ($kind eq 'binding' && defined($value->{expression})) {
        my $resolved = _resolve_expression($value->{expression}, $context, $node_id);
        _die('render_type_mismatch', 'bound render value has the wrong type', $node_id)
            if defined($resolved) && !_value_matches_type($resolved, $type);
        return $resolved;
    }
    _die('invalid_render_value', 'compiled render value is invalid', $node_id);
}

sub _resolve_expression {
    my ($expression, $context, $node_id) = @_;
    _die('unsupported_expression', 'render expression is not supported', $node_id)
        if !defined($expression) || ref($expression);
    if ($expression =~ /\Apresent\((.*)\)\z/) {
        return defined(_resolve_expression($1, $context, $node_id))
            ? JSON::PP::true : JSON::PP::false;
    }
    if ($expression =~ /\Astate\.([A-Za-z_][A-Za-z0-9_]*)\z/) {
        return _resolve_member($context->{state}, $1, $node_id);
    }
    if ($expression =~ /\Ainput\.([A-Za-z_][A-Za-z0-9_]*)\z/) {
        return _resolve_member($context->{inputs}, $1, $node_id);
    }
    if ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.rows\z/
        && exists($context->{sources}{$1})) {
        return $context->{sources}{$1};
    }
    if ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.ready\z/
        && exists($context->{source_ready}{$1})) {
        return $context->{source_ready}{$1}
            ? JSON::PP::true : JSON::PP::false;
    }
    if ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.page_size\z/
        && exists($context->{source_page_sizes}{$1})) {
        my $size = $context->{source_page_sizes}{$1};
        _die('unsupported_expression', 'render expression is not supported', $node_id)
            unless defined($size) && !ref($size) && "$size" =~ /\A[1-9][0-9]*\z/;
        return 0 + $size;
    }
    if ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.totals\.([A-Za-z_][A-Za-z0-9_]*)\z/
        && exists($context->{source_totals}{$1})) {
        my ($source, $total) = ($1, $2);
        my $totals = $context->{source_totals}{$source};
        return $totals->{$total}
            if ref($totals) eq 'HASH' && exists($totals->{$total});
        _die('unsupported_expression', 'render expression is not supported', $node_id)
            if $context->{source_ready}{$source};
        return undef;
    }
    if ($expression =~ /\A([A-Za-z_][A-Za-z0-9_]*)(?:\.(.+))?\z/
        && exists($context->{inputs}{$1})) {
        my ($input, $path) = ($1, $2);
        return $context->{inputs}{$input} unless defined $path;
        return _resolve_path($context->{inputs}{$input}, [split /\./, $path]);
    }
    _die('unsupported_expression', 'render expression is not supported', $node_id);
}

sub _resolve_member {
    my ($values, $name, $node_id) = @_;
    _die('unsupported_expression', 'render expression is not supported', $node_id)
        unless exists $values->{$name};
    return $values->{$name};
}

sub _resolve_path {
    my ($value, $path) = @_;
    for my $segment (@$path) {
        return undef unless ref($value) eq 'HASH';
        $value = $value->{$segment};
    }
    return $value;
}

sub _registry_renderer {
    my ($registry, $group, $name, $node_id) = @_;
    my $renderers = $registry->{$group};
    my $renderer = ref($renderers) eq 'HASH' ? $renderers->{$name} : undef;
    _die('unavailable_renderer', 'host renderer is unavailable', $node_id)
        unless ref($renderer) eq 'CODE';
    return $renderer;
}

sub _invoke_renderer {
    my ($renderer, $assigns, $node_id) = @_;
    my $result = eval { $renderer->($assigns) };
    _die('renderer_failed', 'host renderer failed', $node_id) if $@;
    _die('unsafe_renderer_output', 'host renderer must return explicit safe HTML', $node_id)
        unless blessed($result)
        && $result->isa('Selecto::Components::Templates::Renderer::SafeHTML');
    return $result->value;
}

sub _display {
    my ($value, $node_id) = @_;
    return '' unless defined $value;
    return html_escape($value ? 'true' : 'false') if JSON::PP::is_bool($value);
    return html_escape($value) unless ref($value);
    _die('invalid_display_value', 'render expression is not scalar', $node_id);
}

sub _value_matches_type {
    my ($value, $type) = @_;
    return 1 if $type eq 'any';
    return JSON::PP::is_bool($value) if $type eq 'boolean';
    return _integer($value) if $type eq 'integer';
    return ref($value) eq 'ARRAY' if $type eq 'rows';
    return _string($value) if $type eq 'string';
    return 0;
}

sub _integer {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value);
    my $flags = svref_2object(\$value)->FLAGS;
    return !!($flags & (SVp_IOK | SVp_NOK)) && "$value" =~ /\A-?[0-9]+\z/;
}

sub _string {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value);
    return !!(svref_2object(\$value)->FLAGS & SVp_POK);
}

sub _dom_id {
    my ($instance_id, $node_id) = @_;
    return 'selecto-template-' . _encode_dom_part($instance_id) . '-' .
        _encode_dom_part($node_id);
}

sub _region_dom_id {
    my ($instance_id, $node_id) = @_;
    return _dom_id($instance_id, $node_id) . '-region';
}

sub _encode_dom_part {
    my ($value) = @_;
    return join '', map {
        ($_ >= 48 && $_ <= 57) || ($_ >= 65 && $_ <= 90)
            || ($_ >= 97 && $_ <= 122) || $_ == 95
            ? chr($_) : sprintf('-%02X', $_)
    } unpack 'C*', "$value";
}

sub _die {
    my ($code, $message, $node_id) = @_;
    my $path = defined($node_id) && length($node_id) ? " at view.$node_id" : '';
    die "$code: $message$path\n";
}

package Selecto::Components::Templates::Renderer::SafeHTML;

use 5.034;
use strict;
use warnings;
use overload '""' => sub { ${$_[0]} }, fallback => 1;

sub new {
    my ($class, $value) = @_;
    return bless \$value, $class;
}

sub value { return ${$_[0]}; }

1;
