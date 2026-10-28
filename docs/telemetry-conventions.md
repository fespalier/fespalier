# Telemetry conventions

The names `fespalier_otel` emits, as a contract: [Observability](observability.md#telemetry) explains how to turn telemetry on, and [`fsp telemetry`](telemetry-dashboards.md) builds dashboards on these names.

<!-- markdownlint-disable MD024 -->

## Telemetry conventions

<!-- markdownlint-restore -->

This section is **contract version 1**: dashboards and alerts are built on it.

- Within version 1 a change may only add (a new attribute, a new event, a new value of an enum-like attribute, announced in the changelog).
- Renaming or removing a name or a value, or changing the meaning or unit of an attribute, is version 2: it bumps `fespalier.telemetry.version` and is a breaking release.
- `packages/fespalier_otel/test/conventions_test.dart` holds every name below as a string literal, so a rename fails a test before it ships.
- 0.21.0 renamed two names without bumping `fespalier.telemetry.version`, which stays `1`: the `auth` step `refresh` is `renew`, and the boolean `fespalier.auth.dpop` is the string `fespalier.auth.scheme`. They were young (0.9.0) and read by nothing but the `auth` label, but a query of your own that filters on either changes ([Upgrading](migration.md#0210)).
- The names follow OpenTelemetry's semantic conventions where they exist (`service.*`, `url.*`, `error.type`, `exception.*`, span status) and use the `fespalier.` prefix for the rest.

**Resource attributes**, fixed when the SDK starts:

| Key                           | Value                                            | Set by                                     |
| ----------------------------- | ------------------------------------------------ | ------------------------------------------ |
| `service.name`                | the app's name                                   | `OtelZoneConfig.serviceName`               |
| `service.version`             | the app's version                                | `otel_zone` `start(serviceVersion:)`       |
| `app.build_id`                | the build number                                 | `otel_zone` `start(buildId:)`              |
| `deployment.environment.name` | e.g. `production`                                | `OtelZoneConfig.deploymentEnvironmentName` |
| `fespalier.version`           | the fespalier release, e.g. `0.8.1`              | `FespalierOtel.resourceAttributes`         |
| `fespalier.telemetry.version` | `1` (a string): the version of these conventions | `FespalierOtel.resourceAttributes`         |

**Scope.** Every span is made by the instrumentation scope `fespalier`, whose version is the fespalier release. To pick fespalier's spans out of a service's, filter on `fespalier.operation` (a backend that does not keep the scope on spans, like OpenObserve, has no scope column to filter on).

**Spans.** Every span is `SpanKind.internal`, except an `http` span (since 0.21.0), which is `SpanKind.client`, and carries `fespalier.operation`. A span's duration is its own (end minus start), so no attribute repeats it; for `navigate` it is _requested to first frame_: redirects, async guards, the build of the new page and its first-frame loads.

| `fespalier.operation` | Span name                                                                                                 | Starts                                                                                                                                      | Ends                                                                                                              | Parent                                                                         |
| --------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `navigate`            | `navigate {route}`; `navigate (not found)`; `navigate` when superseded or after a guard failure           | a location is requested (`go`, `push`, `replace`, a tab switch, a deep link), a pop or a guard's refresh commits, or the router is attached | the end of the first frame rendered after the commit, or when a newer navigation starts before this one committed | none (a root span)                                                             |
| `guard`               | `guard {file}`, e.g. `guard (members)/guard.dart`                                                         | the guard returned                                                                                                                          | the answer is known (sync: at once; async: when its `Future` settles)                                             | the pending `navigate`, else the current context                               |
| `redirect`            | `redirect {file}`                                                                                         | as `guard`                                                                                                                                  | as `guard`                                                                                                        | as `guard`                                                                     |
| `data`                | `data {file}`, e.g. `data products/$id/data.dart`                                                         | the provider of a `data.dart` runs `data()` (since 0.9.0: before it runs, and the span is the current one while it runs)                    | the value is there, its `Future` settles, or the provider is disposed first; a `Stream` ends at once              | the pending `navigate`, else the current context                               |
| `action`              | `action {file}#{name}`                                                                                    | `ActionNotifier.call` (since 0.9.0 the span is the current one while the function runs)                                                     | the result is there, or its `Future` settles                                                                      | the current context (usually none)                                             |
| `deferred`            | `deferred {file}`                                                                                         | `DeferredLibrary.load()` starts a load (not one that joins a load in flight)                                                                | the load completes or fails                                                                                       | the pending `navigate`, else the current context                               |
| `auth`                | `auth {operation}`, e.g. `auth renew` (since 0.9.0; `auth refresh` until 0.20.0)                          | `restoreAuth`, `signIn` or `adopt`, a renewal, `signOut` (`fespalier_auth`)                                                                 | the outcome is known                                                                                              | the current context (usually none)                                             |
| `image`               | `image {cdn}`, e.g. `image emgr` (since 0.9.0)                                                            | a network image starts loading (`fespalier_image`: a widget or a precache; not a cache hit, and not a load already in flight)               | the image is decoded, or the load fails                                                                           | the navigation in progress, if there is one                                    |
| `http`                | `{METHOD}`, e.g. `GET` (since 0.21.0; a `CLIENT` span, named as OpenTelemetry's HTTP conventions name it) | `OtelTransport` (`fespalier_otel`) sends a request; not made until the SDK is up                                                            | the response headers arrive, or the send fails                                                                    | the current context: the `data` or `action` span of the operation that sent it |
| `custom`              | `fespalier.<pkg>.<op>`, e.g. `fespalier.push.open` (since 0.11.0)                                         | a package's own operation starts (`FespalierTelemetry.begin` with `TelemetryOp.custom`)                                                     | the package calls `finish`                                                                                        | the current context (the navigation in progress if the package asked for it)   |

A span's status is `Error` (with the exception's text) exactly when its outcome attribute is `error`.

- A `not_found` navigation is not an error, and neither is an `auth` span that ends `rejected` or `cancelled`.
- A `navigate` that ends `error` (a guard or `redirect.dart` failed, since 0.21.0) has the status `Error`, no exception text and no `fespalier.route`: the exception is on the guard's span, so count failures there.
- An `auth` span that ends `error` has the status and `error.type`, but never the exception's text, which can name a host.
- An `http` span has the status `Error` and `error.type` when the response's status is 400 or more (`error.type` is the status code, `503`) or when no answer came (`error.type` is the `TransportFailure` class, `TransportUnsent`); the exception's text is never recorded, since it can name a host. It ends when the headers arrive: a body that breaks later is the caller's to see.
- A `custom` span that ends `error` has the status and `error.type`, never the exception's text. It has `fespalier.custom.name` (the span's name) and `fespalier.custom.result`; the package's own `fespalier.<pkg>.*` attributes are that package's contract, not version 1's (since 0.11.0).
- An `image` span that ends `error` has the status and, when the load carries one, `fespalier.image.status`; the exception's text is never recorded, since it holds the URL.

**Events.** On one `navigate` span the order is every `leave`, most recently entered first, then one
`enter` or `focus`. The page events fire whether or not the app has an `observe.dart`.

| Event                  | On                                                                              | When                                                       | Attributes                                                    |
| ---------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------- |
| `fespalier.page.enter` | the `navigate` span that caused it                                              | a page instance became the visible page for the first time | `fespalier.route`                                             |
| `fespalier.page.focus` | the same                                                                        | an entered page is the visible page again                  | `fespalier.route`                                             |
| `fespalier.page.leave` | the same                                                                        | an entered page is gone                                    | `fespalier.route`, `fespalier.page.duration_ms`               |
| `exception` (semconv)  | a `guard`, `redirect`, `data`, `action` or `deferred` span with outcome `error` | the operation threw or its `Future` failed                 | `exception.type`, `exception.message`, `exception.stacktrace` |

**Attributes on every span:**

| Key                   | Type   | Values and meaning                                                                                                                                                                                      |
| --------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.operation` | string | `navigate`, `guard`, `redirect`, `data`, `action`, `deferred`, `auth`, `image`, `http` (since 0.21.0) or `custom` (since 0.11.0)                                                                        |
| `fespalier.route`     | string | the route pattern, as `fsp routes` prints it and `AppManifest.byPath` keys it: `/`, `/products/:id`, `/docs/*rest`. Absent when not found. For a section's data or action, the section folder's pattern |
| `fespalier.file`      | string | the app file, relative to the app folder, as spelled on disk: `products/$id/data.dart`. Absent on `navigate`                                                                                            |
| `fespalier.async`     | bool   | whether the operation returned a `Future` (`guard`, `redirect`, `data`, `action`, `auth`)                                                                                                               |
| `error.type`          | string | semconv: on an error, the exception's class (minified on a release web build)                                                                                                                           |

**On a `navigate` span:**

| Key (`navigate`)                  | Type   | Values and meaning                                                                                                                                                                                                        |
| --------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.navigation.kind`       | string | `initial`, `go`, `push`, `pop`, `replace` or `refresh` (the classification DevTools shows); absent when superseded                                                                                                        |
| `fespalier.navigation.outcome`    | string | `ok`, `not_found`, `error` (since 0.21.0) or `superseded`                                                                                                                                                                 |
| `fespalier.navigation.from`       | string | the pattern of the page that was on top before (absent at the start)                                                                                                                                                      |
| `fespalier.navigation.redirected` | bool   | the committed path differs from the requested one: a guard or a `redirect.dart` sent it elsewhere                                                                                                                         |
| `fespalier.navigation.depth`      | int    | how many pushed pages the stack holds after the commit (0 for a plain `go`)                                                                                                                                               |
| `fespalier.navigation.source`     | string | since 0.9.0: where it came from when the app's own code did not start it: `notification`, `shortcut`, `widget` or `link` ([`navigateFrom`](observability.md#where-a-navigation-came-from-navigatefrom)); absent otherwise |
| `url.path`, `url.query`           | string | semconv: the committed location, mount prefix included. Only with `recordLocations: true`                                                                                                                                 |

**On the other spans and events:**

| Key                                                      | Type   | Values and meaning                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| -------------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.guard.decision` (`guard`, `redirect`)         | string | `pass`, `redirect`, `error` or `skipped` (a segment it asks for did not parse, so it did not run); a `redirect` span is `redirect` or `error`                                                                                                                                                                                                                                                                                                                     |
| `fespalier.guard.location`                               | string | where it redirected to. Only with `recordLocations: true`                                                                                                                                                                                                                                                                                                                                                                                                         |
| `fespalier.data.state` (`data`)                          | string | `data`, `error`, `stream` (a `Stream` was returned: not listened to, so the span ends at once) or `disposed` (the provider was disposed before its `Future` settled)                                                                                                                                                                                                                                                                                              |
| `fespalier.data.keyed`                                   | bool   | the provider is a family; the key itself is never recorded                                                                                                                                                                                                                                                                                                                                                                                                        |
| `fespalier.data.attempt` (`data`)                        | int    | since 0.18.0: which try the load is, `1`, or n + 1 when Riverpod ran the provider again on its own after try n failed. A reload the app asks for (`invalidate`, `refresh`) is `1` again. A `Stream` load is always `1`. A hot reload's rebuild of a failed load counts as a retry. Riverpod's default `retry` stops after 10 retries, so at most `11`; a custom `retry:` with no limit has no top, and as a collector dimension each value is a series of its own |
| `fespalier.data.source` (`data`)                         | string | since 0.18.0: `cache` when the saved copy of a `dataCache` was on screen before the fresh data arrived (a retry or a reload that runs while the copy is still shown, as after an offline start, says `cache` too), `fetch` when it was not (also with a `dataCache` and no `dataCacheStorage`, once fetched data has replaced the copy, and for a `data()` that returns its value at once). Absent for a data.dart without a `dataCache`                          |
| `fespalier.action.name` (`action`)                       | string | the function's name in `action.dart`                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `fespalier.action.result`                                | string | `ok` or `error`                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `fespalier.action.rolled_back` (`action`)                | bool   | since 0.18.0: an `optimistic()` patch was shown for the run: `true` when the write failed and the patch was taken back, `false` when it was kept. Absent when no patch was shown. A form does no rollback of its own                                                                                                                                                                                                                                              |
| `fespalier.action.invalid` (`action`)                    | bool   | since 0.18.0: on an `error` only, the run ended with `FieldErrors`: `validate()` refused the input, or the action named wrong fields. `fespalier.action.result` stays `error`. A form that stops a submit before the action runs makes no span                                                                                                                                                                                                                    |
| `fespalier.deferred.result` (`deferred`)                 | string | `ok` or `error`                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `fespalier.page.duration_ms` (on `fespalier.page.leave`) | int    | milliseconds from that instance's enter to its leave, covered time included                                                                                                                                                                                                                                                                                                                                                                                       |

**On an `auth` span** (since 0.9.0; `fespalier_auth`; no new contract version, as a new operation and its
attributes only add):

| Key                        | Type   | Values and meaning                                                                                                                                                                                                                                                                                           |
| -------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fespalier.auth.operation` | string | `restore` (the stored session was read at start-up), `sign_in` (also a session the app adopted), `renew` (`refresh` until 0.20.0), `sign_out` or, since 0.25.0, `step_up` (the user proved who they are again: a step-up refusal or a re-proof page)                                                         |
| `fespalier.auth.result`    | string | `ok`; `none` (restore: nothing was stored); `expired` (restore: the stored credential could not be renewed any more, or the device key is gone); `rejected` (the server refused: wrong credentials, or a session it no longer renews); `cancelled` (the user closed the sign-in); `error` (it could not run) |
| `fespalier.auth.backend`   | string | the backend's short constant name: `oidc`, `firebase`, `fake`, or an app's own                                                                                                                                                                                                                               |
| `fespalier.auth.trigger`   | string | renew only: `expired` (before a request), `unauthorized` (after a 401) or `forced`                                                                                                                                                                                                                           |
| `fespalier.auth.scheme`    | string | since 0.21.0: how the backend authenticates requests, a short constant it names: `bearer`, `dpop`, `device`, or an app's own (was the bool `fespalier.auth.dpop` until 0.20.0)                                                                                                                               |

**On an `http` span** (since 0.21.0; `OtelTransport` in `fespalier_otel`; OpenTelemetry's HTTP client semantic conventions plus `fespalier.operation`; no new contract version, as a new operation and its attributes only add):

| Key                         | Type   | Values and meaning                                                                                                                                 |
| --------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `http.request.method`       | string | the method, upper case: `GET`                                                                                                                      |
| `server.address`            | string | the host the request went to                                                                                                                       |
| `server.port`               | int    | the port (the scheme's default when the URL names none)                                                                                            |
| `url.scheme`                | string | `https` or `http`                                                                                                                                  |
| `url.path`                  | string | the request's path (`/` for none), never its query: on an `http` span it is always recorded, where on a `navigate` span it needs `recordLocations` |
| `http.response.status_code` | int    | the status code, when a response came back                                                                                                         |
| `http.request.resend_count` | int    | how many times the request had been sent before this send: on a re-send only (an auth replay, a retry), absent on the first send                   |
| `error.type`                | string | on an error: the status code (`503`) of a 4xx or 5xx answer, or the `TransportFailure` class when no answer came                                   |

There is no `url.full`, no `url.query` and no header, body or credential: a query value is app data. `traceparent` and `tracestate` are added to a request only for the origins listed in `OtelTransport(propagateTo:)` (none by default). [Observability](observability.md#spans-around-data-and-actions) has the wiring.

**On an `image` span** (since 0.9.0; `fespalier_image`; no new contract version, as a new operation and its
attributes only add):

| Key                       | Type   | Values and meaning                                                                                                               |
| ------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.image.cdn`     | string | the URL builder's name: `imgproxy`, `emgr`, `cloudinary`, `imgix`, `thumbor`, `template`, `srcset`, `direct`, or a builder's own |
| `fespalier.image.width`   | int    | the width asked for, in physical pixels (a bucket)                                                                               |
| `fespalier.image.preload` | bool   | a precache started the load, not a widget                                                                                        |
| `fespalier.image.result`  | string | `ok` or `error`                                                                                                                  |
| `fespalier.image.status`  | int    | the HTTP status of a failed load, when the error carries one                                                                     |

**On a `custom` span** (since 0.11.0; a package's own operation, `TelemetryOp.custom`; no new contract version, as a new operation and its attributes only add):

| Key                       | Type   | Values and meaning                                                                                                           |
| ------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.custom.name`   | string | the operation's name, `fespalier.<pkg>.<op>`, e.g. `fespalier.push.open`                                                     |
| `fespalier.custom.result` | string | the outcome the package ended with, usually `ok` or `error` (`cancelled`, `disposed`, `rejected` and `skipped` are possible) |

A package's own `fespalier.<pkg>.*` attributes also sit on the span; they are that package's contract, not version 1's.

**Metrics.** fespalier emits none: `otel_zone` turns metrics off on purpose (a periodic reader is a timer that keeps the radio busy), and rates and latencies are on the wire as spans already. Derive metrics in the collector with the `spanmetrics` connector, with these dimensions:

- `fespalier.operation`, `fespalier.route`, `fespalier.navigation.kind`, `fespalier.navigation.outcome`, `fespalier.guard.decision`, `fespalier.data.state`, `fespalier.data.attempt`, `fespalier.data.source`, `fespalier.action.name`, `fespalier.action.result`, `fespalier.action.rolled_back`, `fespalier.action.invalid`, `fespalier.deferred.result` and `fespalier.file`;
- next to the resource's `service.name`, `service.version` and `fespalier.version`.

Since 0.18.0 these four are recorded; an app on an older fespalier sends none. `fespalier.data.attempt` is a series per try, which Riverpod's default `retry` keeps to 11 at most (see its row).

Not dimensions of the collector `fsp telemetry` starts yet (since 0.9.0):

- `fespalier.auth.*`: its dashboards label an `auth` span as a session operation, and nothing more.
- `http.*`, `server.*` and `url.scheme` of the `http` span (since 0.21.0): span columns, no panel and no dimension yet.
- `fespalier.navigation.source`: the bundled stack keeps it as a span column, with no panel and no spanmetrics dimension of its own yet.
- `fespalier.image.*`: span columns, no panel, no dimension; a failed image load is on the Errors dashboard under "Image load".

**Never recorded:**

- Segment and query values (unless `recordLocations: true`), family keys, `extra`, action inputs and results, data values and guard inputs.
- From `fespalier_auth`: credentials and tokens, user ids, claims, user names, e-mails, issuer and endpoint URLs, DPoP proofs, signatures and key thumbprints.
- From `OtelTransport`: a URL's query or fragment, a header value, a body, a failure's text (it can name a host).
- From `fespalier_image`: an image's URL, source and signature.

What is recorded is a route pattern, a file path, a function name or an enum-like value, all fixed when the app is built, and exception text, which `otel_zone` scrubs (`redact`) as it scrubs every span string.
