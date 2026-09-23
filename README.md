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

The Components-specific browser behavior lives in focused modules under
`src/browser/` (shell, charts, row dialog, grid, picker, filters, actions,
lookups, and action results). `npm run build` produces the single dependency-
free `public/selecto-components/selecto-components.js` file shipped to Perl
hosts. `npm run build:check` verifies that the committed distribution matches
those sources, and `npm run test:browser` exercises the compiled asset in
Chromium with Playwright.

## Current surface

- a reusable `Selecto::Components` Mojolicious plugin;
- an immutable resource contribution registry and request-time composer for
  host-owned workspaces, including named provider slots, deterministic panel
  ordering, fact-based applicability, and capability pruning without imposing
  shared-package branding or page styling;
- an optional Mojolicious route bridge that mounts every explorer endpoint
  beneath a host-owned `under(...)` route, so authentication and request setup
  are applied by normal route dispatch rather than application-wide path hooks;
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
  drag ordering, and accessible move-up/move-down controls; Available fields,
  groups, measures, sorts, and filters are arranged in collapsible source
  sections (with governed actions under Actions). Searching opens sections
  whose heading or fields match and restores their prior state when cleared;
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
  filters and auto-promote the selected group path as editable governed Detail
  predicates, including formatted dates, numeric/date buckets, and text prefixes;
- an Aggregate Grid presentation for exactly two Group By fields and one
  Aggregate, with sticky axes, independently toggleable cells, row/column/all
  selection controls, direct cell highlighting instead of visible per-cell
  checkbox clutter, selectable empty intersections for defining future views,
  and one explicit Detail submission. Header selections are
  atomic and never silently stop at the configured limit. A complete row or
  column becomes one axis condition; uncovered cells remain paired
  `(row AND column)` alternatives. Selections are ORed without creating a
  row/column Cartesian product. Submitted selections appear as compact,
  read-only Quick Filter cards with one remove control per selection. The grid also provides
  optional tenant-colored linear or logarithmic heat-map shading, full-matrix
  rendering, and grid-shaped Excel, CSV, TSV, and JSON exports;
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
- an optional dedicated Saved queries tab backed by a host-provided store;
  saved URLs are validated, canonicalized, and reset to page one while the
  host owns user, tenant, destination, and privilege scoping;
- a domain-selected private URL mode with WebSocket/POST body state and no
  query-state history, permalink, or query-string export link;
- Excel, CSV, TSV, and JSON exports for every row matched by the active query,
  independent of the current page, with incremental database/HTTP streaming
  for flat CSV, TSV, and JSON exports, disk-backed Excel generation, and
  spreadsheet-formula neutralization for delimited formats;
- an optional collapsible Query Debug panel with generated data/count SQL,
  bound parameters, execution timings, pagination, adapter, and row statistics;
  and
- a real PostgreSQL-backed Northwind example using the existing independently
  authored `selecto-perl-northwind` fixture.

The package is a behavioral workalike, not a source or API port of Phoenix
LiveView. It preserves the recognizable Explorer flow while using
Mojolicious-native transport and lifecycle boundaries.

The plugin entry point is intentionally small. Request behavior is separated
under `Selecto::Components::Controller` into explorer presentation, actions,
lookups, and saved queries. Hosts may mount routes beneath an authenticated
bridge while retaining canonical public paths:

```perl
my $protected = $app->routes->under('/reports')->to(cb => \&authenticate);
$app->plugin('Selecto::Components' => {
    route_bridge => {routes => $protected, prefix => '/reports'},
    explorers => {
        orders => {path => '/reports/orders', %order_explorer_config},
    },
});
```

The bridge owns authorization; Components only registers relative child routes
under it. The configured explorer path remains the public canonical URL used
by forms, WebSockets, exports, actions, and saved queries.

## API Console contract

The API Console browser code is owned by the sibling `selecto-api-console`
repository and packaged as `@selecto/api-console`. This Perl distribution
ships generated `0.5.0` assets so Mojolicious applications remain
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
      data-curl-auth="basic"
      data-title="Orders API Console"></main>
