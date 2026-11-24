# Governed saved views

`Selecto::Components::SavedView` checks and explains Explorer URLs without
executing their queries. `Selecto::Components::SavedQueryStore::Domains` is an
optional implementation of the existing saved-query store interface. Existing
host stores, including the legacy `save` method, remain supported.

## Check and explain

```perl
use Selecto::Components::SavedView;

my $checked = Selecto::Components::SavedView->check($config, $controller, $url);
# Or pass a form-input hash, or a Selecto::Components::State object.
# {ok => 1, url => '/explore/orders?...', state => {...}}
# {ok => 0, errors => [{option => 'field', field => 'absent', message => '...'}]}

my $description = Selecto::Components::SavedView->explain($config, $controller, $url);
```

`$config` is a `Selecto::Components::Config`. `$controller` is the acting
request's controller (or a compatible host context object accepted by its
engine factory and localization callbacks). Never substitute an administrator
engine for this context. Both calls resolve a request-local config, host query
options, the engine's domain and its read policy. They parse with `State` and
compile with `QueryBuilder` and that engine. Compilation may consult adapter
metadata; neither call executes the described Explorer query.

URL inputs must be relative, local to the exact Explorer path, and have no
fragment. State hashes use form parameter names (`field`, `group`, `measure`,
`filter_field`, `filter_op`, `filter_value`, etc.), rather than `State->as_hash`
output. Repeated parameters also accept the MCP builder's `[]` spelling; the
ordinary page loader shares that interpretation. Unknown options are refused.
Private URL Explorers refuse persisted URL state.

Check returns a normalized URL with page 1, matching save behavior. A rejected
field diagnostic includes `field` and `option`; other diagnostics include
`option` and `message`. No SQL or driver exception is returned. Draft filters
retain the ordinary page's draft behavior. Numeric values must match their
field's integer or numeric syntax, including numeric membership/range values.

Explain returns:

```perl
{
    kind => 'explorer_view', url => '/explore/orders?...',
    state => {...},              # State->as_hash; original page retained here
    view => 'detail',            # detail, aggregate or graph
    fields => [{field => 'order_ref', label => 'Order Ref', alias => '', format => ''}],
    filters => [{field => 'piece_count', label => 'Piece Count', op => 'gte', value => '2', value_end => ''}],
    groups => [], measures => [], sort => [{field => 'order_ref', direction => 'asc'}],
    period => undef,             # State as_of
    page_size => 25, omitted_fields => 0, errors => [],
}
```

Groups and measures include their State configuration (formats, aggregate
functions, aliases and graph options) and Explorer labels. Pivot is the
aggregate view's `aggregate_grid` / `pivot_column` state, not a fourth view
type. `state` retains these controls, query options, filters, sort and period.
Unreadable selections and their parallel aliases/values are removed; the
number of distinct unavailable field identifiers is `omitted_fields`.
Explain does not invent a detail selection if every submitted field was
removed. Malformed Explorer state has diagnostics; an unparseable request is
`{kind => 'invalid_explorer_view', errors => [...]}`. A different path (or an
external URL) is ordinary context:
`{kind => 'not_an_explorer_view', path => '/reports'}`.

## Sources

```perl
use Selecto::Components::SavedQueryStore::Domains;

my $store = Selecto::Components::SavedQueryStore::Domains->new(sources => [
    {
        name => 'personal', scope => 'user', scope_label => 'Personal',
        target_label => 'My views',
        engine_factory => sub ($c, $config, $source) {
            # A separate SQLite engine, with the user's read scope and
            # write_context. Its domain declares writes.row_revision,
            # host_bound_fields and unique_keys from selecto-perl stage 1.
            return personal_views_engine($c);
        },
        fields => {key => 'id', name => 'name', url => 'url'},
        write_check => sub ($c, $config, $operation, $row, $engine, $source) {
            return $c->stash('may_edit_personal_views') ? 1 : 0;
        },
    },
    {
        name => 'company', scope => 'client', scope_label => 'Company',
        target_label => 'Company views',
        engine_factory => sub ($c, $config, $source) {
            return company_views_engine($c); # May use PostgreSQL instead.
        },
        fields => {key => 'id', name => 'name', url => 'url', folder => 'folder_name'},
        readonly => 1,
    },
]);
# Pass saved_query_store => $store in the Explorer configuration.
```

Source configuration:

| Key | Meaning |
| --- | --- |
| `name` | Unique lowercase source identifier; also the destination id. |
| `engine_factory` | `($context, $config, $source) -> Selecto::Engine`; controls database, read scope, trusted write context and write grants. |
| `fields` | Required `key`, `name`, and exactly one of `url` or `state`. Optional `folder`, `parent`, `kind`. Values are declared root field identifiers. |
| `scope` | Existing scope value (`user`, `client`, `priv`) or a host scope identifier. |
| `scope_label` | Optional human label for the list. |
| `target_label` | Destination label for `targets`. |
| `readonly` | Refuses all mutations and excludes the source from `targets`. |
| `write_check` | Optional host callback shown above. Must return true to permit the operation. `insert` has no row; update/delete receive the stored mapped row and native `row_revision`. Exceptions fail closed. |
| `explorer_filter` | Optional `($row, $context, $config, $source) -> bool`. Default: local URL path equals the Explorer path; when `kind` is mapped, also requires `view_kind`. Required for state storage and for custom folder/menu selection. |
| `view_kind` | Value written to a mapped `kind` on insert; defaults to `view`. |

