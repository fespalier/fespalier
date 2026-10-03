# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
README's "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## In progress (0.9.0)

`fsp dev`, `fsp build` and `fsp run` (tasks in `pubspec.yaml`, a terminal UI), and the Flutter
packages `fespalier_auth` (sessions, guards, OpenID Connect and Keycloak, `dio`) and
`fespalier_sign_keypair` (DPoP, device-bound tokens) ship in 0.9.0. Next, as a Flutter
package next to `fespalier_otel`:

- **`fespalier_image`.** A widget that requests the image size its layout needs, from a configured
  set of widths, through a URL builder for imgproxy and EmgR, Cloudinary, imgix, Thumbor, a template
  or a list of sized URLs. No signing key in the app. `RouteLink` can warm the destination's image.

## Next

- **Core seams the adapters need.** `FespalierTelemetry.combine` (several sinks at once), the
  route pattern as each page's `name` (so vendor navigator observers see screens), adapter wiring
  in the generated `main()` from one pubspec key, `traceData` taking a closure (HTTP spans under
  the data span), `AppRoutes.urlOf`, a DevTools panel adapters can post to, and `test: a11y: true`
  in `fsp test`.
- **Adapters**, each a small package:
  - `fespalier_launch`: notification, shortcut and home-widget taps open typed routes, the first
    screen on a cold start.
  - `fespalier_sentry` and `fespalier_crashlytics`: errors and performance from the telemetry sink,
    named by route pattern and tagged with the file that threw.
  - `fespalier_adaptive`: `nav.dart` menus as a bottom bar, rail or drawer by width.
  - `fespalier_flags`: feature flags that guards watch, so menus hide flagged routes.
  - `fespalier_dio` (and an `http` variant): cancellation when a page goes away, server validation
    errors on form fields, no retried writes, trace headers.
  - `fespalier_analytics`: screen views and time on screen, named from `meta.dart`, with consent.
  - `fespalier_storage`: `dataCache` storage that shows the saved value on the first frame.
  - `fespalier_connectivity`: the reconnect signal that `refetchOnReconnect` waits for.
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
  and the type it names count as different types (see README's "Status"). Resolving them needs the
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