```

An Explorer can expose a capability-aware `API` control beside its exports by
supplying an `api_console_resolver`. Return the same-origin console path when
the current request may read that API domain, or an empty string to hide it.

```perl
api_console_resolver => sub ($controller, $config, $model) {
    return '' unless MyApp::Authorization->can_read_orders_api($controller);
    return '/api2/orders/v1/console';
},
```

For detail views, Components translates the normalized columns, aliases,
formats, filters, named segments, ordering, and current page into a canonical
API request. The request travels in the URL fragment, so it is not included in
the HTTP request or server logs, and the API Console loads it into its chooser.
Aggregate queries and grouped/grid drilldown predicates remain visible as a
disabled API control because the canonical API does not yet represent those
semantics.

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
Hosts configure generated cURL authentication with `curl_auth`/`data-curl-auth`:
`basic` emits username/password placeholders, `cookie` (the default) emits a
session-cookie placeholder, and `none` omits authentication arguments.
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

### Saved-view host interface

`saved_query_store` is an application-owned object. The minimal legacy
contract remains `list($controller, $config)`, `save($controller, $config,
{name, url})`, and `delete($controller, $config, {name})`. Hosts that support
multiple destinations and guarded edits can additionally implement:

- `targets($controller, $config)` → `[{id, label}, ...]` for destinations the
  current user may write. Recheck permissions in the write methods; options
  in HTML are not an authorization boundary.
- `list(...)` → `[{id, name, url, scope, folder?, readonly?, revision}, ...]`.
  `id` identifies the stored record across scopes; `revision` is an opaque
  optimistic-concurrency token. Only return items readable by this user and
  whose URL belongs to this Explorer endpoint.
- `save_new(..., {name, url, target})` → `{id}`. It must refuse an existing
  name in that destination, even if the existing record belongs to another
  endpoint; never silently replace it.
- `update(..., {id, name, url, revision})` → `{id}`. It must reauthorize the
  item and reject a stale revision. The browser presents an explicit overwrite
  checkbox and keeps Save new separate from Update this view.
- `delete(..., {id, name, revision})` reauthorizes and, when a revision is
  supplied, rejects stale deletes.

The generic UI knows nothing about storage tables, workgroups, folders, or
email delivery. A host may implement those behind this interface. Scheduled
exports can later reference a saved-view `id` and delegate recipient policy
and delivery to a separate host service; no scheduling is implied by saving a
view.

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
- `aggregate_grid`, `aggregate_grid_colorize`, and
  `aggregate_grid_color_scale` (`linear` or `log`) when Aggregate Grid is active;
- `row_click_action`: the selected portable Detail action, when one is active;
- repeated `field` and `group` values; `field` order is the selected result-column order;
- aligned `field_alias`/`field_format` and group alias/format/bucket/prefix values,
  so each selected column carries its own presentation configuration;
- aligned, repeated `filter_field`, `filter_op`, `filter_value`, and
  `filter_value_end` values; server-generated aggregate drilldowns also align
  a `filter_group` marker so the governed grouping expression is reused as the
  Detail predicate. Multi-cell grid drilldowns and ordinary alternative filters
  align `filter_clause` markers: conditions in one numbered clause use AND,
  while numbered clauses use OR. Ordinary filters without a clause apply to
  every alternative. A host can expose a domain-internal key only in the
  filter picker with `filter_fields => ['association.key']`; this does not add
  it to selectable Detail columns. When the domain declares
  `components.filter_choices` for a path, the filter picker shows named
  options in a single- or multi-select (depending on the operator), submitting
  stable values through the same canonical `filter_value` parameter. Such
  internal filter fields are available without adding them to Detail columns.
  A domain-defined conditional choice exposes one virtual filter backed by
  separate physical fields; `filter_picker_hidden_paths` hides legacy fields
  from Available while preserving their saved URLs and validation.
  Column and generated aggregate pickers hide numeric IDs except the root ID
  and `client_profile` IDs; the paths remain valid for saved views, and the
  domain may explicitly expose another with `components.picker_visible_id_paths`.
  The browser's repeated `grid_cell` JSON pairs are a bounded submission format
  only and are replaced by these validated canonical filters;
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
Hosts can set `picker_hidden => 1` on a segment retained for saved-link
compatibility. It is omitted from new selections but remains visible and
removable when an existing query selects it.
`query_library.segment_picker_groups` renders domain-declared alternatives as
radio groups with an Off default. The form submits the chosen segment through
the same canonical `query_library_segment` state, so existing saved URLs and
API requests do not change. An old URL selecting conflicting alternatives is
shown as invalid until the user chooses one.

Projection association shapes are adapted to the Perl component builder as
validated dotted field paths. Parameter values are type-checked by
`selecto-perl` and remain bound values in the compiled statement.

For a canonical join with `type => 'star_dimension'`, grouping either its
`dimension_key` or configured joined `display_field` shows the dimension name
but groups on the key. The key is carried as a hidden result column, so clicking
the displayed name creates an exact, direct predicate such as `status = 'D'`.
Star dimensions intentionally do not offer bucketing or prefix formats because
their name/key pair is the grouping unit.

## Native-template instance storage

`Selecto::Components::Templates::InstanceStore::Memory` supports tests and one
worker. Hosts that may serve one private template instance from multiple workers
use `Selecto::Components::Templates::InstanceStore::PostgreSQL`:

```perl
use Selecto::Components::Templates::Dispatcher;
use Selecto::Components::Templates::InstanceStore::PostgreSQL;

