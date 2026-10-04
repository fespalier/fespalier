---
name: fespalier-observability
description: "Observing a fespalier app (since 0.8.1) — observe.dart (onEnter, onFocus and onLeave hooks for analytics, logging and titles: which pages they run for, in which order, when they fire after the frame, parked tabs, the Ref a hook gets, errors), the telemetry config key and FespalierTelemetry, the fespalier_otel adapter on otel_zone and OpenTelemetry (install, wiring, FespalierOtel.endpoint, the web limitation of runGuarded), the telemetry conventions (contract version 1: every span, event and attribute name), RecordingTelemetry for tests, and what telemetry costs; and, since 0.9.0, several sinks in the one slot (FespalierTelemetry.combine and add, per-sink tokens, isolation), the within hook that makes a data or action span current so HTTP spans nest under it (traceDataCall, the error-zone rule), and navigateFrom with fespalier.navigation.source; and, since 0.9.0, fespalier_sentry (Sentry, errors first: every error and crash tagged with the route pattern, the app file and the action, one breadcrumb per page change, release health, the OpenTelemetry trace id on each event next to fespalier_otel; screen-load transactions and spans on request with tracing: true; RecordingSentry for tests) and FespalierTelemetry.traceOf and linkTrace. Load before adding an observe.dart, turning on telemetry, wiring otel_zone or Sentry, adding a second sink, building a dashboard on the spans, or when a hook never fires, fires twice or throws."
---

# fespalier-observability

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

Two features, both **since 0.8.1** and both opt-in: **route lifecycle hooks** (`observe.dart`) and
**telemetry** (what fespalier reports to a `FespalierTelemetry` sink, and `fespalier_otel`, the sink that
makes OpenTelemetry spans). They share one watch on the router, so a page event means the same thing in
both. An app that uses neither generates the same `app.g.dart` as before and ships none of it.

## observe.dart

```dart
// products/$id/observe.dart: /products/:id and every page below it
import 'package:fespalier/fespalier.dart';
import 'package:my_app/analytics.dart';

void onEnter(Ref ref, {required int id}) => ref.read(analytics).view('product', id);
void onFocus({required int id}) {}
void onLeave(Ref ref, {required int id}) => ref.read(analytics).left('product', id);
```

Any of `onEnter`, `onFocus`, `onLeave` (at least one), each a public top-level function that **returns
`void`**. Parameters: an optional positional `Ref ref`, then named ones: the segments of its folder and
above, optional nullable query parameters, `Uri uri`, and `TypedLocation route` (bound **by its type**: it
must be called `route`). It applies to every **page** (`page.dart`) at and below its folder, in
page-less `(group)` folders too, `nest = false` pages included; a `redirect.dart` route never enters.
Order for one page: `onEnter` and `onFocus` run outermost folder first, `onLeave` innermost first.

Read [`references/lifecycle.md`](references/lifecycle.md) for when each fires (the rule that decides it,
tabs, pushes, redirects), the `Ref` a hook gets, errors, and the traps.

## Telemetry

```yaml
# pubspec.yaml
fespalier:
  telemetry: true # since 0.8.1; run `fsp gen` after
```

Then, in `main.dart`, **before the router is built**: `FespalierTelemetry.install(sink)`. With
`otel_zone`, the sink is `FespalierOtel(isReady: () => observability.isReady)` from `package:fespalier_otel`
(a git dependency next to fespalier, **same `url`, same `ref`**). Nothing is reported until a sink is
installed. Read [`references/telemetry.md`](references/telemetry.md) for the install and wiring,
`FespalierOtel.endpoint()`, **the web limitation of `OtelZone.runGuarded`**, go_router 17, and testing with
`RecordingTelemetry`.

Since 0.9.0, three more things, all in that page:

