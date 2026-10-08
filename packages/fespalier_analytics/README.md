# fespalier_analytics

Screen views for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0), with consent: each page the person opens is reported to a backend of yours by its **route pattern** (`/products/:id`, never the URL), and **nothing is sent or kept while the person has not agreed**. It is an adapter (`fespalier: adapters: [fespalier_analytics]`) over fespalier's telemetry, so the app must be generated with `telemetry: true`. The analytics SDK is not a dependency: you give it an `AnalyticsBackend`, and Firebase Analytics, PostHog, Mixpanel and Amplitude are recipes in the `fespalier-observability` skill. It does not depend on `fespalier_otel` (it sits beside it), starts no timer and listens to nothing.

The docs cover all of it: [Analytics](https://github.com/fespalier/fespalier/blob/main/docs/analytics.md). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.12.0
  fespalier_analytics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_analytics
      ref: v0.12.0
```

<!-- x-release-please-end -->

## Wire it

```yaml
# pubspec.yaml
fespalier:
  telemetry: true # page events reach a sink only from an app generated with it
  adapters: [fespalier_analytics]
```

```dart
// lib/main.dart: configure before the adapters run
Future<void> main() {
  FespalierAnalytics.configure(MyAnalyticsBackend(), screenName: screenName);
  return AppMain.run();
}

// startup.dart, which runs before the router: load the stored decision, so the first screen is not lost
// FespalierAnalytics.sink?.consent = storedConsent;
```

## Test it

```dart
final analytics = RecordingAnalytics();
FespalierAnalytics.configure(analytics, consent: AnalyticsConsent.granted);
// ... boot the app, navigate
expect(analytics.views.map((v) => v.pattern), ['/', '/products/:id']);
```

`examples/plugins` shows it end to end.