my $store = Selecto::Components::Templates::InstanceStore::PostgreSQL->new(
    dbh_provider => sub { $request_worker->dbh },
    table => 'app_runtime.selecto_template_instances',
    max_snapshot_bytes => 1_048_576,
    max_ttl_seconds => 86_400,
    cleanup_limit => 1_000,
);
my $dispatcher = Selecto::Components::Templates::Dispatcher->new(store => $store);
```

`Dispatcher` is the stable host facade. `InstanceService` owns scoped instance
lifecycle and compare-and-set persistence, `EventDispatcher` owns typed browser
events, and `EffectCoordinator` applies source completions. `SourceExecutor`
remains the separate boundary that attaches fresh host authority and performs a
query. This keeps storage, event handling, query execution, and future effect
leasing independently replaceable without changing route code.

The provider supplies a DBI-compatible PostgreSQL handle already owned by the
current request worker. The store neither retains nor disconnects it, and the host
must not share one handle across workers. Apply the statements from
`schema_sql` through the host migration system; `install_schema` is available for
development and disposable tests. The schema includes a child effect-claim table;
set `claims_table` when the host needs an explicit name alongside a custom instance
table.

Before executing a source effect, a worker obtains a short server-side lease:

```perl
my $claim = $dispatcher->claim_effect(
    owner_scope => $owner_scope,
    instance_id => $instance_id,
    effect => $effect,
    lease_seconds => 30,
);

