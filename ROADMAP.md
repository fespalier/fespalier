# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
docs/releasing.md, "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## In progress (0.9.0)

`fsp dev`, `fsp build` and `fsp run` (tasks in `pubspec.yaml`, a terminal UI), and these Flutter
packages ship in 0.9.0:

- `fespalier_auth` (sessions, guards, OpenID Connect and Keycloak, `dio`) and
  `fespalier_sign_keypair` (DPoP, device-bound tokens);
- `fespalier_adaptive` (`nav.dart` menus as a bar, a rail or a drawer by window width);
- `fespalier_image` (images at the size their layout needs, from an image CDN, with
  `RouteLink(onPreload:)` to warm a page's image);
- `fespalier_flags`, `fespalier_storage` and `fespalier_connectivity` (flag-gated routes, a
  `dataCache` that shows the saved value on the first frame, refetch on reconnect);
- `fespalier_dio` and its `http` variant (requests cancelled with their page, server validation
  errors on form fields, no retried writes);
- `fespalier_sentry` (errors first: every error and crash tagged with the route and the file, page
  breadcrumbs, the OpenTelemetry trace id on each event; screen-load transactions on request).

In core: `FespalierTelemetry.combine` (several sinks at once), the `within` hook that puts HTTP
spans under the data span, `navigateFrom` for launches from notifications, the generated `main()`'s
adapters (`fespalier: adapters:`, a `FespalierAdapter` per package), pages named by their route
pattern so vendor navigator observers see screens, and CI runs every package on its declared floor,
Flutter 3.32, with the lowest dependencies it allows.

## Next

- **Core seams the adapters need.** `AppRoutes.urlOf`, a DevTools panel adapters can post to, and
  `test: a11y: true` in `fsp test`.
- **Adapters**, each a small package:
  - `fespalier_launch`: shortcut and home-widget taps open typed routes, the first screen on a cold
    start (notification taps are `fespalier_push`, since 0.13.0).
  - `fespalier_crashlytics`: errors from the telemetry sink, named by route pattern and tagged with
    the file that threw (three calls in a sink of your own until then).
  - `fespalier_sentry`, the rest: Sentry's span streaming (`traceLifecycle: stream`, for which
    `tracing: true` makes no spans yet) and HTTP spans under the data span in Sentry's own tracing.
  - `fespalier_dio`, the rest: composed with `fespalier_auth` (DPoP and refresh under a retry
    layer) and OpenTelemetry trace headers on each request.
- **`fespalier_biometrics`, the rest.** The unlock guard ships in 0.13.0 (docs/guards.md). Not built: a lock
  screen widget, an idle lock on a timer, and a secret kept behind the biometric (a keystore's job).
- **`fespalier_frb`, the rest.** The change feed ships in 0.13.0 (docs/data.md). Not built: a
  `flutter_rust_bridge` dependency (the generated bindings own it), a typed event codec, and a rebuild
  budget for a core that emits thousands of events a second (coarser events or an `InvalidationTable`
  is the answer today).
- **`fespalier_maps`, the rest.** The pin picker ships in 0.13.0 (docs/maps.md). Still to come:
  offline region packs (download with progress, pause, resume, storage) and PMTiles file packs
  (resumable over HTTP Range, checked, written atomically); MapLibre's own downloads cannot resume
  after an app restart, which is why the file packs exist.
- **`fespalier_download`, the rest.** The request, status and port model ships in 0.15.0 (docs/downloads.md).
  The engine, the foreground HTTP backend, the durable registry and the providers ship with it, and so does
  `fespalier_download_background` (a backend over the operating system's download service, Flutter 3.47, which also uploads
  a file: `Uploads` sends a non-idempotent request once), and notification taps open typed routes through an adapter
  (`adapters: [fespalier_download]`). Still to come: credentials once `fespalier_http` has them. `fespalier_maps` file
  packs will move onto it. What a device would show about the background backend is issue #158.
- **Instrumentation the app doesn't have to write.** With `telemetry: true` and an `app.dart`, the
  generated `main()` installs `FespalierOtel` and its zone itself.
- **The four telemetry attributes documented as not emitted**: `fespalier.data.attempt`,
  `fespalier.data.source`, `fespalier.action.rolled_back`, `fespalier.action.invalid`. Forms and
  data freshness now have what they need; adding them brings back the retries, cache-hits and
  rollbacks panels.
- **Reload instead of restart after a regeneration.** `fsp dev` hot restarts when `lib/app.g.dart`
  changes, because the generated router is built once, so a hot reload would keep the old route
  table. In debug the router could rebuild itself on `reassemble` (go_router's
  `GoRouter.routingConfig`, with a `ValueListenable<RoutingConfig>`); a regeneration would then need
  only a hot reload and keep the app's state.
- **Flutter 3.47.6.** A `build:` change on its own, with `just devtools-build`.
- **Editor support for tasks.** The VS Code and IntelliJ plugins list `fespalier: tasks:` as run
  configurations.
- **Make `Maestro flows open their routes on the web` a required check** once it has a few weeks
  of green runs.

## Later

- **Types resolved, not compared by spelling.** The generator reads a syntax tree, so a `typedef`
  and the type it names count as different types (see docs/troubleshooting.md, "Known limitations"). Resolving them needs the
  Dart analyzer, as a sidecar or through the analysis server.
- **Dashboards beyond the local stack.** The same dashboard spec rendered for hosted OpenObserve
  and Grafana Cloud.

## Waiting on others

- **go_router 18 in `examples/telemetry`.** `otel_go_router` 0.2.0 still requires
  `go_router: ^17.0.0`; the fix is open upstream (Dartastic/otel_go_router PR #2). fespalier itself
  supports 17 and 18.
- **`runGuarded` on the web.** `otel_zone`'s `runGuarded` never runs its body in a Flutter web app,
  so the docs use `kIsWeb ? body() : observability.runGuarded(body)` until it is fixed in
  vaam-apps/flutter-otel-zone.
- **OpenTelemetry Collector 0.162.0.** Tagged, but no image is published yet; the stack stays on
  0.161.0 until one is.
- **OpenObserve:** a click on a stat tile opens nothing, and PromQL's `or vector(0)` returns no
  series (v1.0.4). Drill-down is on the tables and charts until then, and the Grafana tiles work
  around the second.
