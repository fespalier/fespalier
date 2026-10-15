# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
docs/releasing.md, "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## Next

- **Adapters**, each a small package (the seams they need are in core: `AppRoutes.urlOf`, the DevTools
  _Adapters_ tab and `test: a11y: true` ship in 0.16.0):
  - `fespalier_launch`: shortcut and home-widget taps open typed routes, the first screen on a cold
    start (notification taps are `fespalier_push`, since 0.13.0).
  - `fespalier_crashlytics`: errors from the telemetry sink, named by route pattern and tagged with
    the file that threw (three calls in a sink of your own until then).
  - `fespalier_sentry`, the rest: Sentry's span streaming (`traceLifecycle: stream`, for which
    `tracing: true` makes no spans yet) and HTTP spans under the data span in Sentry's own tracing.
  - `fespalier_dio`, the rest: a test of `fespalier_auth`'s `SessionInterceptor` under `dio_smart_retry`
    (a DPoP proof per retry, one replay after a refresh); trace headers stay `otel_dio`'s
    (docs/http.md).
- **`fespalier_biometrics`, the rest.** The unlock guard ships in 0.13.0 (docs/guards.md). Not built: a lock
  screen widget, an idle lock on a timer, and a secret kept behind the biometric (a keystore's job).
- **`fespalier_frb`, the rest.** The change feed ships in 0.13.0 (docs/data.md). Not built: a
  `flutter_rust_bridge` dependency (the generated bindings own it) and a rebuild budget for a core that
  emits thousands of events a second (coarser events or an `InvalidationTable` is the answer today).
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
- **OpenTelemetry Collector 0.162.0.** Its image is published: a `build:` bump of
  `cli/templates/telemetry/compose.yaml` (tag and index digest), with `just telemetry-smoke`.
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

- **go_router 18 in `examples/telemetry`.** `otel_go_router` 0.3.0 accepts go_router 18, but
  `otel_zone` (v0.5.0, which the example pins, and v0.6.0 alike) still asks for
  `otel_go_router: ^0.2.0`, which requires `go_router: ^17.0.0`; the fix belongs in
  vaam-apps/flutter-otel-zone. fespalier itself supports 17 and 18.
- **`runGuarded` on the web.** `otel_zone`'s `runGuarded` never runs its body in a Flutter web app,
  so the docs use `kIsWeb ? body() : observability.runGuarded(body)` until it is fixed in
  vaam-apps/flutter-otel-zone.
- **OpenObserve:** a click on a stat tile opens nothing, and PromQL's `or vector(0)` returns no
  series (v1.0.4; v1.1.0 not checked yet). Drill-down is on the tables and charts until then, and the
  Grafana tiles work around the second.
