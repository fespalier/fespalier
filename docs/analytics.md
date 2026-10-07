# Analytics: fespalier_analytics

`fespalier_analytics` (since 0.13.0) reports **screen views** to an analytics service of yours: each page the person opens, by its **route pattern** (`/products/:id`), never by its URL, and only **while the person has agreed**. It is a [telemetry](observability.md#telemetry) sink that an [adapter](adapters.md) installs, so it sits next to `fespalier_otel` or `fespalier_sentry` in the one `combine`, and it needs an app generated with **`telemetry: true`**: page events reach a sink only from such an app.

**The analytics SDK is not a dependency.** You give the package an `AnalyticsBackend` (three methods), and Firebase Analytics, PostHog, Mixpanel and Amplitude are compiled recipes in the `fespalier-observability` skill, so an app on one does not link the others. The package does not depend on `fespalier_otel`, starts no timer and listens to nothing.

## Install

Add `fespalier_analytics` under `dependencies:` next to `fespalier`, with the same git `url` and the same `ref`: pub resolves the two to one package only if they are the same repository dependency. The snippet, kept at the release's tag, is in [`packages/fespalier_analytics/README.md`](../packages/fespalier_analytics/README.md). Then turn telemetry on, list the adapter and run `fsp gen`:

```yaml
# pubspec.yaml
fespalier:
  telemetry: true
  adapters: [fespalier_analytics]
```

An adapter takes no options from the pubspec, so the app's own code reaches it through one static call in `main()`, before `AppMain.run()` ([Adapters that need your code](adapters.md#adapters-that-need-your-code)):

```dart
// lib/main.dart
Future<void> main() {
  FespalierAnalytics.configure(MyAnalyticsBackend(), screenName: screenName);
  return AppMain.run();
}
```

- `configure(backend, {screenName, returningViews = true, screenTime = true, consent = undecided})`. Calling it twice replaces: the earlier sink stops reporting (a hot restart runs `main()` again).
- The adapter's `beforeRun()` adds the sink with `FespalierTelemetry.add`, synchronously, so the first navigation is reported. Its `attach` asks core's `telemetryFollows(router)`: **without `telemetry: true` it reports once** (`fespalier_analytics records no screen: ... Set telemetry: true under fespalier: in pubspec.yaml and run fsp gen`) and records nothing. `telemetry: true` also adds the call sites that report `data()` and actions, which is a cost to know ([What it costs](observability.md#what-it-costs)).
- **Unconfigured, the adapter says so once and does nothing**: one `FlutterError` reports ``fespalier_analytics is listed under `fespalier: adapters:` but was never configured: call FespalierAnalytics.configure(backend) in main() before AppMain.run()``. It never throws out of `beforeRun` or `attach`.
- With `main: manual`, call `configure` in your own `main()` before `AppAdapters.zone`.

## Screen names

A `ScreenView` has a `name`, the route `pattern`, a `source` and `returning`:

- The **name** is `screenName(pattern)`, which is the pattern itself by default. Return `null` (or an empty string) to **skip** a screen, and its time with it. Not-found pages have no pattern and are not screens.
- The **pattern** holds the segment's name, never its value: `/orders/:id`, not `/orders/42`. A query value, a fragment and a segment value are not in anything the backend is given; the package's tests assert it on every string a backend receives. Whatever your `screenName` returns is yours: do not build a name from a URL.
- `source` is a `NavigationSource` (`notification`, `shortcut`, `widget`, `link`) when the navigation that showed the screen was not the app's own ([Where a navigation came from](observability.md#where-a-navigation-came-from-navigatefrom)): a screen opened by a tap on a notification says so.
- `returning` is a screen that is the visible one again (back to a tab, a pop) and not a first entry. `returningViews: false` drops those.

A name from your `meta.dart` ([Route manifest and `meta.dart`](routing.md#route-manifest-and-metadart)) is a two-line `screenName`; the recipe is in the skill.

## Consent

Nothing is sent, and nothing is kept, until the person has agreed.

- `AnalyticsConsent` is `undecided` (the start), `granted` or `denied`. While it is not `granted`, a page event is **dropped on the spot**: it reaches no backend, and there is **no buffer** and no remembered "last screen".
- **Granting does not replay what was dropped.** The screen that was open when the person answered is not reported (and is not timed when it is left); the next screen is the first. Asking on the first screen therefore loses that one: ask on a screen you do not count (`screenName` returns `null` for it), or accept the loss.
- Load the stored decision in **`startup()`**, which runs before the router is built, so the first screen is not lost: `FespalierAnalytics.sink?.consent = stored;`. The same value again does nothing.
- Changing it tells the backend (`AnalyticsBackend.consentChanged`): map it to the vendor's own switch (`setConsent`, `optIn` and `optOut`). A backend that throws is reported (`FlutterError`), and the decision stands. The backend is **not** told the initial `consent:` of `configure`: that is the SDK's own start-up (and a vendor's collection should be off by default until the person answers).
- `analyticsConsent` is a `NotifierProvider` for a settings screen: `ref.watch(analyticsConsent)` reads it and `ref.read(analyticsConsent.notifier).set(AnalyticsConsent.granted)` changes it through the sink. It starts at the sink's decision; after the first frame use it, not the sink, so the two agree.
- The consent change is itself a span, `fespalier.analytics.consent` with `fespalier.analytics.state` (`undecided`, `granted` or `denied`); nothing else about analytics is reported to the other sinks.

Storing the answer, and asking for it, are the app's: the package has no storage and no banner.

## Time on screen

`screenTime: true` (the default) reports a `ScreenTime` when a screen is left: the time from its entry to its leaving, **the time another page covered it included**. It is sent only for a screen whose view was sent, so a screen entered before the person agreed is never timed. A screen that is covered by a pushed page is not left until it is gone; a tab kept alive in a shell is not left when you switch away. `screenTime: false` sends views only.

## Backends

An `AnalyticsBackend` is called synchronously from the router and must return at once:

| Member                    | When                                                                                                |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| `screenView(ScreenView)`  | A screen came up. Only while consent is `granted`.                                                  |
| `screenTime(ScreenTime)`  | A screen was left (default: nothing). Only while consent is `granted`, for a screen already viewed. |
| `consentChanged(consent)` | The decision changed (default: nothing).                                                            |

A vendor call that returns a `Future` is ignored with its own `onError` (`unawaited(call().catchError(...))`), never awaited; a backend that throws is isolated by fespalier's telemetry (the others and the app go on, the error is printed once). Firebase Analytics, PostHog, Mixpanel and Amplitude are recipes in the `fespalier-observability` skill (`references/analytics-backends.md`), built by `just skill-samples`. A vendor SDK's own automatic screen tracking must be switched off, or a screen is counted twice.

## Testing

`package:fespalier_analytics/testing.dart` has `RecordingAnalytics`: `views`, `times`, `consents`, a `log` and `strings` (everything it was given, as strings, to assert that no URL leaked); `throwing: true` makes every call fail. A widget test boots the app as it runs, with `configure` called first, because `AppMain.root()` runs no `main()`:

```dart
FespalierAnalytics.configure(recorder, consent: AnalyticsConsent.granted);
await AppAdapters.beforeRun(); // what main() does before runApp
await tester.pumpWidget(AppMain.root());
expect(recorder.views.map((v) => v.pattern), ['/']);
```

Call `FespalierAnalytics.debugReset()` in `setUp` and `tearDown`, and `FespalierTelemetry.install(null)` in `tearDown` (the sink is added to the telemetry slot). [`examples/plugins`](../examples/plugins) tests the first screen, undecided then granted, a refusal, a notification source, a skipped screen and the absence of any segment value through `AppMain.root()`; no device is needed. What no test can see is the vendor's own side: that Firebase or PostHog really receives the event, and honours the opt-out, on a device.
