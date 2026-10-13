# Screen views with consent: fespalier_analytics

Since 0.13.0. `docs/analytics.md` is the page; `references/analytics-backends.md` has the vendor recipes (Firebase Analytics,
PostHog, Mixpanel, Amplitude). `fespalier_analytics` reports each page the person opens to an analytics service by its
**route pattern**, and only **while they have agreed**. It is a telemetry sink that an [adapter](../../fespalier/references/app-main.md)
installs, so it needs an app generated with **`telemetry: true`**, and it sits next to `fespalier_otel` or `fespalier_sentry` in
the one `FespalierTelemetry.combine`. It depends on neither.

## The three things an app writes

1. An `AnalyticsBackend` over the vendor SDK (the recipes): `screenView`, and optionally `screenTime` and `consentChanged`.
   **The package depends on no analytics SDK**: an app on PostHog must not link Firebase.
2. A `screenName(String pattern)` if the pattern is not the name you want (`null` skips the screen).
3. One call in `main()`, **before `AppMain.run()`**: `FespalierAnalytics.configure(backend, screenName:)`. The adapter installs the
   sink in `beforeRun()`, before any `ProviderScope`, so a provider override cannot carry the backend. With `main: manual`,
   before `AppAdapters.zone`.

```yaml
# pubspec.yaml: the dependency (same git url and ref as fespalier) and
fespalier:
  telemetry: true
  adapters: [fespalier_analytics]
```

```dart
// In lib/main.dart (AppMain is your generated app.main.g.dart):
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:my_app/analytics/screen_name.dart';
import 'package:my_app/analytics/ignore.dart';
import 'package:my_app/app.main.g.dart';

class LogBackend extends AnalyticsBackend {
  @override
  void screenView(ScreenView view) => debugLog('screen ${view.name}');
}

Future<void> main() {
  FespalierAnalytics.configure(LogBackend(), screenName: screenName);
  return AppMain.run();
}
```

## Behaviour to rely on, and traps

- **Consent is the rule of the sink.** `AnalyticsConsent.undecided` (the start) and `denied` drop a page event on the spot: nothing
  reaches the backend, **nothing is buffered, no "last screen" is kept**. **Granting does not replay**: the screen open when the
  person answered is not reported, and not timed when it is left; the next screen is the first. A banner on the first screen
  therefore loses that screen; ask on a screen `screenName` returns `null` for.
