package Selecto::Components::CannedPage;

use Mojo::Base -base, -signatures;
use Mojo::Util qw(xml_escape);
use Mojo::JSON qw(decode_json encode_json);
use Scalar::Util qw(blessed);
use Selecto::CannedPage ();
use Selecto::Error ();
use Selecto::Components::Renderer ();
use Selecto::Components::Renderer::Results ();
use Selecto::Components::Config ();
use Selecto::Components::Util qw(humanize);

has [qw(page engine_factory scope_factory path title)];

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    die "canned page must be a Selecto::CannedPage\n"
        unless blessed($self->page) && $self->page->isa('Selecto::CannedPage');
    die "canned page needs an engine_factory\n" unless ref($self->engine_factory) eq 'CODE';
    die "canned page scope_factory must be a coderef\n"
        if defined($self->scope_factory) && ref($self->scope_factory) ne 'CODE';
    die "canned page path is invalid\n"
        unless defined($self->path) && $self->path =~ m{\A/(?!/)[A-Za-z0-9/_-]+\z};
    return $self;
}

sub handle ($self, $controller) {
    my $domain = $self->page->domain;
    my $public = ($domain->components->{query_params} // 1) ? 1 : 0;
    $controller->res->headers->cache_control('no-store') unless $public;
    if (!$public && $controller->req->method eq 'GET'
        && length($controller->req->url->query->to_string)) {
        return $controller->redirect_to($self->path);
    }
    my ($result, $error);
    eval {
        my $engine = $self->engine_factory->($controller);
        my $scope = $self->scope_factory
            ? $self->scope_factory->($controller, $engine) : undef;
        $result = $self->page->run($engine, $self->_input($controller), $scope);
        1;
    } or $error = $@ || 'Canned page execution failed';
    if ($error) {
        $controller->app->log->error("Selecto canned page failed: $error");
        my $invalid = blessed($error) && $error->can('code')
            && $error->code eq 'invalid_canned_page';
        return $controller->render(
            text => $invalid ? 'Invalid page selection' : 'Page data is unavailable',
            status => $invalid ? 422 : 500,
        );
    }
    return $controller->render(data => $self->_html($result, $public),
        format => 'html', status => 200);
}

sub handle_websocket ($self, $controller) {
    $controller->on(message => sub ($socket, $message) {
        return $socket->finish(1009 => 'WebSocket message is too large')
            if !defined($message) || length($message) > 131_072;
        my $payload = eval { decode_json($message) };
        return $socket->finish(1003 => 'Expected a JSON form')
            unless ref($payload) eq 'HASH';
        my $request_id = $payload->{selecto_request_id};
        return $socket->finish(1003 => 'Invalid request id')
            unless defined($request_id) && !ref($request_id)
                && "$request_id" =~ /\A[0-9]{1,12}\z/;
        my $result;
        my $ok = eval {
            my $engine = $self->engine_factory->($socket);
            my $scope = $self->scope_factory
                ? $self->scope_factory->($socket, $engine) : undef;
            $result = $self->page->run($engine, $self->_input($socket, $payload), $scope);
            1;
        };
        unless ($ok) {
            $socket->app->log->error("Selecto canned page WebSocket failed: $@");
            my $invalid = blessed($@) && $@->can('code')
                && $@->code eq 'invalid_canned_page';
            my $code = $invalid ? 1003 : 1011;
            my $reason = $invalid ? 'Invalid page selection'
                : 'Page request could not be completed';
            return $socket->finish($code => $reason);
        }
        my $public = ($self->page->domain->components->{query_params} // 1) ? 1 : 0;
        return $socket->send({text => encode_json({
            content => $self->_surface($result, $public),
            target => '#selecto-page-' . $self->page->id,
            swap => 'outerHTML',
            selecto => {request_id => "$request_id"},
        })});
    });
}

sub _input ($self, $controller, $payload = undef) {
    my $get = sub ($name) {
        return defined($payload) ? $payload->{$name} : $controller->param($name);
    };
    my $submitted = defined($get->('submitted'));
    return {} unless $submitted;
    my (%filters, %facet_search);
    for my $control (@{$self->page->controls}) {
        my $id = $control->{id};
        if ($control->{kind} eq 'facet') {
            my $values = defined($payload) ? $payload->{"f_$id"}
                : $controller->every_param("f_$id");
            $filters{$id} = !defined($values) ? []
                : ref($values) eq 'ARRAY' ? [@$values] : [$values];
            if ($control->{values}{searchable}) {
                $facet_search{$id} = $get->("facet_search_$id") // '';
            }
        } elsif ($control->{kind} eq 'range') {
            my %range;
            for my $bound (qw(min max)) {
                my $value = $get->("f_${id}_$bound");
                $range{$bound} = $value if defined($value) && length($value);
            }
            $filters{$id} = \%range;
        } else {
            $filters{$id} = $get->("f_$id") // '';
        }
    }
    my $drilldown;
    my $clicked = defined($get->('drilldown_select'));
    my $drilldown_json = $clicked ? $get->('drilldown_select') : $get->('drilldown');
    if (!$get->('clear_drilldown') && defined($drilldown_json)
        && length($drilldown_json)) {
        $drilldown = eval { decode_json($drilldown_json) };
        Selecto::Error->throw('invalid_canned_page', 'invalid drilldown')
            unless ref($drilldown) eq 'HASH';
    }
    my ($detail) = grep { $_->{kind} eq 'detail' } @{$self->page->views};
    return {
        view => $clicked && $detail ? $detail->{id} : $get->('view'),
        page => $clicked ? 1 : $get->('page') // 1,
        limit => $get->('limit') // 25,
        filters => \%filters,
        facet_search => \%facet_search,
        (defined($drilldown) ? (drilldown => $drilldown) : ()),
    };
}

sub _html ($self, $result, $public) {
    my $title = _escape($self->title // $self->page->id);
    return Selecto::Components::Renderer->page_document(
        title => $title, channel_id => 'selecto-page-channel-' . $self->page->id,
        ws_path => $self->path . '/ws', surface => $self->_surface($result, $public),
        include_explorer_script => 0,
        extra_head_html => '<link rel="stylesheet" href="/selecto-components/canned-page.css">' .
            '<script defer src="/selecto-components/canned-page.js"></script>',
    );
}

sub _surface ($self, $result, $public) {
    my $state = $result->{state};
    my $title = _escape($self->title // $self->page->id);
    my $path = _escape($self->path);
    my $id = _escape($self->page->id);
    my $method = $public ? 'get' : 'post';
    my $html = qq{<section id="selecto-page-$id" class="sc-surface selecto-canned-page">};
    $html .= qq{<header class="sc-hero"><div class="sc-hero-heading"><h1>$title</h1></div>};
    $html .= $public ? qq{<div class="sc-hero-actions"><a class="sc-button sc-secondary" href="$path">Reset</a></div>}
        : '<div class="sc-hero-actions"><span class="sc-private-mode">Private URL mode</span></div>';
    $html .= '</header><div class="sc-workspace">';
    $html .= qq{<aside class="sc-builder selecto-canned-controls"><form method="$method" action="$path" hx-ws:send hx-trigger="submit"><input type="hidden" name="submitted" value="1">};
    $html .= qq{<input type="hidden" name="limit" value="$state->{limit}">};
    if ($state->{drilldown}) {
        $html .= '<input type="hidden" name="drilldown" value="'
            . _escape(encode_json($state->{drilldown})) . '">';
        $html .= '<p class="sc-note">Showing matching detail rows from ' . _escape($state->{drilldown}{view})
            . '.</p><button class="sc-button sc-secondary" type="submit" name="clear_drilldown" value="1">Clear drilldown</button>';
    }
    $html .= '<p class="sc-eyebrow">Views and filters</p>';
    $html .= '<label for="selecto-page-view">View</label><select id="selecto-page-view" name="view">';
    for my $view (@{$self->page->views}) {
        my $selected = $view->{id} eq $state->{view} ? ' selected' : '';
        $html .= '<option value="' . _escape($view->{id}) . '"' . $selected . '>'
            . _escape($view->{label} // $view->{id}) . '</option>';
    }
    $html .= '</select>';
    for my $control (@{$self->page->controls}) {
        my $id = $control->{id};
        my $name = _escape("f_$id");
        my $label = _escape($control->{label} // $id);
        my $value = $state->{filters}{$id};
        if ($control->{kind} eq 'facet') {
            $html .= '<fieldset><legend>' . $label . '</legend>';
            if ($control->{values}{searchable}) {
                $html .= '<label>Find ' . $label . ' options <input type="search" name="'
                    . _escape("facet_search_$id") . '" value="'
                    . _escape($state->{facet_search}{$id} // '') . '"></label>';
            }
            my %selected = map { $_ => 1 } @{$value // []};
            for my $option (@{$result->{facets}{$id}{options}}) {
                my $raw = defined($option->{value}) ? "$option->{value}" : '';
                my $checked = $selected{$raw} ? ' checked' : '';
                my $caption = defined($option->{label}) ? $option->{label} : '(missing)';
                $html .= '<label><input type="checkbox" name="' . $name
                    . '" value="' . _escape($raw) . '"' . $checked . '>'
                    . _escape($caption) . ' <span>(' . _escape($option->{count})
                    . ')</span></label> ';
            }
            $html .= '<p>More values are available.</p>' if $result->{facets}{$id}{truncated};
            $html .= '</fieldset>';
        } elsif ($control->{kind} eq 'range') {
            $html .= '<fieldset><legend>' . $label . '</legend>';
            for my $bound (qw(min max)) {
                $html .= '<label>' . ucfirst($bound) . ' <input type="number" name="'
                    . _escape("f_${id}_$bound") . '" value="'
                    . _escape($value->{$bound} // '') . '"></label> ';
            }
            $html .= '</fieldset>';
        } else {
            $html .= '<label>' . $label . ' <input type="search" name="' . $name
                . '" value="' . _escape($value // '') . '"></label>';
        }
    }
    $html .= '<div class="selecto-canned-actions"><button class="sc-button sc-primary" type="submit" name="page" value="1">Apply filters</button> ';
    $html .= '<a class="sc-button sc-secondary" href="' . $path . '">Reset</a></div>';
    $html .= '</form></aside><section class="sc-results selecto-canned-results" aria-label="Search results">';
    $html .= '<div class="sc-result-meta"><div><h2>' .
        _escape(Selecto::Components::Renderer::Results->heading_for_view($result->{view}{kind})) .
        '</h2></div><div><strong>' . _escape($result->{total}) .
        ' matching items</strong></div></div>';
    $html .= qq{<form method="$method" action="$path" hx-ws:send>} . $self->_hidden_state($state);
    $html .= $self->_table($result);
    $html .= '</form>';
    my $previous = $state->{page} - 1;
    my $next = $state->{page} + 1;
    $html .= qq{<nav class="sc-pagination sc-pagination-bottom" aria-label="Results pages"><span>Page $state->{page}</span><form method="$method" action="$path" hx-ws:send>} . $self->_hidden_state($state);
    $html .= qq{<button class="sc-page-direction" type="submit" name="page" value="$previous">Previous</button>}
        if $previous >= 1;
    $html .= qq{ <button class="sc-page-direction" type="submit" name="page" value="$next">Next</button>}
        if $result->{has_more};
    return $html . '</form></nav></section></div></section>';
}

sub _hidden_state ($self, $state) {
    my $html = '<input type="hidden" name="submitted" value="1"><input type="hidden" name="view" value="' .
        _escape($state->{view}) . '"><input type="hidden" name="limit" value="' .
        _escape($state->{limit}) . '">';
    for my $control (@{$self->page->controls}) {
        my $value = $state->{filters}{$control->{id}};
        my $name = 'f_' . $control->{id};
        if ($control->{kind} eq 'facet') {
            $html .= '<input type="hidden" name="' . _escape($name) . '" value="' . _escape($_) . '">'
                for @{$value // []};
            $html .= '<input type="hidden" name="facet_search_' . _escape($control->{id}) .
                '" value="' . _escape($state->{facet_search}{$control->{id}} // '') . '">'
                if $control->{values}{searchable};
        } elsif ($control->{kind} eq 'range') {
            for my $bound (qw(min max)) {
                $html .= '<input type="hidden" name="' . _escape("${name}_$bound") .
                    '" value="' . _escape($value->{$bound}) . '">'
                    if defined($value->{$bound});
            }
        } else {
            $html .= '<input type="hidden" name="' . _escape($name) . '" value="' .
                _escape($value // '') . '">';
        }
    }
    $html .= '<input type="hidden" name="drilldown" value="' . _escape(encode_json($state->{drilldown})) . '">'
        if $state->{drilldown};
    return $html;
}

sub _table ($self, $result) {
    my ($view) = grep { $_->{id} eq $result->{state}{view} } @{$self->page->views};
    my $label_config = Selecto::Components::Config->new(
        id => $self->page->id, title => $self->title // $self->page->id,
        path => $self->path, engine_factory => $self->engine_factory,
    );
    my $field_labels = $label_config->field_map($self->page->domain);
    my $selections = $view->{query}->selections;
    my @columns = map {
        my $selection = $selections->[$_];
        my $path = $selection && $selection->kind eq 'field'
            ? $selection->arguments->[0] : undef;
        my $label = defined($path) && $field_labels->{$path}
            ? $field_labels->{$path}{label}
            : humanize($selection && $selection->alias_name
                ? $selection->alias_name : $result->{columns}[$_]);
        +{key => "column_$_", label => $label,
            measure => $view->{kind} eq 'aggregate' && $_ >= @{$view->{query}->groups} ? 1 : 0}
    } 0 .. $#{$result->{columns}};
    my @records = map {
        my %record;
        @record{map { "column_$_" } 0 .. $#{$_}} = @{$_};
        \%record;
    } @{$result->{rows}};
    my $table = {columns => \@columns, records => \@records};
    if ($view->{kind} eq 'aggregate') {
        my $group_count = @{$view->{query}->groups};
        $table->{extra_column} = {label => 'Details', cell => sub ($record, $index) {
            my @values = map { $record->{"column_$_"} } 0 .. $group_count - 1;
            return '<button class="sc-button sc-secondary" type="submit" name="drilldown_select" value="' .
                _escape(encode_json({view => $result->{state}{view}, values => \@values})) .
                '">Show matching items</button>';
        }};
    }
    return Selecto::Components::Renderer::Results->_table($table, {bulk_actions => []});
}

sub _escape ($value) { xml_escape(defined($value) ? "$value" : '') }

1;
