# Telemetry conventions, contract version 1

Since 0.8.1. This is the contract that dashboards and alerts are built on. `fespalier.telemetry.version`
is `1`. Within version 1 a change may only **add** (an attribute, an event, a value of an enum-like
attribute). Renaming or removing a name or a value, or changing the meaning or unit of an attribute, is
version 2, a breaking release. `packages/fespalier_otel/lib/src/conventions.dart` holds every name as a
constant and `test/conventions_test.dart` as a literal; the README's
[Telemetry conventions](https://github.com/fespalier/fespalier#telemetry-conventions) section has the
tables.

OpenTelemetry's semantic conventions are followed where they exist (`service.*`, `url.*`, `error.type`,
`exception.*`, span status); everything else has the `fespalier.` prefix.

## Names

```text
instrumentation scope   fespalier            (version = the fespalier release)
resource                fespalier.version, fespalier.telemetry.version
spans                   navigate {route} | navigate (not found) | navigate   (superseded)
                        guard {file} | redirect {file} | data {file}
                        action {file}#{name} | deferred {file}
                        auth {operation}   (since 0.9.0, fespalier_auth)
events (on navigate)    fespalier.page.enter | fespalier.page.focus | fespalier.page.leave
                        exception (semconv, on an error span)
every span              fespalier.operation = navigate | guard | redirect | data | action | deferred | auth
                        fespalier.route, fespalier.file, fespalier.async, error.type
navigate                fespalier.navigation.kind = initial | go | push | pop | replace | refresh
                        fespalier.navigation.outcome = ok | not_found | superseded
                        fespalier.navigation.from, fespalier.navigation.redirected (bool)
                        fespalier.navigation.depth (int), url.path, url.query (recordLocations only)
guard, redirect         fespalier.guard.decision = pass | redirect | error | skipped
                        fespalier.guard.location (recordLocations only)
data                    fespalier.data.state = data | error | stream | disposed
                        fespalier.data.keyed (bool)
action                  fespalier.action.name, fespalier.action.result = ok | error
deferred                fespalier.deferred.result = ok | error
auth (since 0.9.0)      fespalier.auth.operation = restore | sign_in | refresh | sign_out
                        fespalier.auth.result = ok | none | expired | rejected | cancelled | error
                        fespalier.auth.backend (the backend's constant name: oidc, firebase, fake, your own)
                        fespalier.auth.trigger = expired | unauthorized | forced   (refresh only)
                        fespalier.auth.dpop (bool: the backend binds its tokens)
leave event             fespalier.route, fespalier.page.duration_ms (int)
enter, focus events     fespalier.route
```

## Rules a query or a panel can rely on

- **Route** is the pattern, as `fsp routes` prints it and `AppManifest.byPath` keys it (`/`,
  `/products/:id`, `/docs/*rest`), without the mount prefix. For a section's data or action it is the
  section folder's pattern. **File** is relative to the app folder, as spelled on disk.
- **Duration** is the span's own. For `navigate` it is _requested to first frame_ (guards, redirects, the
  build and the first-frame loads included); a `data` span's duration is its loading time.
- **Status** is `Error` exactly when the outcome attribute is `error`. `not_found` is not an error, and
  neither is an `auth` span that ends `rejected` or `cancelled`. An `auth` span that ends `error` has the status
  and `error.type`, **never the exception's text** (it can name a host).
- **`auth` spans** (since 0.9.0, `fespalier_auth`, within version 1: a new operation and new keys) follow the
  installed sink and need no `telemetry: true`. A refresh is one span however many requests wait for it.
  `auth` is also the first word of the span name: `auth restore`, `auth sign_in`, `auth refresh`,
  `auth sign_out`. A sink that switches exhaustively over `TelemetryOp` needs an `auth` case (0.9.0).
- A **guard parent**: guard, redirect, data and deferred spans started while a navigation is pending are
  children of its `navigate` span; an action is a root span (a user's tap).
- **Never recorded**: segment and query values (unless `recordLocations: true`), family keys, `extra`,
  action input and result, data values, guard inputs. Exception text is scrubbed by `otel_zone`. From
  `fespalier_auth`: tokens, user ids, claims, user names, e-mails, issuer and endpoint URLs, DPoP proofs
  and key thumbprints.
- **Superseded** navigations never committed: no kind, no route, no `redirected` or `depth`. Leave them
  out of latency panels.
- **Not emitted** (so no dashboard panel charts one): a data attempt (Riverpod does not tell a
  provider its retry count), a data source (network or cache), an action rolled back, an action rejected
  by validation.
- **Metrics**: none. Derive them in the collector with the `spanmetrics` connector, using these
  attributes as dimensions. The `fespalier.auth.*` attributes are not dimensions of the collector
  `fsp telemetry` starts yet (since 0.9.0).
- **The backend decides the column names.** OpenObserve turns `.` into `_` and stores every span
  attribute as a string (a bool is `'true'`), keeps resource attributes under `service_`, and has no
  instrumentation-scope column on traces: select fespalier's spans by `fespalier_operation`.