A state column stores a JSON object of form-input parameters. Its host filter
must identify the owning Explorer. Listing retains shared unreadable URLs;
validation happens on saves, never while deciding whether a shared view
appears. Other pages and other Explorers are excluded by the default filter.
A custom filter must likewise reject unrelated rows. To include folder nodes,
explicitly admit only the relevant tree's folders and map `parent` and/or
`folder`; use the existing host schema and its restrictive parent references.

The factory must return a SQLite, PostgreSQL, MySQL or MariaDB engine whose
domain declares `writes.row_revision`. `fields.key` must equal the domain's
single primary key. Sources do not share the Explorer adapter. DuckDB sources
are refused, including read-only sources. This package adds no database schema.

The domain's enabled operations and field grants remain mandatory. Factories
may resolve capability policy into request-specific domain grants; a
`write_check` can further narrow those grants per destination or row. The
store always calls `Engine->execute_write`; callbacks cannot enable a domain
operation or field that the core refuses. Missing grants refuse by default.
Owner/audit fields belong in `writes.host_bound_fields`, not caller input.
Read scopes are independently required: host owner bindings protect writes,
not listing. Configure the existing foreign-key tenant guard for authorized
parents; untrusted `parent`/`folder` insert values still pass core governance.

## Store calls and identity

All calls take `($context, $config, ...)`:

* `list` returns `{id, name, url, scope, scope_label?, readonly, revision,
  row_revision, folder?, parent?}` rows. Reads are paginated internally.
* `targets` returns writable insert destinations `{id, label}`.
* `save_new(..., {target, name, url})` checks the view and inserts it.
  `state` may replace `url`; optional mapped `folder`/`parent` are insert-only.
* `update(..., {id, name, url, row_revision})` checks the new view and updates
  only its mapped name and URL/state. All other columns stay unchanged.
* `delete(..., {id, row_revision})` removes that row with the revision check.

Mutation results are `{ok => 1, id => ...}`. Update/delete also accept the
existing UI member `revision`. `row_revision` is the exact native token,
including null, empty text or zero. The list's `revision` string is
`rv1.` followed by base64 JSON containing a one-element array of that token;
the store unwraps it before putting `row_revision` on the core write intent.
Old direct scalar revision arguments remain accepted.

Ids are `<source>.<base64url>` without padding. The payload is UTF-8 JSON of a
one-element array containing the primary key as text. They remain stable over
reloads, distinguish sources, and reject noncanonical/malformed encodings.
Ids and revisions are opaque, not authority. A fresh scoped read and write
policy precede every mutation. A missing row is stale. Existing rows outside
this Explorer's source filter are forbidden.

| Core failure | Store failure |
| --- | --- |
| `database_unique_violation` | `SAVED_QUERY_CONFLICT` |
| `stale_revision` (`changed` or `missing`) | `SAVED_QUERY_STALE` |
| required/invalid revision; missing listed row | `SAVED_QUERY_STALE` |
| `host_bound_field`, missing trusted context, denied operation/field/capability, parent or tenant refusal | `SAVED_QUERY_FORBIDDEN` |
| nonempty folder | `SAVED_QUERY_CONFLICT` |

These are existing `SAVED_QUERY_*: message` exceptions. Invalid checked views
raise `Selecto::Error` with code `SAVED_QUERY_INVALID` and
`details.errors` containing check diagnostics, suitable for a host API/MCP.
Unrecognized core failures remain structured core errors and are not mislabeled
as conflicts or authorization refusals. HTTP saves run the public check before
calling any store; folder-delete conflicts return HTTP 409.

Folder deletion checks all scoped child rows, including non-Explorer menu
entries. The store never issues child deletes. For concurrent child creation,
the host's parent reference must use `RESTRICT`/`NO ACTION`; a cascading host
schema is unsuitable for writable folders. Parent and child visibility must
share the host scope. The fixture uses restrictive foreign keys on both
SQLite and PostgreSQL. This stage does not claim a generic atomic tree lock or
change host tables.

## Stage 3 integration

Reuse the public check before an agent's mutation handler and explain for the
new tool. Do not rely on menu listing as the agent's domain listing: published
domains include other pages and menu entries. Preserve native `row_revision`
from core reads; `revision` is only the existing UI transport envelope.
The invented four-source fixture is in `t/lib/SavedViewsFixture.pm`. MCP builder
round trips use the optional sibling `Selecto::MCP::ExplorerURLBuilder` and do
not introduce a runtime dependency on selecto-perl-mcp.
