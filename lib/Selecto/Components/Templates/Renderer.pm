package Selecto::Components::Templates::Renderer;

use 5.034;
use strict;
use warnings;
use B qw(SVp_IOK SVp_NOK SVp_POK svref_2object);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Components::Util qw(html_escape);

sub render {
    my ($class, %args) = @_;
    my $manifest = $args{manifest};
    my $snapshot = $args{snapshot};
    my $registry = $args{registry};
    _die('invalid_render_input', 'template render input is invalid')
        unless ref($manifest) eq 'HASH'
        && ref($manifest->{view}) eq 'HASH'
        && ($manifest->{view}{schema} // '') eq 'selecto.template.view.v1'
        && ref($manifest->{view}{nodes}) eq 'ARRAY'
        && ref($snapshot) eq 'HASH' && ref($registry) eq 'HASH';
    my $context = _render_context($snapshot);
    return _render_nodes($manifest->{view}{nodes}, $context, $registry);
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
        return _invoke_renderer($renderer, {
            node_id => "$node_id",
            dom_id => _dom_id($context->{instance_id}, $node_id),
            name => "$node->{name}",
            props => _resolve_values($node->{props}, $context, $node_id),
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
        my $renderer = _registry_renderer(
            $registry, 'elements', $node->{name}, $node_id,
        );
        return _invoke_renderer($renderer, {
            node_id => "$node_id",
            dom_id => _dom_id($context->{instance_id}, $node_id),
            name => "$node->{name}",
            attributes => _resolve_values($node->{attributes}, $context, $node_id),
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
    if ($kind eq 'include') {
        _die('invalid_render_node', 'compiled include node is invalid', $node_id)
            unless defined($node->{template}) && length($node->{template})
            && ref($node->{bindings}) eq 'HASH';
        my $renderer = $registry->{include};
        _die('unavailable_include_renderer', 'include renderer is unavailable', $node_id)
            unless ref($renderer) eq 'CODE';
        return _invoke_renderer($renderer, {
            node_id => "$node_id",
            dom_id => _dom_id($context->{instance_id}, $node_id),
            template => "$node->{template}",
            bindings => _resolve_values($node->{bindings}, $context, $node_id),
        }, $node_id);
    }
    _die('invalid_render_node', 'compiled render node is invalid', $node_id);
}

sub _render_context {
    my ($snapshot) = @_;
    _die('invalid_render_snapshot', 'template snapshot is invalid')
        unless defined($snapshot->{instance_id}) && length($snapshot->{instance_id})
        && ref($snapshot->{inputs}) eq 'HASH'
        && ref($snapshot->{state}) eq 'HASH'
        && ref($snapshot->{sources}) eq 'HASH';
    my %sources = map {
        my $source = $snapshot->{sources}{$_};
        $_ => ref($source) eq 'HASH' ? $source->{result} : undef;
    } keys %{$snapshot->{sources}};
    return {
        instance_id => "$snapshot->{instance_id}",
        inputs => $snapshot->{inputs},
        state => $snapshot->{state},
        sources => \%sources,
    };
}

sub _resolve_values {
    my ($values, $context, $node_id) = @_;
    my %resolved = map {
        $_ => _resolve_value($values->{$_}, $context, $node_id)
    } keys %$values;
    return \%resolved;
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
