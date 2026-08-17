# Selecto Components Perl

`selecto-perl-components` is a server-rendered Mojolicious workalike for the
core exploration flow in Elixir's `selecto_components`. It sits directly on
native [`selecto-perl`](https://github.com/seeken/selecto-perl): Selecto owns the
domain, immutable query, adapter compilation, bound values, and execution;
this package owns validated browser state, HTML, WebSockets, and assets.

This is alpha software. Its browser transport is pinned to htmx
`4.0.0-beta6`, which is itself a prerelease.

## Current surface

- a reusable `Selecto::Components` Mojolicious plugin;
- separate View and Filters builder tabs, with active-tab continuity across
  WebSocket fragment replacements;
- locally staged builder edits with an explicit Run boundary, so unfinished
  view, column, filter, sort, and pagination changes do not execute queries;
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
- Detail, Aggregate, and Graph result views;
- domain-declared selected-row bulk actions with select-all-page controls,
  hidden primary-key selection, typed action forms, dynamic host choices,
  preview/execute authorization callbacks, CSRF protection, and server-side
  input revalidation;
- total matched-row and page counts, with changed query intent resetting to
  page one while page-only Run and Previous/Next retain explicit pagination;
- hierarchical Aggregate rollups with clickable group values, subtotals, and a
  grand total, plus clickable Graph group values; drilldowns retain existing
  filters and apply the selected group path as exact governed Detail predicates,
  including formatted dates, numeric/date buckets, and text prefixes;
- `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between`, `in`, `is_null`, and
  `not_null` filters supported by the current native Perl query contract;
- a domain-derived Available/Set aggregate picker where every governed column
  can be configured with type-aware `count`, distinct-count, average, sum,
  min/max, boolean-count, and buckets, alongside optional curated presets;
- relationship fields, sorting, bounded limits, and offset pagination;
- htmx 4 `hx-ws` updates using server-rendered HTML fragments;
- ordinary HTTP GET fallback, permalinks, and browser-refresh recovery;
- a domain-selected private URL mode with WebSocket/POST body state and no
  query-state history, permalink, or query-string export link;
- CSV export with spreadsheet-formula neutralization;
- optional compiled SQL display for development; and
- a real PostgreSQL-backed Northwind example using the existing independently
  authored `selecto-perl-northwind` fixture.

The package is a behavioral workalike, not a source or API port of Phoenix
LiveView. It preserves the recognizable Explorer flow while using
Mojolicious-native transport and lifecycle boundaries.

## State and transport contract

The URL query string is canonical by default. A WebSocket is only a faster
transport for the same state:

1. A direct `GET /explore/products?...` normalizes and validates query params.
2. The form sends the same named fields over htmx 4 as `{headers, body}` JSON.
3. The server runs the same state parser and Selecto query builder.
4. It returns a correlated JSON message containing server-rendered HTML and a
   canonical URL.
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
redirects away inbound query state, removes permalink and query-string CSV
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
- `GET /explore/products?format=csv` for the current result page; and
- `WS /explore/products/ws` for htmx 4 incremental updates.

## Selected-row actions

Selected-row actions come from the canonical domain contract. The Components
host only renders actions that are bulk-scoped (or explicitly bulk-enabled)
and have a registered host handler. Required action fields are normalized and
validated again on POST; select choices are resolved again for the current
request so a stale browser cannot submit a choice that the user can no longer
use.

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

The vendored assets are exactly `htmx.org@4.0.0-beta6`:

| Asset | SHA-256 |
| --- | --- |
| `htmx.min.js` | `28fae7bbe8e8142b702debb9d5234a9a436d9435a4b5165b195aa1a7ed840d25` |
| `hx-ws.min.js` | `b20cdc95e0bc9ab49f8ab581251bb32cc96d7eaa2e68d1405114cee57b1eff7e` |

The UI uses the htmx 4 names `hx-ws:connect` and `hx-ws:send`. Incoming server
messages set `content`, `target`, `swap`, and `HX-Request-ID` according to the
[official htmx 4 WebSocket extension contract](https://four.htmx.org/extensions/hx-ws).
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
- Raw SQL is hidden unless the host explicitly enables `show_sql`.

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
redirection, static assets, CSV export, and real Mojolicious WebSocket message
round trips.

That is bounded evidence for the included domains, states, transport envelopes,
and test adapter results. It is not proof of arbitrary schemas, adapters,
databases, browser versions, proxy settings, accessibility, concurrency,
security, or performance.

## Explicitly deferred

- persisted saved-view stores and sharing policy;
- row and bulk action forms;
- emailed and scheduled exports;
- dashboards, extension view packages, maps, and custom visual encodings;
- push broadcasts from external data changes; and
- compatibility with htmx 4 final until that release exists and is tested.
