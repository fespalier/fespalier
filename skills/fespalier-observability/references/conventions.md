# Telemetry conventions, contract version 1

Since 0.8.1. This is the contract that dashboards and alerts are built on. `fespalier.telemetry.version`
is `1`. Within version 1 a change may only **add** (an attribute, an event, a value of an enum-like
attribute). Renaming or removing a name or a value, or changing the meaning or unit of an attribute, is
version 2, a breaking release. `packages/fespalier_otel/lib/src/conventions.dart` holds every name as a
constant and `test/conventions_test.dart` as a literal; the docs'
[Telemetry conventions](https://github.com/fespalier/fespalier/blob/main/docs/telemetry-conventions.md) page has the
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
                        image {cdn}   (since 0.9.0, fespalier_image)
                        fespalier.<pkg>.<op>   (custom, since 0.11.0: a package's own operation)
events (on navigate)    fespalier.page.enter | fespalier.page.focus | fespalier.page.leave
                        exception (semconv, on an error span)
every span              fespalier.operation = navigate | guard | redirect | data | action | deferred | auth | image | custom
                        fespalier.route, fespalier.file, fespalier.async, error.type
navigate                fespalier.navigation.kind = initial | go | push | pop | replace | refresh
                        fespalier.navigation.outcome = ok | not_found | superseded
                        fespalier.navigation.from, fespalier.navigation.redirected (bool)
                        fespalier.navigation.depth (int), url.path, url.query (recordLocations only)
                        fespalier.navigation.source = notification | shortcut | widget | link   (since 0.9.0)
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
image (since 0.9.0)     fespalier.image.cdn (the URL builder's name: imgproxy, emgr, cloudinary, imgix, thumbor, template, srcset, direct)
                        fespalier.image.width (int: the bucket, in physical pixels)
                        fespalier.image.preload (bool: a precache started the load)
                        fespalier.image.result = ok | error
                        fespalier.image.status (int: the HTTP status of a failed load, when known)
custom (since 0.11.0)   fespalier.custom.name (the operation's name, fespalier.<pkg>.<op>)
                        fespalier.custom.result = the outcome the package ended with, usually ok | error
                        plus the package's own fespalier.<pkg>.* attributes (its contract, not version 1's)
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
- **`image` spans** (since 0.9.0, `fespalier_image`, within version 1) are one per network load that starts
  (a cache hit and a load already in flight make none), named `image emgr`, `image cloudinary`, and so on. They
  are a child of the navigation in progress when there is one, follow the installed sink and need no
  `telemetry: true`. An `image` span that ends `error` has the status and, when known,
  `fespalier.image.status`; **never the URL, the source, the signature or the error's text**. A sink that
  switches exhaustively over `TelemetryOp` needs an `image` case too (0.9.0).
- **`custom` spans** (since 0.11.0, `TelemetryOp.custom`, within version 1: a new operation and new keys) are a
  package's own operation, named by `TelemetryStart.name` (`fespalier.push.open`). The name is
  `fespalier.<pkg>.<op>`, every key of `attributes` starts with `fespalier.<pkg>.`, and a value is a String, an
  int, a double or a bool (debug assertions in `FespalierTelemetry.begin`). A `custom` span that ends `error` has
  the status and `error.type`, **never the exception's text**. A sink that switches exhaustively over
  `TelemetryOp` needs a `custom` case (0.11.0, the `feat!` break).
- A **guard parent**: guard, redirect, data and deferred spans started while a navigation is pending are
  children of its `navigate` span; an action is a root span (a user's tap).
- **A data or action span is the current span while `data()` or the action runs** (since 0.9.0, through
  the `within` hook of `FespalierOtel`): spans an HTTP client makes inside it, after an `await` too, are
  its children. A `data` span starts before `data()` runs, so its duration includes the sync part.
- **`fespalier.navigation.source`** (since 0.9.0, within version 1: a new key) is where a navigation came
  from when the app's own code did not start it: `notification`, `shortcut`, `widget` or `link`, set by
  `navigateFrom`. It is **absent** otherwise, and fespalier never sets it by itself. A cold-start launch
  is `kind = initial` with a source, not a new kind: a dashboard that counts `initial` as "App start"
  still does.
- **Never recorded**: segment and query values (unless `recordLocations: true`), family keys, `extra`,
  action input and result, data values, guard inputs. Exception text is scrubbed by `otel_zone`. From
  `fespalier_auth`: tokens, user ids, claims, user names, e-mails, issuer and endpoint URLs, DPoP proofs
  and key thumbprints; from `fespalier_image`, an image's URL, source and signature; `fespalier_sentry` never
  sends a `custom` operation's attributes.
- **Superseded** navigations never committed: no kind, no route, no `redirected` or `depth`. Leave them
  out of latency panels.
- **Not emitted** (so no dashboard panel charts one): a data attempt (Riverpod does not tell a
  provider its retry count), a data source (network or cache), an action rolled back, an action rejected
  by validation.
- **Metrics**: none. Derive them in the collector with the `spanmetrics` connector, using these
  attributes as dimensions. The `fespalier.auth.*`, `fespalier.image.*` and `fespalier.custom.*` attributes and `fespalier.navigation.source` are not
  dimensions of the collector `fsp telemetry` starts yet (since 0.9.0).
- **The backend decides the column names.** OpenObserve turns `.` into `_` and stores every span
  attribute as a string (a bool is `'true'`), keeps resource attributes under `service_`, and has no
  instrumentation-scope column on traces: select fespalier's spans by `fespalier_operation`.
