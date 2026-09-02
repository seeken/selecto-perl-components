# Selecto Components Perl

`selecto-perl-components` is a server-rendered Mojolicious workalike for the
core exploration flow in Elixir's `selecto_components`. It sits directly on
native [`selecto-perl`](https://github.com/seeken/selecto-perl): Selecto owns the
domain, immutable query, adapter compilation, bound values, and execution;
this package owns validated browser state, HTML, WebSockets, and assets.

This is alpha software. Its browser transport is pinned to htmx `4.0.0`.

The Perl explorer remains the visual reference, while the shared CSS source
now lives in the sibling `selecto-api-console` JavaScript workspace as
`@selecto/web-assets`. `mise run assets` regenerates this distribution's CSS,
htmx files, and API Console from local siblings; the same resolver can consume
installed npm packages later.

## Current surface

- a reusable `Selecto::Components` Mojolicious plugin;
- a dependency-free Selecto API Console that discovers a canonical API's
  manifest, domain, OpenAPI document, public fields, types, query-library
  views/projections/segments, and orderings at runtime, then builds, runs, and
  displays bounded queries without domain-specific JavaScript;
- named query-library views integrated into View and reusable governed
  segments and typed parameters integrated into Filters, with active-tab
  continuity across WebSocket fragment replacements;
- optional request-time localization of domain titles, fields, measures,
  query-library entries, and action forms through portable domain i18n metadata;
- locally staged builder edits with an explicit Run boundary, so unfinished
  view, column, filter, sort, and pagination changes do not execute queries;
- a left-side view tray that participates in normal page scrolling, collapses
  to a chevron rail, and automatically collapses when a query is applied;
- domain-derived Available/Set field picker with filtering, add/remove controls,
  drag ordering, and accessible move-up/move-down controls;
- per-column presentation aliases and governed date/time formats for Detail
  columns and Aggregate grouping buckets;
- an ordered Available/Set sort picker with independent ascending/descending
  direction for each selected field;
- domain-derived Available/Set filter picker with search, multiple AND filters,
  and removable filter editors;
- type-aware filter controls: native date and date-time inputs, numeric inputs,
  boolean choices, two-value ranges, and allowlisted calendar shortcuts such
  as Today, This Month, This Quarter, and This Year;
- Detail, Aggregate, and Graph result views, with Bar, Horizontal Bar, Stacked
  Bar, Line, Area, Pie, Doughnut, and Scatter dashboard charts;
- automatic Detail denormalization prevention for to-many relationships:
  selected child fields share an inline nested table backed by a correlated
  JSON collection, so each root object remains one result row;
- domain-declared selected-row actions exposed as optional Detail columns; each
  chosen action owns its selection UI, button, and typed dialog. Ordinary
  actions use independent checkbox sets, while grouped actions can assign rows
  to trusted colored-shape markers and collect inputs for each group. Both use
  hidden primary-key selection, dynamic host choices, preview/execute
  authorization callbacks, CSRF protection, and server-side input revalidation;
- total matched-row and page counts plus full data-and-count query timing, with
  changed query intent resetting to page one while page-only Run and
  Previous/Next retain explicit pagination;
- hierarchical Aggregate rollups with clickable group values, subtotals, and a
  grand total, plus clickable Graph group values; drilldowns retain existing
  filters and apply the selected group path as exact governed Detail predicates,
  including formatted dates, numeric/date buckets, and text prefixes;
- star-dimension Aggregate and Graph groups that display the referenced name,
  group by the stable fact key, and use that hidden key for Detail drilldowns;
- `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between`, `in`, `is_null`, and
  `not_null` filters supported by the current native Perl query contract;
- a domain-derived Available/Set aggregate picker where every governed column
  can be configured with type-aware `count`, distinct-count, average, sum,
  min/max, boolean-count, and buckets, alongside optional curated presets;
- relationship fields, sorting, bounded limits, and offset pagination;
- domain-declared object links for Detail HTML cells, with related IDs selected
  as hidden governed columns and no extra ID columns in exports;
- optional domain-declared row-click actions for Detail results, with a compact
  action selector, permalink/saved-query state, automatically selected hidden
  dependencies, safe URL substitution, and keyboard access;
- htmx 4 `hx-ws` updates using server-rendered HTML fragments;
- ordinary HTTP GET fallback, permalinks, and browser-refresh recovery;
- an optional dedicated Saved queries tab backed by a host-provided object with
  `list`, `save`, and `delete` methods; saved URLs are validated, canonicalized,
  and reset to page one while the host owns user and tenant scoping;
- a domain-selected private URL mode with WebSocket/POST body state and no
  query-state history, permalink, or query-string export link;
- Excel, CSV, TSV, and JSON exports for every row matched by the active query,
  independent of the current page, with spreadsheet-formula neutralization for
  delimited formats;
- an optional collapsible Query Debug panel with generated data/count SQL,
  bound parameters, execution timings, pagination, adapter, and row statistics;
  and
- a real PostgreSQL-backed Northwind example using the existing independently
  authored `selecto-perl-northwind` fixture.

The package is a behavioral workalike, not a source or API port of Phoenix
LiveView. It preserves the recognizable Explorer flow while using
Mojolicious-native transport and lifecycle boundaries.

## API Console contract

The API Console browser code is owned by the sibling `selecto-api-console`
repository and packaged as `@selecto/api-console`. This Perl distribution
ships generated `0.2.0` assets so Mojolicious applications remain
self-contained; it does not fork the JavaScript or CSS source. The console is
host-neutral. It does not receive a serialized
field catalog from Perl and does not contain application domain names. A host
serves the two packaged assets and provides a mount point containing the
canonical API base path:

```html
<link rel="stylesheet" href="/selecto-api-console/selecto-api-console.css">
<script defer src="/selecto-api-console/selecto-api-console.js"></script>
<main data-selecto-api-console
      data-api-base="/api2/orders/v1"
      data-title="Orders API Console"></main>
```

On startup it reads the base manifest, `domain`, and `openapi.json` resources
with same-origin credentials. It derives public field and type controls from
the canonical domain and query-library controls from the domain's named views,
projections, segments, parameters, and orderings. Query execution uses the
advertised versioned `query` route. No adapter, table name, raw SQL, or
unpublished identifier can be selected by the UI.

`Selecto::Components::APIConsole->page` also accepts semantic `theme` and
validated `page_shell` objects. These let a host apply tenant colors and inject
its established navigation dependencies and markup without coupling the shared
console package to an application framework or menu implementation.

Mojolicious hosts may render the complete shell and install its static path
with `Selecto::Components::APIConsole->page(...)` and
`Selecto::Components::APIConsole->install_assets($app)`. Other Selecto hosts
can serve the same JavaScript and CSS unchanged using the HTML contract above.
The packaged standalone page is also available at
`/selecto-api-console/index.html?api=/api2/orders/v1`.

Maintainers refresh the vendored distribution with
`script/sync-api-console`. It builds the sibling `selecto-api-console` checkout
when present, accepts `SELECTO_API_CONSOLE_DIST` for another checkout, and
falls back to an installed `@selecto/api-console` package. Every copied file is
verified against the shared asset manifest before changing the Perl package.

## State and transport contract

The URL query string is canonical by default. A WebSocket is only a faster
transport for the same state:

1. A direct `GET /explore/products?...` normalizes and validates query params.
2. The form sends the same named fields over htmx 4 as top-level JSON values,
   alongside the reserved `headers` object.
3. The server runs the same state parser and Selecto query builder.
4. It returns a JSON message containing server-rendered HTML and a canonical
   URL.
5. htmx swaps only the Explorer surface; a tiny local script calls
   `history.replaceState` with the canonical URL.

Refresh, copy/paste, bookmarks, and ordinary form submission therefore resolve
to the same governed query as a WebSocket interaction. The server keeps no
hidden query-builder state.

For a domain whose filters may contain sensitive values, set
`components.query_params` to false in the domain contract:

```perl
my $domain = Selecto::Domain->new(
    name => 'Patients',
    table => 'patients',
    fields => { id => 'integer', diagnosis => 'string' },
    components => { query_params => 0 },
);
```

Private URL mode keeps generated URLs at the explorer path, ignores and
redirects away inbound query state, removes permalink and query-string export
controls, marks responses `Cache-Control: no-store`, and changes the ordinary
fallback form to POST. Interactive state remains in the rendered form and
WebSocket/POST body. Refresh starts again from domain defaults unless the host
provides an explicit saved-view store; the package does not move sensitive
state into a cookie or opaque client token.

While editing, the browser stages controls locally and leaves the URL and
result set at their last applied state. Only **Run query** submits the
complete form over the WebSocket (or as an ordinary GET/POST, according to the
domain policy, without JavaScript).

In the default shareable mode, canonical parameters are:

- `view`: `detail`, `aggregate`, or `graph`;
- `row_click_action`: the selected portable Detail action, when one is active;
- repeated `field` and `group` values; `field` order is the selected result-column order;
- aligned `field_alias`/`field_format` and group alias/format/bucket/prefix values,
  so each selected column carries its own presentation configuration;
- aligned, repeated `filter_field`, `filter_op`, `filter_value`, and
  `filter_value_end` values; server-generated aggregate drilldowns also align
  a `filter_group` marker so the governed grouping expression is reused as the
  Detail predicate;
  newly added filters remain URL-visible drafts and do not constrain the query
  until they have the required value or values (or a null operator). Date
  shortcuts are stored as allowlisted identifiers and resolved to bound,
  half-open date ranges on submission;
- aligned repeated measure-or-column/function/alias/bucket/NULL-handling values, repeated
  `order`/`direction` values, `limit`, and `page`; and
- `q=1`, which distinguishes an authored empty selection from the initial
  default state.

When a domain declares `query_library`, canonical state also includes
`query_library_view`, repeated `query_library_segment`, aligned
`query_library_param_name`/`query_library_param_value` pairs, and an internal
materialized-view marker. The marker lets a newly selected view seed Detail
columns and ordering once while keeping those controls editable on subsequent
requests. Named view segments and additional segments continue to constrain the
query alongside visual filters. They are included in the applied-filter count
and shown as non-removable segment summaries; remove them by changing the named
view or segment controls. Query-library `capability` values are rendered as
metadata only and are not an authorization decision.

Projection association shapes are adapted to the Perl component builder as
validated dotted field paths. Parameter values are type-checked by
`selecto-perl` and remain bound values in the compiled statement.

For a canonical join with `type => 'star_dimension'`, grouping either its
`dimension_key` or configured joined `display_field` shows the dimension name
but groups on the key. The key is carried as a hidden result column, so clicking
the displayed name creates an exact, direct predicate such as `status = 'D'`.
Star dimensions intentionally do not offer bucketing or prefix formats because
their name/key pair is the grouping unit.

## Plugin usage

```perl
use Mojolicious::Lite -signatures;
use Selecto;
use Selecto::Components;
use Selecto::Engine;

my $domain = MyApp::Domains->products;
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));

plugin 'Selecto::Components' => {
    explorers => {
        products => {
            path => '/explore/products',
            title => 'Products',
            engine_factory => sub ($controller) {
                return Selecto::Engine->new(
                    domain => $domain,
                    adapter => $adapter,
                );
            },
            default_fields => [
                'product_name',
                'category.category_name',
                'unit_price',
            ],
            default_group => ['category.category_name'],
            default_limit => 25,
            max_limit => 100,
            max_filters => 20,
            max_orders => 10,
            show_sql => 0,
        },
    },
};
```

This registers:

- `GET /explore/products` for a full page and no-JavaScript fallback;
- `POST /explore/products` for the no-JavaScript private-state fallback;
- `GET /explore/products?format=xlsx|csv|tsv|json` for the current result page; and
- `WS /explore/products/ws` for htmx 4 incremental updates.

## Host themes

An application can adapt an Explorer to request-specific branding without
loading a host stylesheet into the portable component UI. Supply a
`theme_resolver` callback in an Explorer configuration. It receives the
current Mojolicious controller and request-local configuration and returns a
`scheme` of `light` or `dark`, plus any of `primary`, `secondary`, and
`on_primary` as six-digit hexadecimal colors.

```perl
theme_resolver => sub ($controller, $config) {
    my $palette = MyApp::TenantTheme->for_request($controller);
    return {
        scheme     => 'light',
        primary    => $palette->{brand_color},
        secondary  => $palette->{accent_color},
        on_primary => $palette->{brand_text_color},
    };
},
```

The values are validated before they become scoped CSS custom properties.
Resolvers should return an empty object when no tenant palette is available;
the shared dark palette remains the fallback.

## Host page shells

Applications can surround the full Explorer page with their existing
navigation without coupling that navigation to the portable query surface.
Supply a `page_shell_resolver` callback; it receives the current Mojolicious
controller, request-local configuration, and page model.

```perl
page_shell_resolver => sub ($controller, $config, $model) {
    return {
        head_start_html => '<link rel="stylesheet" href="/host/navigation.css">',
        head_html => '<style>.host-navigation { z-index: 1000 }</style>',
        body_start_html => '<host-navigation></host-navigation>',
        body_class => 'host-navigation-enabled',
    };
},
```

`head_start_html` loads before the Selecto component assets, while `head_html`
loads after them and is suitable for small host compatibility overrides.
`body_start_html` is emitted immediately inside `body`. These HTML values are
trusted application markup and must never contain request or user input.
`body_class` is separately validated as a space-delimited list of CSS class
names. The shell is applied only to a full page; incremental result surfaces
remain host-neutral.

## Domain localization

Canonical domains can opt into request-time presentation localization without
changing field paths or saved-query state; language selection does not alter
the domain fingerprint. Add a stable
namespace under `extensions.i18n`; `terms` is optional and can override a
generated dictionary key or provide defaults for presentation text that lives
in host configuration, such as the Explorer title and curated measures.

```perl
extensions => {
    i18n => {
        namespace => 'selecto.products',
        terms => {
            'domain.title' => {default => 'Product Explorer'},
            'measures.count.label' => {default => 'Product count'},
        },
    },
},
```

The Explorer configuration supplies a `localizer` callback. It receives the
generated dictionary key, portable fallback, and semantic context (including
the current Mojolicious `controller`) and must return a plain scalar. Errors,
references, empty strings, and control characters fall back to the portable
text.

```perl
localizer => sub ($key, $default, $context) {
    return MyApp::Dictionary->translate($key, $default);
},
```

Generated keys include `fields.<path>.label`,
`query_library.<registry>.<id>.label`, and nested action/input/option paths
under `actions.<id>`. Localization happens before display-label sorting.
`Selecto::Components::I18N->terms($domain, {...})` returns the complete term
catalog for an application-controlled synchronization or translation workflow.
The canonical contract is never translated or mutated.

## Detail object links

A canonical domain column may declare an internal object link. `id_field` is
relative to that column's relation, so a link on `shipper.co_name` with
`id_field => 'id'` automatically selects `shipper.id`. The ID remains hidden
and the displayed company name becomes the link in Detail HTML results.
Aggregate/Graph cells and exported data remain unchanged.

```perl
co_name => {
    type => 'string',
    link => {
        url_template => '/backoffice/client.mcgi?id={{id}}',
        id_field => 'id',
    },
},
```

Templates must be same-application paths beginning with one `/` and must
contain `{{id}}`. Components URL-encodes the selected ID and HTML-escapes the
completed link before rendering it.

## HTML-only value formatting

A canonical domain column may opt into a governed HTML formatter. The
`vin_last_six` formatter leaves the first 11 characters of a valid
17-character VIN at normal weight and wraps its final six characters in
`<strong>`. Short or malformed values are displayed normally. Formatting is
also applied inside to-many nested tables and to grouped HTML values.

```perl
vin => {
    type => 'string',
    html_format => 'vin_last_six',
},
```

This is a presentation rule only. Excel, CSV, TSV, and JSON exports retain the
original unformatted value.

## Detail row-click actions

Canonical domains can offer `external_link` and `iframe_modal` actions that
make the unused surface of each Detail row open a governed application
destination. Required fields are fetched as hidden query columns when they are
not already selected; they remain absent from the displayed columns and
exports.

```perl
detail_actions => {
    open_product => {
        name => 'Product maintenance',
        type => 'external_link',
        required_fields => ['id'],
        payload => {
            url_template => '/products/maint?id={{id}}',
            target => '_self',
        },
    },
},
```

Set `default_row_click_action => 'open_product'` in the Explorer configuration
to enable it on the initial view. Users can choose another declared action or
`No row action`; that choice participates in canonical URL and saved-query
state. Clicking an existing link, button, checkbox, form control, or selected
text does not trigger the row action. URL substitutions are percent encoded,
and executable or protocol-relative URL schemes fail closed.

Use `type => 'iframe_modal'` with the same URL template to keep the Explorer in
place. The shared dialog lazily loads the selected row, offers Previous and Next
controls in the rows' current displayed order, reports that navigation is for
the current page, and includes an `Open full page` link. Its payload also accepts
`title`, `size`, `referrer_policy`, `navigation_enabled`, and optional `allow`
or `sandbox` iframe attributes.

## Selected-row actions

Selected-row actions come from the canonical domain contract. The Components
host only renders actions that are bulk-scoped (or explicitly bulk-enabled)
and have a registered host handler. Required action fields are normalized and
validated again on POST; select choices are resolved again for the current
request so a stale browser cannot submit a choice that the user can no longer
use.

Authorized actions appear in the Detail column picker as `Action: <label>`.
Adding one and running the query places its checkbox column in the requested
column order and displays its action button. Multiple action columns may be
selected at once; their selected rows, counts, buttons, and dialogs remain
independent. Removing an action column removes that action UI from the result.

```perl
actions => {
    add_note => {
        label => 'Add Note',
        scope => 'bulk',
        inputs => [
            {
                id => 'note_type', label => 'Note type', type => 'select',
                choice_source => 'note_types', required => 1,
            },
            {
                id => 'comment', label => 'Comment', type => 'textarea',
                required => 1, max_length => 255,
            },
        ],
        execution => {kind => 'host', operation => 'add_note'},
    },
},
```

Register dynamic choices, authorization, and the application-owned execution
boundary on the explorer:

```perl
choice_sources => {
    note_types => sub ($controller, $action, $input) {
        return [{value => 'internal', label => 'Internal'}];
    },
},
lookup_sources => {
    carriers => sub ($controller, $request) {
        # Authenticate and tenant-scope this query in the host application.
        # $request includes query, limit, action, input, and selected_ids.
        return [{
            value => 501,
            label => 'Acme Transport',
            description => 'ID 501 · Detroit, MI',
        }];
    },
},
action_authorizer => sub ($controller, $request) {
    return {status => 'enabled'};
},
action_handlers => {
    add_note => sub ($controller, $request) {
        # $request->{selected_ids} is unique and bounded.
        # $request->{inputs} contains normalized, validated form values.
        return {ok => 1, applied_count => scalar @{$request->{selected_ids}}};
    },
},
```

The action route is `POST /explore/products/actions/:action_id`. Browser forms
carry a session-bound CSRF token. Hosts remain responsible for checking every
target against the current tenant/user and for transaction, audit, and
business-rule behavior inside the handler.

An action can instead group rows before it runs. The built-in `lucky_charms`
palette uses pink hearts, orange stars, yellow moons, green clovers, blue
diamonds, and purple horseshoes in that order, exposing a new distinct shape as
each group is created. A selected row displays only its filled marker;
clicking it again unassigns the row and restores the available outlines. The
result table keeps rows with the same marker adjacent, orders marker groups by
palette order, and retains the original query order within each group and among
unassigned rows. Reordering uses a short positional animation and honors the
browser's reduced-motion preference.

```perl
load_build => {
    label => 'Load Build',
    scope => 'bulk',
    selection => {
        mode => 'groups',
        palette => 'lucky_charms',
        max_groups => 6,
        row_details => [
            {id => 'origin', label => 'Origin', field => 'origin.city'},
            {id => 'destination', label => 'Destination', field => 'destination.city'},
        ],
        group_inputs => [{
            id => 'carrier_id', label => 'Carrier', type => 'lookup',
            lookup_source => 'carriers', value_type => 'integer',
            direct_entry => 1, minimum_query_length => 2,
            required => 1, minimum => 1,
        }],
    },
    submit_label => 'Build loads',
    execution => {kind => 'host', operation => 'load_build'},
},
```

The handler receives normalized `selected_ids` plus `groups`, ordered by marker
index. Each group has its trusted server-resolved `marker`, its own
`selected_ids`, and normalized `inputs`. The browser cannot submit custom
marker colors, shapes, or labels. `row_details` are governed hidden fields
shown beside each selected row in the confirmation card; they are display-only
and are not submitted to the handler. A `lookup` input uses the authenticated
`GET /explore/products/actions/:action_id/lookups/:input_id` route and the
corresponding host-owned `lookup_sources` callback. Results are normalized to
`value`, `label`, and optional `description`; the chosen value, not its label,
is submitted to the action handler. Lookup discovery reuses action
authorization and includes the active group's selected row IDs so the host can
apply tenant, eligibility, and row-level rules.

The plugin adds its packaged `public/` directory to Mojolicious static paths.
The htmx runtime and WebSocket extension are served locally; the browser does
not depend on a CDN.

Aggregate and Graph Available lists are derived from the domain field catalog,
including relationship columns. A user selects a column and configures its
allowlisted aggregate function, alias, NULL handling, or buckets. No `measures`
configuration is required; a governed row-count choice is included automatically.

An explorer may additionally publish curated presets. Presets appear beside the
domain columns and remain fully configurable according to their underlying type:

```perl
measures => [
    { id => 'product_count', label => 'Product count', aggregate => 'count' },
    { id => 'total_price', label => 'Total price', aggregate => 'sum', field => 'unit_price' },
],
```

`max_filters` defaults to 20 and may be configured from 1 through 20. Because
the Available/Set model permits each governed field once, the domain's field
catalog can impose a lower practical maximum.

`max_orders` defaults to 10 and may be configured from 1 through 20. Date/time
formats are selected from a closed catalog; Aggregate formatting is part of the
group expression itself, so choosing Month produces month buckets rather than
merely changing the display label.

## htmx 4 boundary

The vendored assets are exactly `htmx.org@4.0.0`:

| Asset | SHA-256 |
| --- | --- |
| `htmx.min.js` | `e484d9171a9db30a39c8f16e3d709d4137f3211c659f8e6125816635033d593f` |
| `hx-ws.min.js` | `a7c11e4eca05417d6299bb40aaacca01572e44605389fc4d5ef12be408a4d03b` |

The UI uses the htmx 4 names `hx-ws:connect` and `hx-ws:send`. Incoming server
messages set `content`, `target`, and `swap` according to the
[official htmx 4 WebSocket extension contract](https://htmx.org/extensions/hx-ws),
with application metadata under `selecto`. Browser listeners use the final
`htmx:ws:*` lifecycle events and the asynchronous message JSON API.
Do not substitute the htmx 2 `ws-connect` protocol without changing the server
message and tests.

## Security boundary

- Every field and relationship path must resolve through the configured
  `Selecto::Domain`.
- View names, operators, aggregate functions, sort directions, limits, and
  measure sources come from closed allowlists and the governed domain catalog.
- Values remain separate from SQL and compile as adapter parameters.
- Browser input cannot select an adapter or submit SQL.
- Selected-row action IDs must be declared by the domain and registered by the
  host. Action targets are deduplicated and bounded, action choices are
  re-resolved, authorization is repeated for execute, and POSTs require the
  session-bound CSRF token. An action that declares a capability stays hidden
  unless the explorer registers an `action_authorizer`.
- WebSocket handshakes with an `Origin` header default to same-host only. A host
  behind unusual proxy or multi-origin routing can provide an explicit
  `origin_check` callback to the plugin.
- WebSocket frames are capped at 128 KiB and invalid envelopes close with a
  policy/data error.
- Private URL mode reduces disclosure through history, logs, referrers, and
  copied links; hosts must still use TLS and avoid request-body logging when
  filter values are sensitive.
- Raw database exceptions are not rendered. Known `Selecto::Error` messages
  remain visible; unexpected failures become a generic error.
- Raw SQL is hidden unless the host explicitly enables `show_sql`. Enabling it
  renders the Query Debug panel and should remain limited to trusted development
  environments.

A host Content Security Policy can remain self-contained:

```text
default-src 'self'; script-src 'self'; style-src 'self';
connect-src 'self' ws: wss:; img-src 'self';
base-uri 'none'; frame-ancestors 'none'
```

## Development

Perl 5.34+, Mojolicious 9.40+, and the native `selecto-perl` sibling are
required. The workspace development toolchain pins Perl 5.40.2.

```sh
cpanm --installdeps .
mise run verify
```

Local resolution defaults to `../selecto-perl`. Override it without editing
repository files:

```sh
SELECTO_LIVE_SELECTO_PERL=/path/to/selecto-perl mise run verify
```

Set `SELECTO_ECOSYSTEM_USE_LOCAL=0` to use an installed `Selecto`
distribution.

## Northwind example

The example uses the existing native Perl Northwind database, domains, and
registered adapter. Prepare a disposable database in the sibling app first:

```sh
cd ../selecto-perl-northwind
export DATABASE_URL='postgres://localhost/selecto_perl_northwind'
mise run setup

cd ../selecto-perl-components
export DATABASE_URL='postgres://localhost/selecto_perl_northwind'
mise run server
```

Open [http://127.0.0.1:4128/explore/products](http://127.0.0.1:4128/explore/products).
Set `PORT` or `PHX_DEV_HOSTNAME` to change the development endpoint.

## Verification boundary

`mise run verify` covers state normalization, rejected identifiers and
capabilities, canonical repeated query params, real PostgreSQL SQL compilation,
bound filter values, relationship joins, grouping and aggregates, ordered
Available/Set field selection, multiple Available/Set filters and draft-filter
semantics, configured date/time detail columns and aggregate buckets,
multi-column ordering, shareable GET and private POST rendering, private URL
redirection, static assets, all export formats, and real Mojolicious WebSocket message
round trips.

That is bounded evidence for the included domains, states, transport envelopes,
and test adapter results. It is not proof of arbitrary schemas, adapters,
databases, browser versions, proxy settings, accessibility, concurrency,
security, or performance.

## Explicitly deferred

- persisted saved-view stores and sharing policy;
- emailed and scheduled exports;
- dashboards, extension view packages, maps, and custom visual encodings;
- push broadcasts from external data changes.
