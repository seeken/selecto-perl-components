package Selecto::Components::DomainCatalog;

use Mojo::Base -base, -signatures;
use Mojo::File ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Components::AssetManifest qw(asset_revision);
use Selecto::Components::Config ();
use Selecto::Components::I18N ();
use Selecto::Components::Renderer ();
use Selecto::Components::ThemeStylesheet ();
use Selecto::Components::Util qw(html_escape);

has path => '/catalog';
has title => 'Domain catalog';
has [qw(catalog catalog_resolver domain_links_resolver domain_columns_resolver
    baselines_resolver localizer label_domain theme_resolver)];

sub mount ($class, $app, %options) {
    my $routes = delete($options{routes}) // $app->routes;
    my $self = $class->new(%options);
    die "catalog path must be an absolute path without a trailing slash\n"
        unless !ref($self->path) && $self->path =~ m{\A/[A-Za-z0-9/_-]*[A-Za-z0-9_-]\z};
    die "catalog title must be text\n" unless defined($self->title) && !ref($self->title);
    die "provide catalog or catalog_resolver\n"
        unless defined($self->catalog) != defined($self->catalog_resolver);
    _catalog($self->catalog) if defined $self->catalog;
    for my $key (qw(catalog_resolver domain_links_resolver domain_columns_resolver baselines_resolver localizer theme_resolver)) {
        die "$key must be a coderef\n" if defined($self->$key) && ref($self->$key) ne 'CODE';
    }
    my $lib = Mojo::File->new(__FILE__)->to_abs->dirname->dirname->dirname;
    my ($public) = grep { -d $_ } ($lib->dirname->child('public'),
        $lib->child('auto', 'share', 'dist', 'Selecto-Components', 'public'));
    die "packaged browser assets were not found\n" unless $public;
    unshift @{$app->static->paths}, "$public" unless grep { "$_" eq "$public" } @{$app->static->paths};
    Selecto::Components::ThemeStylesheet->install_route($app, 'explorer');
    # Both pages use the exact mount path. IDs and baselines are query values,
    # so arbitrary catalog IDs never become route patterns or path segments.
    $routes->get($self->path)->to(cb => sub ($c) {
        return $c->render(text => 'Method not allowed', status => 405)
            unless $c->req->method eq 'GET';
        $c->res->headers->cache_control('no-store');
        my $catalog = $self->catalog_resolver ? _catalog($self->catalog_resolver->($c)) : $self->catalog;
        return $self->_handle($c, $catalog);
    });
    return $self;
}

sub _catalog ($catalog) {
    die "catalog must be a Selecto::DomainCatalog\n"
        unless blessed($catalog) && $catalog->isa('Selecto::DomainCatalog');
    return $catalog;
}

