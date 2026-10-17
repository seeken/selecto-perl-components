# Perl / PostgreSQL / HTMX / Vue initial stack

This disposable example serves native HTMX and `selecto_spa_vue` from one
Mojolicious application. Both interfaces obtain a fresh, session-scoped engine
from the same explorer configuration and execute through the core bounded
reader. Vue uses the public shared canonical adapter and real JSON endpoints.

## Run it

Check out sibling `selecto-perl`, `selecto-perl-components`, `selecto_spa_vue`,
`selecto-api-console` and `selecto-protocol`. Install their declared Perl and
npm dependencies with their normal package workflows. Perl needs `DBD::Pg`.
Build the Vue example from `selecto_spa_vue`:

```sh
npm ci
npm run build:perl-postgres
```

Create a fresh database on a PostgreSQL service you own. Its name must start
with `selecto_perl_stack_`; the example rejects other names. From
`selecto-perl-components`, set its URL in your local environment, then run:

```sh
export SELECTO_PERL_STACK_POSTGRES_URL=postgres://localhost/selecto_perl_stack_demo
mise run stack:setup
mise run stack:server
```

The URL above assumes your PostgreSQL role, port and authentication are already
configured. Keep credentials in local environment settings. Setup creates the
synthetic table once in a transaction. It refuses an existing table and never
drops, truncates or silently reseeds it. Do not point it at an application DB.

Open `http://127.0.0.1:4187/session`, choose Alpha or Beta, then visit
`/explore/items` for HTMX or `/vue` for Vue. This session picker is test/demo
authentication; the example refuses production mode. Override the listener
with `SELECTO_PERL_STACK_HTTP_PORT`. Vue assets are served from its sibling
`dist/perl-postgres` directory; rebuild after changing the Vue source.

## Host configuration

An existing explorer opts into the JSON routes with these trusted settings:

```perl
items => {
    path => '/explore/items',
    engine_factory => sub ($c) { authenticated_scoped_engine($c) },
    default_fields => [qw(id name amount)],
    default_limit => 25, max_limit => 100,
    canonical_api_path => '/api/items',
    canonical_authorizer => sub ($c) { authorized_reader($c) ? 1 : 0 },
    canonical_publication => sub ($c, $engine) { principal_publication($c, $engine) },
    canonical_field_encodings => {large_integer => 'decimal-string'},
}
```

The callbacks above belong to your host. The factory must derive tenant scope
from trusted authentication. Publication identifies the principal's public
metadata cache; it does not grant row access. Hidden fields remain unavailable
to public selections, filters and orderings. The host's route bridge must
protect the native explorer as well as the canonical authorizer protecting
every JSON request. JSON POSTs require the current session's `X-CSRF-Token`
and the existing Components same-origin policy. This integration currently
uses cookie sessions; a Bearer-only transport needs its own reviewed host
authentication/CSRF policy.

The canonical base serves its manifest, `/catalog`, `/explorer`, `/openapi.json`
and `POST /query`. Complete `/domain` publication defaults to forbidden; set
`canonical_publish_domain => 1` only when your authenticated audience may read
the complete authored contract, including internal policy metadata. The example
explicitly opts in for its synthetic contract.

## Verify the stack

After setup and the Vue build, from `selecto-perl-components` run
`mise run test:canonical-stack`. From `selecto-perl`, set
`SELECTO_PERL_TEST_POSTGRES_URL` to an owned test database and run
`mise run test:remote-query`. Both tasks require real PostgreSQL and fail when
its URL is missing. The core test creates connection-local temporary tables.

This sibling workspace also provides `mise run perl-stack:verify` from its
root. With the initialized stack URL exported, it runs the focused core
checks, builds Vue, runs native HTTP checks and runs the five browser journeys.
It does not create or stop PostgreSQL; its operator owns the database lifecycle.

From `selecto_spa_vue`, with the same `SELECTO_PERL_STACK_POSTGRES_URL`, run:

```sh
npm run test:perl-postgres
```

Playwright owns the temporary HTTP server and refuses to reuse an existing
one. Stop a manually started stack server first, or choose a different port.
The five journeys cover independent direct API calls, real HTMX WebSocket
paging, Vue run/page/reload/filter controls, two-session isolation, and native
HTTP paging with JavaScript disabled. Reports, traces and screenshots are in
`test-results`. These integration checks complement each repository's full
verification task and distribution checks.

## Current boundary and remaining work

The first JSON reader supports explicit root scalar selections, aliases,
array/object rows, integer/decimal/string/boolean/date codecs, eight flat
comparison/null operators, ordering and positive bounded offset pages.
Nonunique caller sorts retain their order and append the public primary key
as a tie breaker. One lookahead row establishes `has_more`; JSON paging does
not run a total count. Native HTMX keeps its existing richer native views.

The JSON reader returns an explicit unsupported response for richer intent:
aggregates/graphs, nested relations, recursive filters, named query-library
intent, temporal formats and mandatory extra output/grouping/order policies.
It also requires a public root primary key. Export, editor, saved-query and
action services are not advertised by this example. Extending these needs
matching protocol semantics, metadata and executable UI/API coverage.

This is executable development evidence, not formal profile admission. The
central runner now includes its real specification-2.33 observers. From the
sibling workspace root, `mise run perl-stack:certify` runs unchanged native
query/collection cases with Go/PostgreSQL and canonical/tenant cases with
Elixir/PostgreSQL as independent peers. Configure three separately owned,
disposable databases through `SELECTO_CERT_PERL_POSTGRESQL_URL`,
`SELECTO_CERT_GO_POSTGRESQL_URL` and `SELECTO_CERT_POSTGRESQL_URL`. Reports go to
a fresh directory, or a nonexisting `SELECTO_PERL_STACK_CERT_OUTPUT` directory.
Use a coherent compiler/SDK pair for Go's native dependencies; these remain
operator tool settings.

Those four native API profiles are separate from certifying the actual
authenticated HTTP reader, HTMX or Vue. This session-based host still needs
matching formal transport/browser enrollment and evidence; the existing
central HTTP observer currently handles Bearer or anonymous authentication.
The wider workspace's formal missing obligations and runtime evidence gates
remain open. No release or publication is implied by the initial journeys.

## Elixir/PostgreSQL Vue peer

The workspace `postgres-stack:differential` task now uses the same built Vue
files against this Perl host and the standalone native Elixir/PostgreSQL fixture
in `selecto_backend_certification/examples/elixir_postgresql_vue`. Initialize
separate disposable databases, set both `SELECTO_PERL_STACK_POSTGRES_URL` and
`SELECTO_ELIXIR_STACK_POSTGRES_URL`, and reserve separate HTTP ports. Eight
HTTP/browser checks pass for the controlled flat detail subset.

The current `perl-stack:certify` task uses **Elixir/PostgreSQL for all four
selected native API profiles**. After reconciliation with the current core and
adapters, the controlled pair passes all 52 target checks and 26 differential
comparisons. The task still exits nonzero if any required case fails. Earlier
Go certificates and failed collection attempts remain historical evidence.
The current peer is Elixir. These native certificates and eight HTTP/Vue checks
remain separate from formal transport/SPA qualification. See workspace
`STATUS.md` for the current gaps and exact reports.
