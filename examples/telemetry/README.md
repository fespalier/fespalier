# telemetry

A fespalier example for the route lifecycle (`observe.dart`) and for OpenTelemetry through
[`otel_zone`](https://github.com/vaam-apps/flutter-otel-zone) and `package:fespalier_otel`
(both since 0.8.0). Three tabs (home, orders, settings), an order page with a `data.dart`, an
`action.dart` and its own `observe.dart`, a guarded and deferred settings page, and a login page.

- `lib/app/observe.dart` and `lib/app/(tabs)/orders/$id/observe.dart` write the screens they see
  into `lib/analytics.dart`; `test/lifecycle_test.dart` reads them.
- `pubspec.yaml` has `fespalier: telemetry: true`, so the generated `lib/app.g.dart` tells
  fespalier where each guard, data provider, action and deferred page is.
- `lib/main.dart` wires `otel_zone`. It stays a hand-written `main()`; a generated entrypoint
  (`zone()` in `lib/app/startup.dart`) can take its place once it lands. A failure while the app
  starts arrives through `FlutterError.reportError`.
- `test/telemetry_test.dart` runs the app on the SDK's in-memory exporter and reads the spans:
  a navigation with its guard, data load and page events as children and events, an action, and a
  deferred load.

This is the one example on go_router 17: `otel_zone` depends on `otel_go_router`, which declares
`go_router: ^17.0.0`.

On the web, `main.dart` runs its body outside `OtelZone.runGuarded`, which leaves a web app blank
(since 0.8.0, known limitation: otel_zone runGuarded on web). `flutter run -d chrome` shows the app.