if ($claim->{status} eq 'claimed') {
    my $completion = execute_source_outside_the_store_transaction($effect);
    my $result = $dispatcher->complete_claimed_effect(
        owner_scope => $owner_scope,
        instance_id => $instance_id,
        manifest => $manifest,
        claim_token => $claim->{claim_token},
        completion => $completion,
    );
}
```

A `busy` result means another worker owns that source generation. An expired lease
can be replaced with a new opaque token. The old token then receives `claim_lost`
and cannot commit. Hosts should choose a lease longer than their enforced query
timeout and keep tokens in server-owned request state.
`cleanup_expired_claims` removes abandoned leases with the same configured hard
row limit used for instance cleanup.

Owner scope is canonicalized and stored only as a SHA-256 digest. Instance IDs are
opaque references. Snapshots remain server-side, have a configurable byte limit,
and are updated by an atomic revision-checked statement. Stale writers receive a
conflict with the current storage revision. Expiry uses PostgreSQL's clock, and
`cleanup_expired` deletes no more than the configured row limit per call. Database
exceptions are returned by the dispatcher as the bounded
`instance_store_unavailable` error.

The store is ephemeral recovery infrastructure rather than business persistence.
It does not make business writes idempotent. Effect leases prevent duplicate source
query execution for one instance/source/generation when the host follows the
claim/complete flow; operation-layer receipts and idempotency remain necessary for
business writes.

## Native-template HTTP plugin

### Server-owned update forms

`Selecto::Components::Templates::Form` connects a compiled native update form
to the same owner-scoped instance stores used by native read templates. A host
supplies `resolve_form`, `load_record`, and `write_record` callbacks. Resolve
the form and record for the authenticated owner and tenant on every request;
the browser supplies only an opaque instance, operation, path, field value,
and expected revision. The service checks the current contract fingerprint,
validates declared fields and exact nested row identities through
`Selecto::Templates::FormState`, and uses store compare-and-set before returning
the next draft. It generates new nested draft identities on the server.

`write_record` receives `(owner_scope, record_id, form, baseline, draft)`. It
must recheck tenant/record membership and the baseline within its own database
transaction, apply explicit create/update/delete intents through the host's
mutation engine, and return `{status => 'ok'}` only after commit. Failed writes
leave the draft available at a new revision; successful writes seal that
instance as `saved`. A fresh GET opens a new authorized draft. An abandoned
`saving` reservation expires with the instance; hosts should use transactional
idempotency receipts if they need automatic retry after a worker failure.

The host owns Mojolicious routes, CSRF protection, validation display, and
escaped HTML. Ordinary POST and HTMX fragment requests can use the same
`change`/`save` operations and response model. The executable
`t/templates_form_http.t` shows both paths with nested edits, owner isolation,
stale revision rejection, host write conflict, and contract re-resolution.

`Selecto::Components::Templates` is an additive Mojolicious plugin for private
native-template pages. It does not require or alter the explorer plugin. The host
installs pinned compiled manifests and renderer callbacks, resolves authenticated
owner scope for every request, and supplies fresh source authority:

```perl
plugin 'Selecto::Components::Templates' => {
    store => $template_instance_store,
    source_max_workers => 4,
    source_timeout_seconds => 15,
    websocket_inactivity_timeout => 3600,
    websocket_heartbeat_interval => 30,
    resolve_owner => sub ($controller) {
        my $actor = authenticated_actor($controller)
            or return {status => 'unauthenticated'};
        return {status => 'ok', owner_scope => {
            tenant_id => $actor->tenant_id,
            actor_id => $actor->id,
            session_id => $controller->session('template_session_id'),
        }};
    },
    templates => {
        order_browser => {
            release_id => 'order-browser-2026-09-22',
            manifest => $compiled_order_browser,
            registry => $template_renderer_registry,
            public_inputs => [qw(status customer_id)],
            ttl_seconds => 3600,
            lease_seconds => 30,
            source_timeout_seconds => 15,
            resolve_inputs => sub ($controller) {
                return trusted_server_inputs($controller);
            },
            resolve_source_context => sub ($controller, $owner_scope, $effect) {
                return {
                    tenant_id => $owner_scope->{tenant_id},
                    actor_id => $owner_scope->{actor_id},
                };
            },
            source_authorizer => sub ($source_context, $source, $effect) {
                my $engine = fresh_tenant_scoped_engine(
                    $source_context->{tenant_id},
                    $source_context->{actor_id},
                    $source,
                );
                return {status => 'ok', engine => $engine, query => $engine->query};
            },
        },
    },
};
```

The plugin adds these ordinary HTTP routes by default:

| Route | Purpose |
| --- | --- |
| `GET /templates/:id` | Mount an opaque owner-bound instance and render the full page |
| `POST /template-instances/:instance/events` | Normalize and dispatch one declared event |
| `POST /template-instances/:instance/sources/:source` | Claim and execute one current declared source generation |
| `WS /template-instances/:instance/ws` | Dispatch typed events with the pinned HTMX 4 WebSocket envelope |

`template_path` and `instance_path` can replace the two prefixes. Every response is
private and `no-store`; state-changing requests require the session-bound Mojolicious
CSRF token. POST responses return the same stable instance root as an HTML fragment
when `HX-Request: true`, and a complete page otherwise. The root carries state and
store revisions, disables HTMX history snapshots, and pending source forms use the
packaged htmx runtime with an ordinary submit fallback. It also declares the htmx 4
status policy explicitly: bounded 4xx and 5xx fragments replace the stable root.
Browser tests pin successful swaps plus 409 conflict and 422 validation behavior.

`public_inputs` is the host's explicit allowlist for bookmarkable GET filters. Each
name must be an input declared by the compiled manifest with type `string`, `integer`,
or `boolean` (including optional forms). Unknown, repeated, oversized, and incorrectly
typed query values fail before an instance is allocated. Valid values are decoded to
their manifest types, merged with non-overlapping trusted values from `resolve_inputs`,
and then mounted; a compiled source can bind them as `input.status` or another declared
input when constructing its query. The host still supplies tenant scope and fresh source
authority independently. Query parameters are ordered by the manifest, noncanonical
requests redirect before mount, and the successful page emits both `Content-Location`
and a canonical link. Templates without an allowlist reject all query parameters.

Component renderer callbacks receive their existing node data plus a server-built
`transport.events` descriptor for each declared event. The descriptor contains the
POST action, `hx_ws_send`, htmx target/swap values, and hidden fields
(`template_action`, `csrf_token`, `event`, `event_id`, and `state_revision`). Render
the form with `hx-ws:send`, render those fields as escaped values, and keep the
editable browser value named `value`. Its action and method remain the ordinary POST
fallback. The controller rejects missing, repeated, and extra fields before dispatch.

The complete page keeps a stable `hx-ws:connect` channel outside the replaceable
template root and loads the packaged `hx-ws` runtime. Typed event replies use the
same `{content,target,swap}` envelope as the existing Explorer and carry state/store
revision metadata under `selecto`. Handshake and every event re-resolve the opaque
instance against authenticated owner scope. Each event also requires the masked
session CSRF token. Same-origin validation, a 128 KiB frame ceiling, configurable
inactivity timeout, and protocol heartbeat reuse the shared WebSocket policy. Policy
failures close with 1008; malformed JSON closes with 1003; oversized frames close
with 1009. The HTTP event route remains available to browsers without JavaScript or
when the WebSocket extension falls back to the form action.

The browser never supplies the manifest, source plan, owner scope, adapter, or query.
For a source POST, the controller loads the owner-bound snapshot, reconstructs the
current effect, obtains a generation lease, reduces request authority to a bounded
JSON-safe source context, and schedules `SourceExecutor`; the template can only narrow
the fresh host query. `resolve_source_context` runs in the web process and must return
data rather than a controller, cookie, handle, or service object. `source_authorizer`
runs in the source child and must create its engine and DBI handle there. The default
context contains only `owner_scope` when no resolver is configured.

The built-in `SourceScheduler` uses Mojolicious subprocesses with a per-web-process
concurrency bound. `source_max_workers` defaults to 4, and excess work returns a
bounded 503 after releasing its effect claim. `source_timeout_seconds` defaults to 15
and must be lower than every source template's lease; a template can select a lower
timeout. Timed-out children receive `TERM`, then `KILL` after a short grace period,
and their typed timeout completion is applied by the parent only while the claim is
still current. Payloads and results cross a JSON boundary and default to a 1 MiB
limit; `source_max_payload_bytes` and `source_max_result_bytes` can lower or raise
that bound up to 16 MiB. A host can inject an object implementing `execute` as
`source_scheduler` when it needs an existing supervised worker service.

The route test starts a slow source and an unrelated HTTP request concurrently. The
unrelated route completes first, while child-process audit evidence confirms that
source authorization and DB-handle creation run outside the web process. Scheduler
tests also cover capacity rejection, event-loop progress, JSON isolation, result
limits, timeout, and forced termination of a child that ignores `TERM`.

### Native EP helpers

The same plugin installs four trusted server-side helpers for applications that
want ordinary Mojolicious EP markup instead of the generic compiled renderer:

```perl
my $model = $controller->selecto_template_model(
    template => 'order_browser',
    instance_path => '/native-template-instances',
    target => '#native-order-browser',
);

