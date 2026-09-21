# Perl core and components security review — 2026-09-21

## Scope and conclusion

Reviewed the current `selecto-perl` and `selecto-perl-components` worktrees,
including their exposed API/query/write boundaries, Explorer HTTP/WebSocket
routes, record editor, action and lookup controllers, saved queries, exports,
URL rendering, importer contract, file facade, and shipped browser code.
Both repositories were clean when the review began.
The user explicitly reserved the deployment-specific, in-situ scan for themselves.

Confirmed issues were patched and regression-tested. This is a bounded source
review with executable evidence, not a guarantee of production security or a
complete audit of every dependency, database adapter, callback, or runtime.
There remains a pre-existing generated-asset release-check failure described below.

## Findings and changes

### High: dependency floor admitted a vulnerable JSON decoder

Both distributions accepted Mojolicious 9.40. The components WebSocket path
decodes untrusted JSON with Mojo::JSON. Mojolicious versions before 9.47 have a
documented pure-Perl JSON nesting memory-exhaustion vulnerability. A byte-size
limit alone does not enforce nesting depth. Raised both packages' cpanfile and
Makefile.PL requirements to the installed/tested 9.49; components also enforce
that version at load time.

Upstream evidence:
- https://github.com/mojolicious/mojo/security/advisories/GHSA-p5qf-qvw8-xgvg
- https://github.com/mojolicious/mojo/blob/main/Changes

### Medium: custom CSRF tokens bypassed upstream masking protections

Components generated a stable token using a secret, time, and rand, and emitted
the same token throughout a session. Mojolicious added secure random generation
in 9.46 and per-render masking against compression side channels in 9.48.
Components now use the framework's csrf_token helper and csrf_protect validator
for actions, saved queries, and record editing. Tests verify fresh masks,
acceptance of existing valid masked forms, rejection of missing/raw/forged tokens,
and rejection across sessions. No end-to-end compression-oracle exploit was run.
Existing open forms using the previous custom token must be reloaded.

### Medium: unsafe detail-action URLs passed validation

Core domain parsing accepted `java<TAB>script:alert({{id}})` and equivalent
newline/carriage-return variants. Browsers normalize these characters in URL
schemes. Components repeated the same insufficient check. Both now reject
control characters, unsafe literal whitespace, and backslashes. Spaces inside
valid field placeholders remain supported. Local object-link templates also
reject backslashes, preventing browser authority normalization of `/\\host/...`.

Exposure requires unsafe domain/link metadata; this is not evidence that an
ordinary row value can escape an otherwise safe template. Row substitutions
remain URL-escaped. Regression tests exercise rejection at the domain and
component URL boundaries.

### Medium: WebSocket origin comparison omitted the scheme

Reproduced acceptance of Origin `http://example.test` for an HTTPS request to
the same host. The default check now compares scheme, host, and effective port,
and rejects malformed origins with credentials, paths, queries, or fragments.
Explicit default ports and hostname case normalize correctly. Native requests
without Origin remain supported; this is not an authentication mechanism.
TLS/proxy interpretation remains part of the application's request configuration.

### Export hardening: control-prefixed spreadsheet cells

Explorer CSV/TSV escaping covered `=`, `+`, `-`, and `@`, but not leading tab,
CR, or LF, unlike the existing core API formatter. Both streaming and buffered
Explorer paths now use the expanded escaping set. Tests verify each prefix.
No external spreadsheet application execution was tested.

### Redirect hardening: scheme-bearing return URLs

The return-path helper accepted `javascript:/explore/products` and
`https:/explore/products` because their parsed path matched the Explorer path
and no host was present. It now rejects schemes, userinfo, and control characters.
Tests preserve legitimate local query strings and reject scheme-bearing and
external returns. No browser redirect exploit is claimed.

## Verification

- Core required `mise run verify`: source and MakeMaker suites pass, 44 files,
  2,693 tests in each run, with an isolated PostgreSQL cluster and temporary
  DBD::SQLite installation enabled.
- Components source and MakeMaker suites: 15 files, 1,477 tests in each run,
  including real local HTTP/WebSocket routes and the 39 new boundary assertions.
- Components Playwright suite: 27 passed. Browser JavaScript was not changed.
- Central Perl/PostgreSQL certificate, specification 2.14.0: 143 passed,
  74 explicitly unsupported, no failed cases; overall PARTIALLY_CERTIFIED.
  This is not a full certificate. Report:
  `../selecto_backend_certification/certification-reports/20260921T141508Z/summary.md`.
- `git diff --check` passes in both edited repositories.

Enabling SQLite exposed obsolete tests that assumed RETURNING and write graphs
were unsupported. Updated those fixtures to exercise actual returned identities
and persisted parent/child/grandchild bindings on modern SQLite, while retaining
the unsupported branch for older SQLite. Negative governance tests remain active.
No SQLite implementation behavior was changed to make these tests pass.

Logs are under `/private/tmp/selecto-perl-security-final-verify.log`,
`/private/tmp/selecto-components-security-final-verify.log`, and
`/private/tmp/selecto-components-security-browser.log`.

## Remaining release check and evidence limits

`mise run verify` in components stops at `assets:check`: the checked-in
`public/selecto-components/selecto-components.css` differs from the shared
`selecto-api-console/packages/web-assets` source. The components copy contains
newer graph/editor styling absent from the shared source. Blind synchronization
would remove those styles, so this review preserved them. This pre-existing
release integrity failure still needs reconciliation; the overall components
release gate is not green. The source, package, and browser checks were run
independently rather than claiming that gate passed.

Database execution evidence covers PostgreSQL, SQLite, and in-memory DuckDB.
MySQL, MariaDB, and MSSQL live suites were not configured. The central certificate excludes its
unsupported profiles, including real-HTTP certification; the components HTTP
tests provide separate, narrower transport evidence.

Trusted boundaries remain explicit: host code supplies authenticated scoped
engines, callback authorization, action effects, importer matching/execution,
and appropriate session/proxy configuration. Native write command objects are
trusted programmatic inputs, not an untrusted HTTP format. Raw authored HTML
shell hooks are trusted host content. SQL visibility is opt-in. This review did
not test production data, host callbacks, distributed file-storage races,
arbitrary query cost, or application-specific identity/session revocation.