sub _h ($value) { return html_escape(defined($value) ? $value : '') }
sub _json ($value) { return JSON::PP->new->canonical->pretty->encode($value) }
sub _text ($value) { return defined($value) && !ref($value) }
sub _url ($self, $c, %query) {
    return $c->req->url->clone->query(\%query)->to_string;
}
sub _t ($self, $c, $domain, $key, $default) {
    return _h(Selecto::Components::I18N->localize($self->localizer,
        $domain // $self->label_domain, "catalog.$key", $default, {controller => $c}));
}
sub _links ($self, $c, $entry) {
    return '' unless $self->domain_links_resolver;
    my $raw = $self->domain_links_resolver->($c, $entry);
    my $links = Selecto::Components::Config::header_link_list($raw, 'domain_links_resolver');
    my $html = '';
    for my $i (0 .. $#$links) {
        my $kind = $raw->[$i]{kind} // '';
        die "domain link kind must be an identifier\n" unless _text($kind) && $kind =~ /\A[a-z_-]*\z/;
        $html .= '<a data-sc-link-kind="' . _h($kind) . '" href="' . _h($links->[$i]{href}) . '">' . _h($links->[$i]{label}) . '</a> ';
    }
    return $html;
}
sub _columns ($self, $c) {
    return [] unless $self->domain_columns_resolver;
    my $columns = $self->domain_columns_resolver->($c);
    die "domain_columns_resolver must return column definitions\n" unless ref($columns) eq 'ARRAY';
    my %seen;
    for my $column (@$columns) {
        die "catalog column requires a unique id, label and value callback\n"
            unless ref($column) eq 'HASH' && _text($column->{id}) && $column->{id} =~ /\A[a-z][a-z0-9_]*\z/
                && !$seen{$column->{id}}++ && _text($column->{label}) && ref($column->{value}) eq 'CODE';
    }
    return $columns;
}
sub _baselines ($self, $c, $entry) {
    return [] unless $self->baselines_resolver;
    my $items = $self->baselines_resolver->($c, $entry);
    die "baselines_resolver must return a list\n" unless ref($items) eq 'ARRAY';
    my %seen;
    for my $item (@$items) {
        die "baseline requires a unique id, label and earlier document or fingerprint\n"
            unless ref($item) eq 'HASH' && _text($item->{id}) && $item->{id} =~ /\A[a-z][a-z0-9_-]*\z/
                && !$seen{$item->{id}}++ && _text($item->{label})
                && (ref($item->{against}) eq 'HASH' || (_text($item->{against}) && length($item->{against})));
    }
    return $items;
}

sub _handle ($self, $c, $catalog) {
    my $id = $c->param('domain');
    my ($body, $domain, $heading);
    if (defined $id) {
        my ($entry) = grep { $_->{id} eq $id } @{$catalog->list};
        return $c->render(text => 'Domain not found', status => 404) unless $entry;
        my $baselines = $self->_baselines($c, $entry);
        my %report_options;
        my $against = $c->param('against') // '';
        if (length $against) {
            my ($choice) = grep { $_->{id} eq $against } @$baselines;
            # A retained fingerprint can also be pasted directly. Documents
            # only come from the host resolver, never from request JSON.
            return $c->render(text => 'Unknown comparison', status => 400)
                unless $choice || $against =~ /\A(?:sha256:)?[a-f0-9]{64}\z/;
            $report_options{against} = $choice ? $choice->{against} : $against;
        }
        my $report = eval { $catalog->report($id, %report_options) };
        return $c->render(text => 'Comparison unavailable', status => 400) unless $report;
        $domain = eval { $catalog->get($id) };
        $heading = $entry->{name} // $id;
        $body = $self->_detail($c, $catalog, $entry, $report, $domain, $baselines, $against);
    } else {
        $heading = $self->title;
        $body = $self->_list($c, $catalog);
    }
    my $theme = $self->theme_resolver ? $self->theme_resolver->($c, $self) : {};
    $theme //= {};
    die "theme_resolver must return an object\n" unless ref($theme) eq 'HASH';
    my $scheme = $theme->{scheme} // '';
    die "theme scheme must be light or dark\n" unless _text($scheme) && $scheme =~ /\A(?:light|dark)?\z/;
    my $html = Selecto::Components::Renderer->page_document(
        title => _h($heading), main_class => 'sc-page sc-catalog', channel_id => 'selecto-domain-catalog',
        scheme_attribute => length($scheme) ? ' data-sc-color-scheme="' . _h($scheme) . '"' : '',
        theme_stylesheet => Selecto::Components::ThemeStylesheet->href('explorer', $theme),
        extra_head_html => '<link rel="stylesheet" href="/selecto-components/domain-catalog.css?v=' . asset_revision() . '">',
        surface => '<div class="sc-surface">' . $body . '</div>',
    );
    return $c->render(text => $html, format => 'html');
}

sub _list ($self, $c, $catalog) {
    my $t = sub ($key, $default) { $self->_t($c, undef, $key, $default) };
    my $q = $c->param('q') // '';
    my $kind = $c->param('source') // '';
    my $status = $c->param('status') // '';
    my $columns = $self->_columns($c);
    my $html = '<header class="sc-catalog-heading"><div><p class="sc-catalog-eyebrow">Selecto</p><h1>' . _h($self->title) . '</h1><p>'
        . $t->('intro', 'Inspect domain contracts and static validation reports.') . '</p></div><span class="sc-catalog-badge">'
        . $t->('read_only', 'Read only') . '</span></header>';
    $html .= '<form method="get" class="sc-catalog-filters"><label>' . $t->('search', 'Search')
        . '<input type="search" name="q" value="' . _h($q) . '"></label>';
    for my $filter (['source', 'Source kind', $kind, [qw(code file store)]],
        ['status', 'Report status', $status, [qw(ok warning refused changed)]]) {
        $html .= '<label>' . $t->($filter->[0], $filter->[1]) . '<select name="' . $filter->[0] . '"><option value="">' . $t->('all', 'All') . '</option>';
        for my $value (@{$filter->[3]}) {
            $html .= '<option value="' . $value . '"' . ($filter->[2] eq $value ? ' selected' : '') . '>' . $t->($value, ucfirst($value)) . '</option>';
        }
        $html .= '</select></label>';
    }
    $html .= '<button type="submit">' . $t->('filter', 'Filter') . '</button></form>';
    my @reports = grep {
        my $entry = $_->{entry};
        (!length($kind) || $entry->{source}{kind} eq $kind)
            && (!length($status) || $_->{status} eq $status || $_->{validation_status} eq $status)
            && (!length($q) || index(lc(join(' ', map { $entry->{$_} // '' } qw(name id adapter version fingerprint))
                . ' ' . _json($entry->{source})), lc($q)) >= 0)
    } @{$catalog->report_all};
    $html .= '<p role="status">' . scalar(@reports) . ' ' . $t->('domains', 'domains') . '</p><div class="sc-catalog-table" tabindex="0" role="region" aria-label="'
        . $t->('domains', 'Domains') . '"><table><thead><tr>';
    $html .= join '', map { '<th scope="col">' . $t->(@$_) . '</th>' }
        (['name','Domain'], ['id','ID'], ['source','Source'], ['version','Version'], ['fingerprint','Fingerprint'], ['adapter','Adapter'], ['status','Report status'], ['links','Host links']);
    $html .= join '', map { '<th scope="col">' . _h($_->{label}) . '</th>' } @$columns;
    $html .= '</tr></thead><tbody>';
    for my $report (@reports) {
        my $e = $report->{entry};
        my @cells = ('<a href="' . _h($self->_url($c, domain => $e->{id})) . '">' . _h($e->{name} // $e->{id}) . '</a>',
            _h($e->{id}), _h($e->{source}{kind}) . '<small>' . _h(_json($e->{source}{ref})) . '</small>', _h($e->{version}),
            '<code title="' . _h($e->{fingerprint}) . '">' . _h(substr($e->{fingerprint} // '', 0, 16)) . '</code>', _h($e->{adapter}),
            '<span class="sc-catalog-badge">' . $t->($report->{status}, ucfirst($report->{status})) . '</span>'
                . ($report->{status} eq 'changed' ? '<small>' . $t->($report->{validation_status}, ucfirst($report->{validation_status})) . '</small>' : ''),
            $self->_links($c, $e));
        for my $column (@$columns) {
            my $value = $column->{value}->($c, $e);
            die "catalog column value must be text\n" if defined($value) && ref($value);
            push @cells, _h($value);
        }
        $html .= '<tr>' . join('', map { '<td>' . $_ . '</td>' } @cells) . '</tr>';
    }
    $html .= '</tbody></table></div>';
    $html .= '<p>' . $t->('empty', 'No domains match these filters.') . '</p>' unless @reports;
    return $html;
}

sub _section ($title, $value) {
    return '<section class="sc-catalog-section"><h2>' . $title . '</h2><pre>' . _h(_json($value)) . '</pre></section>';
}
sub _detail ($self, $c, $catalog, $entry, $report, $domain, $baselines, $against) {
    my $t = sub ($key, $default) { $self->_t($c, $domain, $key, $default) };
    my $html = '<nav><a href="' . _h($self->_url($c)) . '">' . $t->('back', 'All domains') . '</a></nav>'
        . '<header class="sc-catalog-heading"><div><p class="sc-catalog-eyebrow">' . _h($entry->{id}) . '</p><h1>' . _h($entry->{name} // $entry->{id})
        . '</h1><p>' . $self->_links($c, $entry) . '</p></div><span class="sc-catalog-badge">' . $t->($report->{status}, ucfirst($report->{status})) . '</span></header>';
    $html .= '<section class="sc-catalog-section"><h2>' . $t->('identity', 'Current identity and source') . '</h2><dl class="sc-catalog-identity">';
    for my $item (['id', 'ID', $entry->{id}], ['version', 'Version', $entry->{version}],
        ['fingerprint', 'Fingerprint', $entry->{fingerprint}], ['adapter', 'Adapter', $entry->{adapter}],
        ['source', 'Source kind', $entry->{source}{kind}]) {
        $html .= '<div><dt>' . $t->($item->[0], $item->[1]) . '</dt><dd>' . _h($item->[2]) . '</dd></div>';
    }
    for my $key (sort keys %{$entry->{source}{ref}}) {
        $html .= '<div><dt>' . _h($key) . '</dt><dd>' . _h($entry->{source}{ref}{$key}) . '</dd></div>';
    }
    $html .= '</dl></section>';
    $html .= '<section class="sc-catalog-section"><h2>' . $t->('checks', 'Report checks') . '</h2><ul class="sc-catalog-checks">';
    for my $check (@{$report->{checks}}) {
        $html .= '<li><strong>' . _h($check->{stage}) . ' · ' . _h($check->{status}) . '</strong><p>' . _h($check->{message})
            . '</p><code>' . _h($check->{path}) . '</code><small>' . _h($check->{code}) . '</small></li>';
    }
    $html .= '</ul></section><section class="sc-catalog-section"><h2>' . $t->('diff', 'Structural diff') . '</h2>';
    $html .= '<p>' . $t->('diff_note', 'Changes compare an earlier declaration with the current source. They do not decide compatibility or privileges.') . '</p>';
    $html .= '<form method="get" class="sc-catalog-filters"><input type="hidden" name="domain" value="' . _h($entry->{id})
        . '"><label>' . $t->('baseline', 'Earlier fingerprint or baseline ID') . '<input name="against" list="sc-catalog-baselines" value="' . _h($against) . '"></label>'
        . '<datalist id="sc-catalog-baselines">' . join('', map { '<option value="' . _h($_->{id}) . '">' . _h($_->{label}) . '</option>' } @$baselines)
        . '</datalist><button type="submit">' . $t->('compare', 'Compare') . '</button></form>';
    if (defined $report->{diff}) {
        my $count = 0;
        $html .= '<ul class="sc-catalog-changes">';
        for my $surface (sort keys %{$report->{diff}}) {
            for my $change (qw(added removed changed)) {
                for my $item (@{$report->{diff}{$surface}{$change}}) {
                    ++$count;
                    $html .= '<li><strong>' . _h($surface) . ' · ' . $t->($change, ucfirst($change)) . ': ' . _h($item->{name})
                        . '</strong><code>' . _h($item->{path}) . '</code>'
                        . join('', map { '<small>' . _h($_) . '</small>' } @{$item->{changes} // []}) . '</li>';
                }
            }
        }
        $html .= '</ul>';
        $html .= '<p>' . $t->('no_changes', 'No structural changes.') . '</p>' unless $count;
    } else {
        $html .= '<p>' . $t->('no_diff', 'No comparison is available. Choose a retained fingerprint or a host baseline.') . '</p>';
    }
    $html .= '</section>';
    unless ($domain) {
        return $html . '<p role="status">' . $t->('unavailable', 'The served contract is unavailable. See the report checks above.') . '</p>';
    }
    my $raw = $catalog->document($entry->{id});
    my $document = JSON::PP->new->decode($raw);
    $html .= '<section class="sc-catalog-section"><h2>' . $t->('served', 'Served contract') . '</h2><p>'
        . $t->('pinned_note', 'A pinned contract can differ from the current source reported above.') . '</p><code>' . _h($domain->fingerprint) . '</code></section>';
    $html .= '<section class="sc-catalog-section"><h2>' . $t->('fields', 'Fields') . '</h2><div class="sc-catalog-table" tabindex="0" role="region" aria-label="'
        . $t->('fields', 'Fields') . '"><table><thead><tr>';
    $html .= join '', map { '<th scope="col">' . $t->(@$_) . '</th>' } (['field','Field'],['type','Type'],['label','Label'],['description','Description'],['hidden','Hidden'],['internal','Internal'],['redacted','Redacted']);
    $html .= '</tr></thead><tbody>';
    my $walk;
    $walk = sub ($relation, $prefix) {
        for my $field (sort keys %{$relation->fields}) {
            my $name = length($prefix) ? "$prefix.$field" : $field;
            my $meta = $domain->field_metadata($name);
            my $label = Selecto::Components::I18N->localize($self->localizer, $domain,
                "fields.$name.label", $meta->{label} // '', {controller => $c});
            my $description = Selecto::Components::I18N->localize($self->localizer, $domain,
                "fields.$name.description", $meta->{description} // '', {controller => $c});
            $html .= '<tr>' . join('', map { '<td>' . _h($_) . '</td>' }
                ($name, $meta->{type} // $relation->fields->{$field}, $label, $description))
                . join('', map { '<td>' . $t->($meta->{$_} ? 'yes' : 'no', $meta->{$_} ? 'Yes' : 'No') . '</td>' } qw(hidden internal redacted)) . '</tr>';
        }
        my $associations = $relation->associations;
        $walk->($associations->{$_}, length($prefix) ? "$prefix.$_" : $_) for sort keys %$associations;
    };
    $walk->($domain, '');
    $html .= '</tbody></table></div></section>';
    my %associations = (source => $document->{source}{associations} // $document->{associations} // {});
    for my $schema (sort keys %{$document->{schemas} // {}}) {
        my $members = $document->{schemas}{$schema}{associations} // {};
        $associations{"schemas.$schema"} = $members if keys %$members;
    }
    for my $section (['associations','Associations', \%associations],
        ['joins','Joins',$document->{joins} // {}], ['actions','Actions',$document->{actions} // {}],
        ['writes','Write operations',$document->{writes} // {}], ['segments','Segments',$document->{query_library}{segments} // {}],
        ['authorization','Authorization surface',$domain->authorization_surface]) {
        $html .= _section($t->($section->[0], $section->[1]), $section->[2]);
    }
    $html .= '<details class="sc-catalog-section"><summary>' . $t->('json', 'View JSON') . '</summary><button type="button" data-sc-catalog-copy="sc-catalog-json" data-sc-copied="'
        . $t->('copied', 'Copied') . '" data-sc-copy-failed="' . $t->('copy_failed', 'Copy unavailable; select the JSON below.') . '">' . $t->('copy', 'Copy JSON')
        . '</button><span role="status" data-sc-catalog-copy-status></span><pre id="sc-catalog-json" tabindex="0">' . _h($raw) . '</pre></details>';
    return $html;
}

1;

=head1 NAME

Selecto::Components::DomainCatalog - read-only domain reports for authenticated hosts

=head1 SYNOPSIS

  Selecto::Components::DomainCatalog->mount($app,
      routes => $authenticated_routes, path => '/catalog', catalog => $catalog);

=head1 MOUNT OPTIONS

C<mount($app, %options)> returns the component. C<routes> defaults to the
application routes; pass a host authentication bridge. C<path> defaults to
C</catalog>. Only GET is registered; HEAD is refused with 405. No query or
write engine is constructed by this component. The core catalog report performs
its own static admission. Serve these declarations only to authorized viewers.

Supply exactly one of C<catalog> (a scope-specific Selecto::DomainCatalog) or
C<catalog_resolver =E<gt> sub ($c) { ... }> for request-specific scope.
C<title> defaults to Domain catalog. C<theme_resolver($c, $component)> returns
Explorer theme keys C<scheme>, C<primary>, C<secondary>, C<on_primary>.
C<localizer> uses the Explorer dictionary signature; C<label_domain> supplies
list-page i18n metadata. Detail terms use the served domain. Semantic keys
start with C<catalog.>; field labels and descriptions reuse C<fields.PATH.label>
and C<fields.PATH.description>. Resolver labels and values are escaped text.

C<domain_links_resolver($c, $entry)> returns C<[{label, href, kind}]>.
Like Config's header links, hrefs must be absolute same-origin paths; external
schemes and protocol-relative URLs are refused. Kind is an optional lowercase
identifier, including explorer, api, console, openapi or privileges.

C<domain_columns_resolver($c)> returns C<[{id, label, value =E<gt> sub
($c, $entry) { ... }}]>. IDs are unique lowercase identifiers. Values must be
scalar text or undef. There is no raw HTML option.

C<baselines_resolver($c, $entry)> returns C<[{id, label, against}]>, where
C<against> is an earlier contract hash or retained fingerprint accepted by
C<< $catalog->report >>. IDs are unique lowercase identifiers. The viewer can
also enter a retained fingerprint directly. Documents never come from request
bodies. Unavailable comparisons return 400. Core has no history enumeration;
the host supplies named choices. Pins supply their automatic diff.

=head1 ROUTES

GET C<path> lists reports, with C<q>, C<source> and C<status> filters.
GET C<path?domain=ID> shows one served contract and the current report;
C<against> selects an earlier comparison. Unknown domains return 404.
The JSON panel contains the core's canonical served document, including the
retained version for pinned entries. Refused contracts still show their report.
Assets and the validated public theme stylesheet use the shared static paths.

=cut