my $next = $controller->selecto_template_dispatch_event(
    instance => $controller->stash('instance'),
    instance_path => '/native-template-instances',
    target => '#native-order-browser',
);

my $scheduled = $controller->selecto_template_dispatch_source(
    instance => $controller->stash('instance'),
    source => $controller->stash('source'),
    instance_path => '/native-template-instances',
    target => '#native-order-browser',
    on_finish => sub ($next_model) {
        return $controller->render(template => 'orders/native', model => $next_model);
    },
);

$controller->selecto_template_websocket(
    instance => $controller->stash('instance'),
    instance_path => '/native-template-instances',
    target => '#native-order-browser',
    render => sub ($next_model) {
        return $controller->render_to_string(
            template => 'orders/native', model => $next_model,
        );
    },
);
```

`selecto_template_model` accepts exactly one of `template` (mount a new instance)
or `instance` (load an existing owner-bound instance). The returned
`selecto.template.native-model.v1` object contains cloned input/state values,
projected source rows or bounded source errors, and server-built event/source form
descriptors. EP templates render the supplied actions, HTMX target/swap metadata,
CSRF fields, component lifetime, and revisions as escaped values. Editable event
values stay in the field named by `input_name`. The `transport` object supplies a
stable channel ID and WebSocket path; event descriptors advertise `hx_ws_send` when
the EP chooses the packaged HTMX WebSocket transport.

The dispatch helpers use the same owner resolution, CSRF validation, component
identity, effect leases, source workers, reducer, and instance store as the generic
routes. The model excludes the compiled manifest, owner scope, adapter, database
handle, and source-authority callbacks. These are host helpers rather than public
browser APIs: applications provide their own native routes, error rendering,
private-cache headers, and full-page versus fragment layout. The source helper is
asynchronous; render later when it returns `scheduled`, and complete the response in
`on_finish`. The WebSocket helper installs the same handshake, owner, origin, CSRF,
event-envelope, and revision checks as the generic route, but its `render` callback
returns the host's EP fragment for the stable native target. A native WebSocket route
therefore does not fall back to generic component markup.

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
            max_grid_cells => 50,
            max_grid_result_cells => 10_000,
            max_orders => 10,
            show_sql => 0,
            websocket_message_cleanup => sub ($controller, $config) {
                MyApp::Database->release_request_resources($controller);
            },
        },
    },
    websocket_inactivity_timeout => 3600,
    websocket_heartbeat_interval => 30,
};
```

