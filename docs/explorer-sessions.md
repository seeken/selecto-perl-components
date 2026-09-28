# Explorer WebSocket sessions

An Explorer connection retains its last successful form snapshot, a revision,
and a bounded cache of raw query results. It does not retain controllers, engines,
database connections, or domain authorization closures. Normal HTTP requests and
exports continue to execute independently.

The browser sends a complete form on its first submission. After acknowledgement,
it sends a `selecto_session` object containing `revision`, `set`, and `remove`.
Array values replace the entire array, preserving field order and duplicates.
Concurrent submissions use full forms. An unknown or stale revision receives
`selecto.session.resync`; the browser retries its latest submission with the
original complete form. Reconnecting does not rerun a query on its own. The next
submission restores state, and canonical URLs remain usable after a restart.
Invalid submissions display validation errors without advancing the revision.
Older clients may continue submitting complete forms.

Every query still obtains a request-scoped engine, validates the current domain,
and compiles its governed SQL. Only then may execution reuse a result keyed by
adapter, SQL, columns, and bound parameters. Domain fingerprint or host scope
changes invalidate the cache. This allows presentation changes and revisiting a
page to reuse data; pagination can also reuse the matching count. Cached values
are serialized and decoded on retrieval so rendering cannot mutate them.

Repeating the same query explicitly runs it fresh. `selecto_refresh: 1` always
clears cached results. Successful Explorer edits and actions mark the next
submission for refresh. Other sessions' writes can remain invisible until the
cache expires or the user refreshes. The cache is local to a connection and is
discarded on close; it is not a durable saved-query store.

## Host integration

These options may be set at the plugin level or per Explorer:

```perl
websocket_context => sub ($controller, $config) {
    # Reauthenticate and reauthorize the current user on EVERY invocation.
    return undef unless allowed_now($controller, $config);
    # Include tenant, principal, effective scope, and any policy revision.
    return current_security_namespace($controller, $config);
},
websocket_session_options => {
    ttl => 30,                 # seconds; 0 disables result caching (max 300)
    max_bytes => 2_097_152,    # serialized results per socket (max 8 MiB)
    max_entries => 8,          # data pages + counts (max 32)
},
```

An undefined context denies access and closes with code 1008. A changed context
discards the saved form and cached results. With no callback, the session is
isolated to its connection and relies on the hosting application's existing
authentication and governed engine. Hosts using database session variables or
policy changes not reflected in SQL must include those in the namespace, or
disable result caching. Scope strings are server-only and never returned to the
browser. `websocket_message_cleanup` still runs after every message, including
cache hits, revision conflicts, and denied requests.

TMS rechecks the browser login and Explorer access on every message and supplies
tenant, user, active client, and login session identity. It recreates governed
domains and request resources each time. Permission-sensitive field catalogs and
action eligibility remain request-scoped; this layer deliberately caches data
only after current query validation and compilation.

Responses include `selecto.session.revision`, `accepted`, and `cache_hit` for
diagnostics. Defaults cap each connection at eight entries / 2 MiB with a
30-second freshness window. Oversized results are served normally without being
retained. Hosts may disable caching while retaining revisioned form state.
