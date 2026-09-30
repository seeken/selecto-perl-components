# Selecto::Components

Selecto::Components is a [Mojolicious](https://mojolicious.org) plugin that
adds a browser UI for exploring data to your application. It is built on
[Selecto](https://github.com/seeken/selecto-perl), the Perl query library for
governed domains. You describe the tables, columns and relationships users may
reach as a `Selecto::Domain`. The plugin then renders pages where users build
their own queries, and every query goes through Selecto's validation and SQL
compilation. The browser never sends SQL.

What you get:

- **Explorer**: a query builder with Detail, Aggregate (including a two-axis
  grid) and Graph views. Users can choose columns, filters, groupings,
  measures, sorting and pagination, and drill down from aggregates to rows.
- **Exports** of every matching row as CSV, TSV, JSON or Excel, streamed where
  the database adapter supports it.
- **Canned search pages**: author-defined views with promoted facet, range and
  text controls, and no free-form builder.
- **Row actions** (open a link, an iframe dialog or a record editor) and
  **selected-row actions** (host handlers with typed input forms, lookups,
  per-row eligibility and grouped selections).
- **Record editor**: an inline edit dialog for a single row, with optimistic
  concurrency.
- **Saved queries** kept in a store you provide, **dashboard** helpers for
  showing saved views as tiles, and **localization** hooks.
- **API Console** and **Importer** pages for a canonical Selecto HTTP API.

The UI is rendered on the server. [htmx 4](https://htmx.org) WebSockets send
incremental updates, and plain GET/POST forms still work without JavaScript.

This is an early release (0.1.0). Expect the interface to change.

## Installation

```sh
cpanm Selecto::Components
```

This installs `Selecto`, `Mojolicious` (9.49 or later) and the other Perl
dependencies. You also need the DBI driver for your database, for example
`DBD::Pg`, `DBD::SQLite` or `DBD::mysql`. See the `Selecto` documentation for
the adapters it supports. Perl 5.34 or later is required.

The browser assets (CSS, JavaScript, and vendored copies of htmx and Chart.js)
are installed into the distribution's share directory. The plugin serves them
itself. There is nothing to build, and pages load nothing from a CDN.

## Quick start

Save this as `app.pl`:

```perl
#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use DBI;
use Selecto;

# A small SQLite database. A real application would connect to its own database.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
    {RaiseError => 1, AutoCommit => 1});
$dbh->do('CREATE TABLE categories (id INTEGER PRIMARY KEY, category_name TEXT)');
$dbh->do('CREATE TABLE products (id INTEGER PRIMARY KEY, product_name TEXT,
    category_id INTEGER, unit_price NUMERIC, units_in_stock INTEGER)');
$dbh->do(q{INSERT INTO categories VALUES (1, 'Beverages'), (2, 'Condiments')});
$dbh->do(q{INSERT INTO products VALUES
    (1, 'Chai', 1, 18.00, 39), (2, 'Chang', 1, 19.00, 17),
    (3, 'Aniseed Syrup', 2, 10.00, 13), (4, 'Cajun Seasoning', 2, 22.00, 53)});

# The Selecto domain is the allowlist: only these tables, columns and joins
# can ever be queried from the browser.
my $domain = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Products',
    source => {
        source_table => 'products', primary_key => 'id',
        fields => [qw(id product_name category_id unit_price units_in_stock)],
        columns => {
            id => {type => 'integer'},
            product_name => {type => 'string', label => 'Product'},
            category_id => {type => 'integer'},
            unit_price => {type => 'decimal', label => 'Unit price'},
            units_in_stock => {type => 'integer', label => 'In stock'},
        },
        associations => {
            category => {queryable => 'categories',
                owner_key => 'category_id', related_key => 'id'},
        },
    },
    schemas => {
        categories => {
            source_table => 'categories', primary_key => 'id',
            fields => [qw(id category_name)],
            columns => {id => {type => 'integer'}, category_name => {type => 'string'}},
            associations => {},
        },
    },
    joins => {category => {type => 'inner'}},
}, strict => 1);

my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));

app->secrets(['replace-this-secret']);    # sessions carry the CSRF token

plugin 'Selecto::Components' => {
    explorers => {
        products => {
            title => 'Products',
            engine_factory => sub ($c) {
                Selecto::Engine->new(domain => $domain, adapter => $adapter);
            },
            default_fields => [qw(product_name category.category_name unit_price)],
            default_group  => ['category.category_name'],
        },
    },
};

get '/' => sub ($c) { $c->redirect_to('/explore/products') };

app->start;
```

Run it and open <http://127.0.0.1:3000/explore/products>:

```sh
morbo app.pl                       # development server with reload
perl app.pl daemon                 # or a plain daemon
perl app.pl get /explore/products  # or render one page on the command line
```

The in-memory database and the single `$dbh` are fine for `morbo` and
`daemon`. Under `prefork` or hypnotoad, open database connections per worker,
for example inside `engine_factory`.

Each explorer registers these routes under its `path` (the default path is
`/explore/<id>`):

| Route | Purpose |
| --- | --- |
| `GET <path>` | Full page. Query state lives in the URL; add `?format=csv\|tsv\|json\|xlsx` to export |
| `POST <path>` | No-JavaScript fallback for private URL mode |
| `WS <path>/ws` | htmx 4 WebSocket for incremental updates |
| `POST <path>/controls` | Lazily loaded view controls (`lazy_view_controls`) |
| `GET/POST <path>/actions/:id…` | Selected-row action forms, submissions and lookups |
| `GET/POST <path>/records/:id/edit` | Record editor |
| `POST <path>/saved-queries[/delete]` | Saved-query store |

## Configuration

The plugin takes `explorers` and/or `pages`, which are hashes keyed by a
lowercase ID, plus some options that apply to the whole plugin:

```perl
plugin 'Selecto::Components' => {
    explorers => \%explorers,                  # query builders, see below
    pages     => \%pages,                      # canned search pages
    route_bridge => {routes => $reports, prefix => '/reports'},
    origin_check => \&Selecto::Components::WebSocketPolicy::same_origin,  # the default
    websocket_inactivity_timeout => 3600,      # 30..86400 seconds
    websocket_heartbeat_interval => 30,        # 0 (off) or 15..300 seconds
    websocket_context => \&security_context,   # see "Per-request engines"
    websocket_session_options => {ttl => 30, max_bytes => 2_097_152, max_entries => 8},
    lazy_view_controls => 0,
};
```

Every explorer needs an `engine_factory` that returns a `Selecto::Engine`. It
is called for each request, and this is where your application decides which
domain, database handle and tenant scope apply. The most common explorer
options are:

| Option | Default | Meaning |
| --- | --- | --- |
| `path`, `title` | `/explore/<id>`, humanized ID | Public URL and page heading |
| `views`, `default_view` | all three, `detail` | Any of `detail`, `aggregate`, `graph` |
| `default_fields`, `default_group` | first fields | Initial Detail columns and Aggregate groups |
| `measures` | row count | Curated presets such as `{id, label, aggregate, field}` |
| `default_limit`, `max_limit` | 25, 100 | Page size and its upper bound |
| `export_authorizer`, `max_export_rows` | allow, unbounded | Who may export, and a row cap |
| `theme_resolver`, `page_shell_resolver` | none | Per-request colors, and host navigation markup |
| `localizer` | none | Translation callback |
| `action_handlers`, `action_authorizer`, … | none | Selected-row actions |
| `saved_query_store` | none | Enables the Saved queries tab |
| `show_sql` | 0 | Query Debug panel. **Never enable this in production** |

Some settings belong to the domain rather than the explorer. They go under the
domain contract's `components` key: `query_params` (see *Private URL mode*
below), `filter_choices`, `filter_picker_hidden_paths` and
`picker_visible_id_paths`.

The full option reference, with callback signatures and limits, is in
`perldoc Selecto::Components`. Related modules have their own POD, for example
`Selecto::Components::CannedPage`, `Selecto::Components::Actions`,
`Selecto::Components::RecordEditor` and `Selecto::Components::Dashboard`.

## Integrating into an existing application

### Authentication with a route bridge

To mount every route beneath one of your own `under` routes, pass it as
`route_bridge`. Normal Mojolicious dispatch then runs your authentication
before any explorer, action, export or WebSocket request:

```perl
my $reports = app->routes->under('/reports')->to(cb => sub ($c) {
    return 1 if $c->session('user_id');
    $c->render(text => 'Please sign in', status => 401);
    return undef;
});

plugin 'Selecto::Components' => {
    route_bridge => {routes => $reports, prefix => '/reports'},
    explorers => {
        orders => {
            path => '/reports/orders',
            title => 'Orders',
            engine_factory => \&orders_engine,
        },
    },
};
```

Each explorer `path` must start with the bridge `prefix`.

### Per-request engines and tenant scope

`engine_factory` receives the controller. Build the tenant or row-level scope
from trusted server-side state, never from request parameters. A required
predicate is combined with every data, count, export and drilldown query the
user can build:

```perl
sub orders_engine ($c) {
    # Trusted, server-side tenant: never read it from the request.
    my $tenant_id = $c->session('tenant_id');
    my $domain = $orders_domain->with_required_predicate(
        Selecto::Expression->eq('tenant_id', $tenant_id),
    );
    return Selecto::Engine->new(domain => $domain, adapter => $adapter);
}
```

Mark the scoping column `internal => 1` in the domain. It stays usable in
predicates but is never offered as a column or filter.

A WebSocket stays open far longer than one HTTP request. `websocket_context`
(set for the plugin or per explorer) runs for every message. Return `undef` to close the socket, or return a string
that identifies the security context (tenant, user and policy version). When
that string changes, the connection's cached results are discarded. See
[docs/explorer-sessions.md](docs/explorer-sessions.md).

```perl
websocket_context => sub ($c, $config) {
    my $user = $c->session('user_id') // return undef;    # undef closes the socket
    return join ':', $c->session('tenant_id'), $user;
},
```

If you lease database connections per request, release them in
`websocket_message_cleanup => sub ($c, $config) {...}`. It runs after every
WebSocket message.

### Themes and page shells

Explorer pages ship with their own stylesheet. You can brand them per request
and wrap them in your own navigation without loading host CSS into the
component:

```perl
theme_resolver => sub ($c, $config) {
    return {scheme => 'light', primary => '#0B5FFF',
        secondary => '#00A37A', on_primary => '#FFFFFF'};
},
page_shell_resolver => sub ($c, $config, $model) {
    return {
        head_start_html => '<link rel="stylesheet" href="/css/host-nav.css">',
        body_start_html => '<nav class="host-nav"><a href="/">Home</a></nav>',
        body_class => 'with-host-nav',
    };
},
```

Colors must be `#RRGGBB`. The shell's HTML strings are trusted markup, so never
put user input in them. If your page has a fixed toolbar, set
`--sc-sticky-top` on an ancestor of the explorer to the toolbar's height, and
result headers will stick below it.

### Localization

Give the domain a stable `extensions => {i18n => {namespace => 'myapp.orders'}}`
namespace and supply a `localizer`. It receives dictionary keys such as
`myapp.orders.fields.customer.label`, plus a fallback string:

```perl
localizer => sub ($key, $default, $context) {
    return $translations{$key} // $default;
},
```

`Selecto::Components::I18N->terms($domain)` lists every key, which you can
feed to a translation workflow.

### Canned search pages

A page presents fixed views with a few promoted controls, and users cannot edit
its query. Define it under `pages`. The keys that `Selecto::CannedPage` defines
(`domain`, `dataset`, `views`, `controls`, `initial_state`) are passed through
to it:

```perl
plugin 'Selecto::Components' => {
    pages => {
        product_search => {
            path => '/products', title => 'Product Search',
            domain => $domain,
            engine_factory => sub ($c) { $engine },
            dataset => {query => Selecto::Query->new, entity_key => ['id']},
            views => [
                {id => 'list', kind => 'detail', label => 'Products',
                    query => Selecto::Query->new->select('id', 'name', 'brand', 'price')
                        ->order_by('name')},
                {id => 'by_category', kind => 'aggregate', label => 'By category',
                    query => Selecto::Query->new->select('category',
                        Selecto::Expression->count_distinct('id')->as('items'))
                        ->group_by('category')->order_by('category')},
            ],
            controls => [
                {id => 'brand', kind => 'facet', label => 'Brand', field => 'brand',
                    values => {source => 'dataset', limit => 30, searchable => 1}},
                {id => 'price', kind => 'range', label => 'Price', field => 'price'},
                {id => 'name', kind => 'text', label => 'Name', field => 'name'},
            ],
            record_link => {field => 'id', url_prefix => '/products/view?id='},
            initial_state => {view => 'list', filters => {}},
        },
    },
};
```

To keep a request-specific row scope in every result and facet query, add
`scope_factory => sub ($c, $engine) { $predicate }`. Set
`websocket_enabled => 0` for a page that only uses ordinary GET navigation.
See `Selecto::Components::CannedPage` for `column_layout`.

### Selected-row actions

Declare actions in the domain contract. Then register a handler for each one
on the explorer. An action is offered only when the domain declares it and a
handler is registered. It appears in the column picker as `Action: <label>`.

```perl
# In the domain contract:
actions => {
    mark_shipped => {
        label => 'Mark shipped',
        scope => 'bulk',
        inputs => {
            note => {label => 'Note', type => 'textarea', required => 1, max_length => 200},
        },
        execution => {kind => 'host', operation => 'mark_shipped'},
    },
},

# In the explorer configuration:
action_authorizer => sub ($c, $request) {
    return $c->session('user_id') ? 'enabled' : 'hidden';
},
action_handlers => {
    mark_shipped => sub ($c, $request) {
        # selected_ids are unique and bounded; inputs are validated.
        # Re-check every ID against the current tenant before writing.
        my $count = MyApp::Orders->mark_shipped(
            $c, $request->{selected_ids}, $request->{inputs}{note},
        );
        return {ok => 1, message => "Marked $count orders."};
    },
},
```

Submissions need the session CSRF token that the rendered form carries. The
same explorer can also define `choice_sources`, `lookup_sources`,
co-domain lookups (`co_domain_engines` and `co_domain_scopes`),
`action_eligibility_resolvers`, `action_form_resolvers` and a
`record_editor_handler`. Row-click actions (`detail_actions`) and record
editors (`editors`) are declared in the domain. See
`Selecto::Components::Actions`, `Selecto::Components::RowActions` and
`Selecto::Components::RecordEditor`.

### Private URL mode

By default the URL query string holds the query-builder state, so pages can be
refreshed, bookmarked and exported. If filter values are sensitive, turn this
off in the domain:

```perl
my $patients = Selecto::Domain->new(
    name => 'Patients', table => 'patients',
    fields => {id => 'integer', diagnosis => 'string'},
    components => {query_params => 0},
);
```

In private URL mode, state travels only in WebSocket and POST bodies.
Generated URLs stay path-only, and inbound query strings redirect to the bare
path. Responses are sent with `Cache-Control: no-store`. Permalinks, query
string exports and the Saved queries tab are unavailable.

### Saved queries, dashboards and the API Console

- `saved_query_store` takes an object with
  `list($c, $config)`, `save($c, $config, {name, url})` and
  `delete($c, $config, {name})`. Optional methods add multiple destinations
  and guarded updates. Your application owns scoping, sharing and
  persistence. See the `saved_query_store` section of
  `perldoc Selecto::Components`.
- `Selecto::Components::Dashboard` turns saved view URLs into tiles, and can
  apply shared filter values to their promoted filters. Get the explorer
  object with `$c->selecto_components_explorer($id)`.
- `Selecto::Components::APIConsole->page(...)` renders the packaged API
  Console for a canonical Selecto HTTP API, and `install_assets($app)` serves
  its files. An explorer's `api_console_resolver` adds an **API** button that
  hands the current Detail query to it.

## Optional add-ons

Native-template pages (`Selecto::Components::Templates`, the `/templates/:id`
routes, instance stores and the Studio preview host) are provided by the
separate
[Selecto-Components-Templates](https://github.com/seeken/selecto-perl-components-templates)
distribution. It is not yet on CPAN, because it depends on the unpublished
`Selecto::Templates`. The browser code for those pages still ships in this
distribution's bundle, so the add-on needs no assets of its own.

## Security model

- **No SQL from the browser.** Field paths, operators, aggregate functions,
  sort directions, formats and limits come from the domain and closed
  allowlists. Values are bound as parameters. Browser input can never pick
  the adapter or the database.
- **The domain is the boundary.** Identifiers outside the configured
  `Selecto::Domain`, and internal fields, are rejected on every request,
  including forged URLs and WebSocket frames.
- **Scope comes from the host.** Tenant and row scope come from
  `engine_factory` (a required predicate or `Selecto::Engine` scope) and from
  `scope_factory` on canned pages. Authorization comes from your route
  bridge, `action_authorizer`, `export_authorizer` and `websocket_context`.
- **Actions** must be declared by the domain *and* registered by the host.
  Targets are deduplicated and bounded. Inputs and choices are revalidated
  on the server. Execution is authorized again. POSTs need the session CSRF
  token.
- **WebSockets**: when a handshake carries an `Origin` header, its scheme,
  host and port must match the request. Supply `origin_check` if you run
  behind unusual proxies or serve several origins. Frames are capped at
  128 KiB.
- **Errors**: raw database errors are logged, never rendered. `show_sql`
  renders SQL *with bound parameters*, including tenant IDs. The plugin warns
  at startup if `show_sql` is enabled in `production` mode.

The pages work under a self-contained Content Security Policy:

```text
default-src 'self'; script-src 'self'; style-src 'self';
connect-src 'self' ws: wss:; img-src 'self'; base-uri 'none'; frame-ancestors 'none'
```

## Browser and transport notes

The vendored htmx runtime is exactly `htmx.org@4.0.0`:

| Asset | SHA-256 |
| --- | --- |
| `htmx.min.js` | `e484d9171a9db30a39c8f16e3d709d4137f3211c659f8e6125816635033d593f` |
| `hx-ws.min.js` | `a7c11e4eca05417d6299bb40aaacca01572e44605389fc4d5ef12be408a4d03b` |

The UI uses htmx 4's `hx-ws:connect`/`hx-ws:send` and the `htmx:ws:*` events.
Server messages carry `content`, `target` and `swap`, and application metadata
travels under `selecto`. This is not the htmx 2 `ws-connect` protocol. Edits
are staged locally until the user presses **Run query**. The same form works as
an ordinary GET (or a POST, in private URL mode) without JavaScript. The
WebSocket is only a faster transport for the same state, and the server keeps
no query-builder state that the URL (or the POST body) does not also carry.
Charts use a vendored Chart.js 4.5.1.

## Example application

[`examples/northwind.pl`](examples/northwind.pl) runs two explorers and a
canned page over a real PostgreSQL Northwind database. It needs the separate
`selecto-perl-northwind` fixture checked out next to this repository:

```sh
cd ../selecto-perl-northwind
export DATABASE_URL='postgres://localhost/selecto_perl_northwind'
mise run setup
cd ../selecto-perl-components
mise run server        # http://127.0.0.1:4128/explore/products and /pages/products
```

## Development

```sh
cpanm --installdeps .
script/with-local-sibling prove -lr t
mise run verify        # asset checks, Playwright browser tests, prove and make test
```

`script/with-local-sibling` uses the checkout of `selecto-perl` in
`../selecto-perl`. Set `SELECTO_LIVE_SELECTO_PERL=/path/to/selecto-perl` to use
another checkout, or `SELECTO_ECOSYSTEM_USE_LOCAL=0` to use the installed
`Selecto`. The browser sources live in `src/browser/`. `npm run build`
produces `public/selecto-components/selecto-components.js`, and
`mise run assets` resyncs the shared CSS, htmx and API Console assets from the
sibling `selecto-api-console` workspace.

## License

Copyright (c) 2026 Chris Rohlfs. This is free software, licensed under the
Artistic License 2.0 (GPL Compatible). See [LICENSE](LICENSE).

The vendored browser assets have their own licenses (htmx: 0BSD, Chart.js:
MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