`websocket_message_cleanup` runs after each valid WebSocket message, including
messages whose query or rendering fails. Hosts that lease database connections
or other request-scoped resources through the controller should release them
there; a WebSocket controller otherwise lives far longer than an ordinary HTTP
controller. Cleanup failure closes the socket with a generic server-error
message rather than leaving partially released resources attached to it.

`websocket_inactivity_timeout` applies to every explorer registered by the
plugin and defaults to one hour. It may be set from 30 seconds through 24 hours.
Choose it together with the reverse proxy's WebSocket idle timeout and client
reconnection policy.

`websocket_heartbeat_interval` defaults to 30 seconds and sends protocol-level
ping frames so idle browser sessions remain visible to intervening proxies.
Browsers answer with pong frames without exposing heartbeat messages to the
application. Set it to `0` to disable it, or to 15–300 seconds to tune it.

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

Use `type => 'record_editor'` to open a native, lazily loaded editor instead of
an iframe. The action payload names an entry in the canonical domain's
`editors` registry and the root field used as its stable target:

```perl
writes => {
    operations => {update => {enabled => 1}},
    fields => {
        product_name => {updatable => 1},
        unit_price   => {updatable => 1},
    },
},
editors => {
    product_profile => {
        label => 'Edit product',
        fields => [
            {field => 'product_name', required => 1},
            {field => 'unit_price', control => 'number', nullable => 1},
        ],
        actions => ['retire_product'],
    },
},
detail_actions => {
    edit_product => {
        name => 'Edit product', type => 'record_editor',
        required_fields => [qw(id product_name)],
        payload => {
            editor => 'product_profile', target_field => 'id',
            title => 'Edit {{product_name}}', size => 'lg',
        },
    },
},
```

The component fetches the record through the request-specific governed domain,
signs its original editable values, validates CSRF and submitted field names,
and updates with `expected_count => 1`. Those original values form the
optimistic-concurrency predicate, so a competing edit returns HTTP 409. After
success the browser re-fetches the same governed Explorer result before
replacing the row. A row that leaves the result remains as a disabled visible
tombstone until refresh; a row that leaves authorization is reduced to safe
identity only. Dirty forms warn before Close or Previous/Next navigation.

Published editor actions are rendered as explicitly separate operations. They
are not silently chained to profile Save. A host that needs audit or a shared
transaction coordinator can provide `record_editor_handler`; it receives the
effective domain, editor, target, signed originals, normalized changed
assignments, and a `default_save` callback. Successful profile saves and editor
actions keep the dialog open by default, refresh the result row, and reload the
signed editor state. A record-editor handler or action handler may return
`close_dialog => 1` when completion should close the dialog instead.

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
        inputs => {
            note_type => {
                label => 'Note type', type => 'select',
                choice_source => 'note_types', required => 1,
            },
            comment => {
                label => 'Comment', type => 'textarea',
                required => 1, max_length => 255,
            },
        },
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

Actions that must operate on one result row can declare cardinality and their
placement in the domain. `row_dialog` renders an action button in every row and
opens the governed input form in a dialog. `row_inline` renders the governed
inputs and submit button directly in each row. Neither presentation renders
bulk-selection checkboxes or the action toolbar.

```perl
assign_equipment => {
    label => 'Assign driver and trailer',
    scope => 'row',
    selection => {
        mode => 'rows',
        min_rows => 1,
        max_rows => 1,
        presentation => 'row_dialog', # or row_inline
    },
    inputs => [...],
    execution => {kind => 'host', operation => 'assign_equipment'},
},
```

