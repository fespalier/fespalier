# fespalier_crashlytics

Crashlytics for [fespalier](https://github.com/fespalier/fespalier) (since 0.18.0). Every failure of a guard,
a `data.dart`, an action or a deferred load is a **non-fatal** report named by the route pattern
(`/products/:id`) and the app file that threw (`products/$id/data.dart`); the screen is a custom key, so a
crash the app's own handlers record says where the person was; each page change is a line in the log.

This package is a sink with **no Firebase dependency**. It defines a port, `CrashReporter`, of three calls
(`recordError`, `setCustomKey`, `log`), and the app passes a reporter that forwards to Firebase. The Firebase
binding is a compiled recipe in the `fespalier-observability` skill
(`skills/fespalier-observability/references/crashlytics.md`), which `just skill-samples` builds. Every
Firebase plugin of an app shares one core major, so a range in this git-pinned package would hold them back
at each Firebase major.

The docs cover all of it: [Crashlytics](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#crashlytics)
(what Crashlytics gets, the wiring, the rules, testing). This page is the short version.

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
      ref: v0.17.2
  fespalier_crashlytics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_crashlytics
      ref: v0.17.2
```

<!-- x-release-please-end -->

Your app also depends on `firebase_core` `^4.15.0` and `firebase_crashlytics` `^5.4.0`, the versions the recipe
was built against. Their floors (Flutter 3.27, Dart 3.6) are the app's, not fespalier's.

Turn telemetry on in `pubspec.yaml` and regenerate:

```yaml
fespalier:
  telemetry: true
```

## Wire it

`startup()` runs `Firebase.initializeApp`, sets the two global handlers (each skips what the sink already reported)
and adds the sink once. The whole of it, with the platform check, is the recipe in the skill
(`skills/fespalier-observability/references/crashlytics.md`); the line that matters is:

```dart
if (!FespalierTelemetry.contains(crashSink)) FespalierTelemetry.add(crashSink); // add, not install; once
```

`crashSink` is `FespalierCrashlytics(FirebaseCrashReporter())`. The sink needs an app generated with
`telemetry: true`, and it sits next to `FespalierSentry` or `FespalierOtel` in the same `add`/`combine`.
Crashlytics runs on Android, iOS and macOS only.

## Test it

`package:fespalier_crashlytics/testing.dart` has `RecordingCrashlytics`, a reporter that keeps what it is
given, so a test reads the reasons, the keys and the log lines the sink sent, with no Firebase, no platform
channel and no network:

```dart
final crash = RecordingCrashlytics();
FespalierTelemetry.install(FespalierCrashlytics(crash));
// ... navigate, pump ...
expect(crash.lines, [r'error StateError in data items/$id/data.dart on /items/:id']);
```