- **Load the stored decision in `startup()`** (it runs before the router): `FespalierAnalytics.sink?.consent = stored;`. After the
  first frame, change it with `ref.read(analyticsConsent.notifier).set(...)` (a `NotifierProvider` that tells the sink), not on the
  sink, so the provider and the sink agree. The same value again does nothing; a change calls `consentChanged` (map it to the
  vendor's opt-in and opt-out) and ends the span `fespalier.analytics.consent`.
- **The initial `consent:` of `configure` is not announced to the backend.** The vendor SDK starts with collection **off** (Firebase's
  manifest flags, PostHog's `config.optOut`, Mixpanel's `optOutTrackingDefault`, Amplitude's `optOut`) and `consentChanged` turns it on.
- **A name is a pattern or yours, never a URL.** `ScreenView.pattern` is `/orders/:id`; a segment value, a query and a fragment are in
  nothing the backend gets (the package's tests assert it on every string). Do not build a `screenName` from a URL. Not-found pages
  have no pattern and are skipped.
- **`source`** is a `NavigationSource` (`notification`, `shortcut`, `widget`, `link`) when the navigation was not the app's own; send it
  as a property. **`returning`** is a page that is the visible one again (a tab, a pop); `returningViews: false` drops those.
- **Add sinks with `FespalierTelemetry.add`, never `install` after `AppMain.run()` started**: the sink is added in `beforeRun()`, and `install` in `startup()` replaces the slot and drops it. `attach` checks `FespalierTelemetry.contains(sink)` (since 0.13.0) and reports once when it is gone.
- **Time on screen** (`screenTime: true`) is reported when a page is left, covered time included, and only for a page whose view was
  sent. Leaves are paired with views by pattern, by count: two instances of one pattern open at once may swap their times. A page under a pushed page, or a kept-alive tab, is not left yet. `/orders/:id` under `/` leaves `/` covered, not left.
- **Without `telemetry: true` nothing is recorded**: the adapter's `attach` asks `telemetryFollows(router)` and reports one
  `FlutterError` (``fespalier_analytics records no screen: ... Set `telemetry: true` ...``). Run `fsp gen` after turning it on.
- **Unconfigured**: one `FlutterError` reports ``fespalier_analytics is listed under `fespalier: adapters:` but was never configured``
  and the adapter does nothing, never throws. `AppMain.root()` in a widget test runs no `main()`: call `configure` in the test.
- **A backend method returns at once.** The sink calls it synchronously from the router. A vendor `Future` is ignored with its own
  `onError` (`ignoreFuture`, in the backends page), never awaited; a backend that throws in `screenView` or `screenTime` is isolated by `combine` and printed once (and that view is not timed), while one that throws in `consentChanged` is reported with `FlutterError.reportError` and the decision stands.
- **Switch the vendor's own screen tracking off** (Firebase's and Amplitude's observers, PostHog's `PosthogObserver`), or a screen
  is counted twice.
- Telemetry: `fespalier.analytics.consent` with `fespalier.analytics.state` (`undecided`, `granted`, `denied`), nothing else
  (`FespalierAnalyticsConventions`). `telemetry: true` also adds the call sites of `data()` and actions: a cost, documented.

## A name from `meta.dart`

The manifest holds every route's `meta` ([`../../fespalier-routing/references/manifest-and-meta.md`](../../fespalier-routing/references/manifest-and-meta.md)),
so a stable, reviewed screen code is a two-line `screenName`:

```dart
// lib/page_meta.dart
class PageMeta {
  const PageMeta({required this.code, required this.title});

  final String code;
  final String title;
}
```

```dart
// lib/app/meta.dart
import 'package:my_app/page_meta.dart';

const meta = PageMeta(code: 'A01', title: 'Home');
```

```dart
// lib/analytics/screen_name.dart
import 'package:my_app/app.g.dart';
import 'package:my_app/page_meta.dart';

/// The screen's review code when its folder has a meta.dart, the pattern when it has none.
String? screenName(String pattern) =>
    AppManifest.byPath[pattern]?.metaAs<PageMeta>()?.code ?? pattern;
```

```dart
// lib/analytics/ignore.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

/// A vendor call that returns a Future is not awaited by the sink: its failure is reported, not thrown.
void ignoreFuture(Future<void> call, String what) {
  unawaited(
    call.catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'analytics',
          context: ErrorDescription(what),
        ),
      );
    }),
  );
}

/// A stand-in for the vendor call in the samples.
void debugLog(String message) => debugPrint(message);
```

## Testing

```dart
// test/analytics_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_analytics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(FespalierAnalytics.debugReset);
  tearDown(FespalierAnalytics.debugReset);

  test('nothing is told until the person agrees', () {
    final recorder = RecordingAnalytics();
    FespalierAnalytics.configure(recorder);
    final sink = FespalierAnalytics.sink!;
    sink.page(null, const TelemetryPage(TelemetryPageKind.enter, '/orders/:id'));
    expect(recorder.log, isEmpty);

    sink.consent = AnalyticsConsent.granted;
    sink.page(null, const TelemetryPage(TelemetryPageKind.enter, '/orders/:id'));
    expect(recorder.consents, [AnalyticsConsent.granted]);
    expect(recorder.views.single.pattern, '/orders/:id');
  });
}
```

A widget test of the whole path calls `FespalierAnalytics.configure(recorder, consent: AnalyticsConsent.granted)`, then
`await AppAdapters.beforeRun()` (what `main()` does before `runApp`), then pumps `AppMain.root()` and navigates;
`examples/plugins/test/analytics_test.dart` is the model. Call `FespalierAnalytics.debugReset()` in `setUp` and `tearDown`, and
`FespalierTelemetry.install(null)` in `tearDown`. `recorder.strings` is everything the backend was given, to assert that no
URL leaked. **No test sees the vendor's side**: that the event arrives, and that the opt-out holds, on a device.
