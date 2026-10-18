# fespalier_sentry

Sentry for [fespalier](https://github.com/fespalier/fespalier) (since 0.9.0), **errors first**. Out of the
box it sends every error and crash tagged with the route pattern (`/products/:id`), the app file
(`products/$id/data.dart`) and the action that threw; one breadcrumb per page change; the release health
the Sentry SDK already has; and, next to [`fespalier_otel`](../fespalier_otel/README.md), the OpenTelemetry
trace id of the screen or the call each event came from, so an error links to its trace. Screen-load
transactions, spans for guards, data loads and actions, and time to full display are opt-in
(`FespalierSentry(tracing: true)`), for a team that has only Sentry.

Since 0.19.0 the scope is named when a navigation commits, before the page's `initState` and first `build` and not after that frame, so what reads the scope in that frame (an event captured with `withScope`, the page's own code) finds the page's names.

fespalier itself has no Sentry dependency: it tells a `FespalierTelemetry` sink what happened, and this
package is the sink that turns it into Sentry's events, breadcrumbs and, on request, transactions.
`SentryFlutter.init` still starts the SDK, which owns crash capture, sessions, native integrations and the
transport.

The docs cover all of it: [Sentry](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#sentry-fespalier_sentry)
(what Sentry gets, the wiring, tracing, defaults and privacy, testing). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if
they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.19.0
  fespalier_sentry:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_sentry
      ref: v0.19.0
```

<!-- x-release-please-end -->

Your app also depends on `sentry_flutter` for `SentryFlutter.init`, in the range this package accepts:
`>=9.26.0 <10.0.0`.

Turn telemetry on in `pubspec.yaml` and regenerate:

```yaml
fespalier:
  telemetry: true
```

## Wire it

Sentry starts first: its `appRunner` runs the binding, `startup()` and `runApp`, so crashes are Sentry's.
In `lib/app/startup.dart`:

```dart
Future<void> zone(Future<void> Function() body) => SentryFlutter.init(
  (options) => FespalierSentry.configure(
    options,
    // Empty: Sentry is off. Pass --dart-define=SENTRY_DSN=https://... to send.
    dsn: const String.fromEnvironment('SENTRY_DSN'),
  ),
  appRunner: body,
);

/// Before the router is built, so the first navigation is reported.
void startup() => FespalierTelemetry.add(FespalierSentry()); // add, not install: install replaces a sink an adapter added

/// Release health on the web needs it; it makes no transaction.
List<NavigatorObserver> get routerObservers => [
  if (kIsWeb) FespalierSentry.navigatorObserver(),
];
```

`FespalierSentry.configure` puts fespalier's defaults on Sentry's options: PII off, no screenshot or widget
tree, no trace header leaves the app unless you list a host (`propagateTraceTo:`), and the query and
fragment of a request are taken off Sentry's own HTTP breadcrumbs, events and spans.

Next to OpenTelemetry, install both in the one slot and every event also carries `otel.trace_id` and
`otel.span_id`:

```dart
FespalierTelemetry.install(
  FespalierTelemetry.combine([
    FespalierSentry(),
    FespalierOtel(isReady: () => observability.isReady),
  ]),
);
```

Do not also run `OtelZone.runGuarded`: Sentry is the outermost zone.

## Performance, on request

```dart
FespalierSentry.configure(options, dsn: dsn, tracing: true); // the SDK samples
FespalierTelemetry.install(FespalierSentry(tracing: true)); // the sink makes the transactions
```

Each navigation is then a `ui.load` transaction named by its route pattern, with spans for guards,
redirects, data loads, deferred loads and actions, and time to initial and to full display. Use this
**or** a plain `SentryNavigatorObserver()` for transactions, never both.

With Sentry's `options.traceLifecycle = SentryTraceLifecycle.stream` (since 0.19.0) the same tree is
streamed as spans: each screen is a root span (a segment), with the same children, and time to initial and to
full display are attributes of their spans. A superseded navigation cannot be discarded, so it is sent with
`fespalier.navigation.outcome` `superseded`. In that mode the HTTP spans Sentry's own integrations make
(`SentryHttpClient`, `sentry_dio`) inside a `data()` or an action are children of its span (since 0.19.0); one that
ends before the navigation commits carries the segment name `navigate`. See
the docs' [Span streaming](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#span-streaming).

## Tests

`package:fespalier_sentry/testing.dart` has `RecordingSentry`: a real Sentry hub whose transport keeps what
it would send, so a test reads the events, breadcrumbs and transactions the SDK built, with no
`SentryFlutter.init`, no native SDK, no timer and no network.

With `traceLifecycle` set to `stream` in `RecordingSentry(configure:)` (since 0.19.0) it also installs the SDK's
streaming span factory, so a `SentryHttpClient(hub: sentry.hub)` over an `http` `MockClient` makes the HTTP spans a
real app gets (`sentry.spans`).
