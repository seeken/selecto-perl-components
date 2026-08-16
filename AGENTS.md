# selecto-perl-components

- This repository owns the reusable Mojolicious exploration UI for native
  `selecto-perl`. Keep database domain, query, compilation, and execution logic
  in `selecto-perl`; this package owns request-state validation, WebSocket
  transport, server-rendered HTML fragments, and browser assets.
- URL query parameters are the default canonical query-builder state. A domain
  may set `components.query_params` false for private URL state; in that mode,
  WebSocket and POST bodies carry state and generated URLs remain path-only.
- Use htmx 4's `hx-ws` extension for incremental UI updates. Keep an ordinary
  GET fallback and permalink in shareable mode, and a POST fallback without
  permalink/export links in private URL mode.
- Never accept raw SQL, identifiers outside the configured domain, arbitrary
  aggregate functions, or client-selected adapters.
- Keep this as an independent sibling repository. Resolve `selecto-perl` from
  `../selecto-perl` by default via `script/with-local-sibling` and support
  `SELECTO_LIVE_SELECTO_PERL` plus `SELECTO_ECOSYSTEM_USE_LOCAL`.
- The htmx runtime is vendored and version-pinned. Update both assets together,
  record the exact version in the README, and rerun the WebSocket tests.
- Run `mise run verify` before handoff. Run the Northwind demo smoke path when a
  disposable database is available.