`presentation` defaults to `toolbar`. All presentations honor `min_rows` and
`max_rows`; the server validates those limits even if a caller bypasses the
browser. Row presentations require `mode => 'rows'` and `max_rows => 1`.

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
        eligibility_field => 'load_build_eligible',
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
and are not submitted to the handler. `eligibility_field` should normally name
an internal boolean domain field. Selecto adds it to the data query as a hidden
selection, so each row's selection control is governed without a second query
or per-row host calls. The display hint does not replace authorization and
business-rule checks during execution.

Legacy hosts may name a synthetic `__field` and configure an
`action_eligibility_resolvers` callback. This compatibility mode is slower and
is intended only for rules that cannot be represented by a governed SQL-backed
domain field.
A `lookup` input uses the authenticated
`GET /explore/products/actions/:action_id/lookups/:input_id` route and the
corresponding host-owned `lookup_sources` callback. Results are normalized to
`value`, `label`, and optional `description`; the chosen value, not its label,
is submitted to the action handler. Lookup discovery reuses action
authorization and includes the active group's selected row IDs so the host can
apply tenant, eligibility, and row-level rules.

```perl
action_eligibility_resolvers => {
    load_build => sub ($controller, $request) {
        # $request->{row_ids} contains the governed result-page targets.
        return {map { $_ => can_build_load($_) ? 1 : 0 } @{$request->{row_ids}}};
    },
},
```

For reusable object lookups, prefer a domain-declared co-domain over a
host-rendered result query. The source domain names the target domain's
governed query-library pieces and result mapping:

```perl
co_domains => {
    carriers => {
        domain => 'client',
        segments => [qw(carriers available_for_dispatch)],
        projection => 'carrier_lookup',
        ordering => 'company_name',
        search => {
            fields => [qw(id co_name cl_key city state)],
            mode => 'prefix', rank => 1,
        },
        result => {
            value_field => 'id', label_field => 'co_name',
            description_fields => [qw(id cl_key city state)],
        },
    },
},

# In the action input:
{ id => 'carrier_id', type => 'lookup', co_domain => 'carriers' }
```

The Components host resolves only trusted server-side engines and any
selection-derived narrowing predicate:

```perl
co_domain_engines => {
    client => sub ($controller) {
        return tenant_scoped_client_engine($controller);
    },
},
co_domain_scopes => {
    carriers => sub ($controller, $request, $engine) {
        return Selecto::Expression->in(
            'id', carrier_ids_allowed_for($request->{selected_ids}),
        );
    },
},
```

The target engine's required tenant predicate remains in force, the callback
predicate can only narrow the query, and the action handler remains responsible
for revalidating the submitted object before executing a write. Host
`lookup_sources` remain supported for inherently application-specific choices.

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

`max_grid_cells` defaults to 50 and may be configured from 1 through 100. It
bounds the compact row, column, and cell alternatives produced by an
interactive grid selection and accepted by server-side parsing.

`max_grid_result_cells` defaults to 10,000 and may be configured from 100
through 100,000. The aggregate query reads at most one sentinel row beyond
that ceiling, and the renderer also checks the dense row-by-column matrix.
Oversized grids are rejected with guidance to add filters or choose
lower-cardinality groups instead of exhausting the application worker or
browser.

Aggregate tables and Grid axes retain the natural order of governed temporal
formats. In particular, weekday names follow ISO weekday order (Monday through
Sunday), numeric years and date parts sort numerically, and canonical ISO date,
week, month, quarter, and time labels sort chronologically. Grid axes are sorted
after all distinct values have been collected, so sparse matrices cannot inherit
an incorrect first-seen order.

Adapters that advertise `stream` support use `stream_query` for flat exports.
CSV, TSV, and JSON are emitted incrementally with backpressure from the HTTP
connection. Excel is written to a temporary file with the writer's optimized
memory mode and split at Excel's worksheet row limit before Mojolicious serves
the completed file. Aggregate grids retain their bounded materialized export
because their output depends on the complete two-dimensional matrix.

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
  session-bound, per-render masked Mojolicious CSRF token. Previously opened
  forms must be reloaded after upgrading from the custom token implementation.
  An action that declares a capability stays hidden
  unless the explorer registers an `action_authorizer`.
- WebSocket handshakes with an `Origin` header require matching scheme, host,
  and effective port. Requests without an Origin remain supported for native clients. A host
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

Perl 5.34+, Mojolicious 9.49+, and the native `selecto-perl` sibling are
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