- **Several sinks.** `install` holds one sink. `FespalierTelemetry.combine([a, b])` is one sink that tells
  each of them everything, in order, each with **its own tokens** (a sink never sees another's) and
  isolated from the others' errors; `FespalierTelemetry.add(sink)` puts one next to the installed one.
- **`within`.** A sink may override `void within(Object? token, Object? Function() body)` to make a data
  or action span the current one while `data()` or the action runs (`FespalierOtel` does), so an HTTP
  client's spans are its children, after an `await` too. Call `body` once, synchronously; use **zone
  values only**, never `runZonedGuarded` or `onError:` (fespalier refuses that zone and says so once).
  An app made with `telemetry: true` calls `data()` through `traceDataCall(..., () => data(...))` for it.
- **`navigateFrom(NavigationSource.notification, () => router.go(...))`** marks the navigation it starts, and
  telemetry reports `fespalier.navigation.source` (`notification`, `shortcut`, `widget`, `link`). fespalier
  never sets it by itself.

[`references/conventions.md`](references/conventions.md) is **contract version 1**: every span, event and
attribute name, for anyone building a dashboard or an alert. Adding is allowed within version 1; renaming
or removing is version 2.

## Sentry (since 0.9.0)

`package:fespalier_sentry` is the sink for Sentry, and it is **errors first**. By default it sends every error and
crash tagged with the route pattern, the app file and the action (`fespalier.route`, `.file`, `.operation`,
`.action`; fingerprint = default + the file), names the scope after the screen (its transaction and the tag
`fespalier.route`, so a crash caught by Sentry's own integrations says which screen it was on), makes **one
breadcrumb per page change**, and leaves release health to the SDK. **Next to `fespalier_otel`** in a
`FespalierTelemetry.combine`, each event carries `otel.trace_id` and `otel.span_id`, so an error links to its
trace. **No transaction is sent by default**: screen-load transactions, spans and TTID/TTFD are the opt-in,
`FespalierSentry(tracing: true)` plus `tracing: true` in `FespalierSentry.configure`, for a team that has only
Sentry.

```dart
FespalierTelemetry.install(FespalierSentry()); // in startup(), before the router; Sentry starts in zone()
```

Read [`references/sentry.md`](references/sentry.md) for the wiring (Sentry is the outermost zone: no
`OtelZone.runGuarded` next to it), the order rules, what is and is never sent, `tracing: true` (one transaction
per screen, the first screen on Android and iOS, no timer), the options, and testing with `RecordingSentry`.

## The traps

- **Hooks fire after the frame.** `context.go('/x')` followed at once by an assertion sees nothing:
  `await tester.pump()` first. A hook never runs inside `build`.
- **A different segment value is a different page.** `/products/1` to `/products/2` is `onLeave` then
  `onEnter`, whatever `remount` says; a query change is no transition.
- **To redirect, use a guard.** A hook runs after the navigation committed; a `go` inside one works but
  is looked at one frame later. ([`fespalier-guards`](../fespalier-guards/SKILL.md).)
- **`ref.watch` in a hook watches nothing that lasts**: use `ref.read`. Changing another provider from a
  hook is fine.
- **A hook that throws is reported**, not swallowed: `FlutterError.reportError`, context
  `while running onEnter of products/$id/observe.dart`; the other hooks still run, and a widget test
  fails.
- **Telemetry on, no sink installed: nothing happens.** It is not an error. Install the sink before
  `AppRoutes.router()` runs, or the first navigation is not a span.
- **A second `install` replaces the first** (since 0.9.0: use `FespalierTelemetry.add`, or `combine` both).
  An app that installs Sentry in one place and OpenTelemetry in another has only the last.
- **Sentry and `OtelZone.runGuarded` do not mix** (since 0.9.0). Sentry's `appRunner` is the outermost zone;
  `runGuarded`'s zone would send an uncaught async error to Talker only, and Sentry would never see it.
- **Two `ui.load` transactions per screen** (`tracing: true`): a plain `SentryNavigatorObserver()` makes its own.
  Use `FespalierSentry.navigatorObserver()`.
- **Nothing in Sentry**: an empty `SENTRY_DSN` (the SDK and the sink are off), no `install`, no `telemetry: true`,
  or, for transactions, no `tracing: true` in **both** places or a release sample rate of 0.1.
- **A sink's `within` must not give its zone an error handler** (since 0.9.0). `runZonedGuarded` there
  would strand a failing `data()` on its loading view, so fespalier runs the call outside that zone and
  prints `fespalier telemetry: <Sink>.within changed the error zone ...` once. Use `runZoned(body,
zoneValues: {...})`.
- **`fespalier` and `fespalier_otel` must be the same git dependency** (same `url`, same `ref`), or pub
  refuses to resolve; see [fespalier-troubleshooting](../fespalier-troubleshooting/SKILL.md) (its observe.dart and telemetry page).
- **`otel_zone` forces go_router 17** in an app that uses it (`otel_go_router` caps it); fespalier accepts
  17 and 18.
- **`OtelZone.runGuarded` leaves a Flutter web app blank.** Run the body as it is on the web
  (`kIsWeb ? body() : observability.runGuarded(body)`). Since 0.8.1, known limitation.

## Where the code is

- Hooks: `packages/fespalier/lib/src/lifecycle.dart` (the router watch, `RouteHooks`, `observeAttach`);
  the generator reads `observe.dart` in `cli/src/resolve.rs` and writes `RouteMatcher.observe`,
  `_observeAt` and `AppRoutes.attach` into `app.g.dart`.
- Telemetry: `packages/fespalier/lib/src/telemetry.dart` (the sink API, `combine`, `within`,
  `NavigationSource` and `navigateFrom`, and what the generated call sites reach; `traceDataCall` is in
  `devtools/devtools.dart`), `navigation_kind.dart` (the `initial`/`go`/`push`/`pop`/`replace`/`refresh` classifier DevTools
  shares) and `version.dart`; the adapters are `packages/fespalier_otel/` and, since 0.9.0, `packages/fespalier_sentry/`
  (`traceOf` and `linkTrace` in `telemetry.dart` are how the two share a trace).
- Scaffold: `fsp new 'orders/[id]' --observe` writes `observe.dart`.
- The example is `examples/telemetry`: lifecycle tests and span tests, on go_router 17.
