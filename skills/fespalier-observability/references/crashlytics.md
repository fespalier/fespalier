# Crashlytics: `fespalier_crashlytics`

Since 0.18.0. The docs' [Crashlytics](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#crashlytics) section
is the user documentation; this page is what an agent needs to set it up, to say what Crashlytics will show, and to say why a
report is missing or doubled. The package is a **sink with no Firebase in it**: it reports through `CrashReporter`, a port of three
calls, and the Firebase binding below is the app's. It reports **non-fatal** errors; a fatal crash is the app's own handlers'.

## What you get

- **Every failure, named where it happened.** A guard, `data.dart`, action or deferred load that throws is one non-fatal report.
  Its **reason** is the line the console shows with it: `in data products/$id/data.dart on /products/:id`, or
  `in action items/$id/action.dart#rename on /items/:id`. Its keys are `fespalier_operation`, `fespalier_route` (the pattern,
  `/products/:id`), `fespalier_file` (`products/$id/data.dart`) and `fespalier_action` (the function name, or `''`). Keys are
  `''` when there is no value, so every report carries the same five names.
- **The screen, as a key.** Each committed navigation sets `fespalier_screen` to the route pattern, sent only when it changes. A
  location that matched no route sets it to `''` and logs `navigation not found`. A superseded navigation sets nothing.
- **Log lines.** `navigation enter /products/:id` and `navigation focus ...` for a page change (a leave is no line), and, for a
  failure the sink does not report, the class only: `auth refresh StateError`, `custom fespalier.push.open StateError`,
  `action items/$id/action.dart rejected` (a `FieldErrors`), `image emgr error status=404` (an image with no error object).
  `logs: false` turns the lines off; the keys and the reports stay.
- **Repeats are lines.** The same operation, file and exception type inside `repeatWindow` (30 seconds, read through `clock`) is
  `data products/$id/data.dart StateError again`, not another report: Riverpod retries a failing `data()`.

**Never sent:** a segment value, a query value, a family key, `extra`, an action's input or result, a data value, a `FieldErrors`,
a URL or an id. No error's **text** is in a reason, a key or a log line. The exception object goes to the reporter as the app's own,
which is what Firebase's handlers do with every error, so its message is in the report the way Firebase always shows it.

**Not sent in this version:** an OpenTelemetry trace link. `fespalier_sentry` keeps that.

## The rules

- **Non-fatal only.** The sink records what fespalier reports, which the app has handled or shows (a data error view, an action's
  `AsyncError`, go_router's error page, a deferred page's error). A fatal crash is the app's: `FlutterError.onError` calls
  `recordFlutterFatalError`, and `PlatformDispatcher.onError` calls `recordError(..., fatal: true)`.
- **The sink reports first, and the handlers skip what it reported.** The sink calls the reporter synchronously, before an action's
  error is rethrown and before the frame that rethrows a `data()` error in `build`. `crashSink.reported(error)` answers true for an
  object the sink saw, compared by identity, over the last 32 (a report, a repeat, or a log line by class, a `FieldErrors` included).
  The handlers below skip it, so one error is reported once. `FlutterError.presentError` still runs for it, so the debug screen
  stays. The package sets no global handler: the handlers are the app's.
- **Keys are session-wide.** Crashlytics keeps custom keys for the whole session. The four error keys hold the last recorded error
  until the next one, and `fespalier_screen` is where the person is. The recipe sets each key of a report and **awaits** it before
  `recordError`, because Android runs each plugin call on a cached thread pool and the order is not otherwise kept.
- **`add`, not `install`, and once.** `startup()` runs before the router is built and returns early on the web, Linux and Windows
  (Crashlytics is Android, iOS and macOS). It adds the sink with `FespalierTelemetry.add`, behind `contains`: the splash's retry
  runs `startup()` again, and a second `add` reports every error twice.
- **`telemetry: true`.** Guards, `data()`, actions and navigations reach a sink only in an app generated with it. Without it no
  operation of the app reaches the sink: no report and no screen.
- **Synchronous, and no timer.** Installed, every call is synchronous: a sync guard or `data()` stays sync, the reporter's
  `Future` is awaited by nobody and its failure is handled where it is returned, and the sink starts no timer and listens to nothing.
  A reporter that throws costs its own call; a broken SDK never costs a feature.

## Firebase: the versions and the binding

Built on 2026-10-15 against `firebase_core` 4.15.0 and `firebase_crashlytics` 5.4.0; the floors (Flutter 3.27, Dart 3.6) are the app's.
Add `fespalier` and `fespalier_crashlytics` next to each other with the same `url` and `ref` (the package's README has the block).

```yaml
# pubspec.yaml dependencies
  firebase_core: ^4.15.0
  firebase_crashlytics: ^5.4.0
```

`FirebaseCrashReporter` is the port's binding. It is lazy, so the sink can be built before `Firebase.initializeApp` runs, and it
forwards each call to Crashlytics: `recordError` sets the keys of the report, awaits each, and then records; `setCustomKey` and `log`
are one call each.

```dart
// lib/crash/firebase_crash_reporter.dart
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:fespalier_crashlytics/fespalier_crashlytics.dart';

/// Firebase Crashlytics behind fespalier's CrashReporter port. The Firebase SDK is the app's.
final class FirebaseCrashReporter extends CrashReporter {
  FirebaseCrashReporter([FirebaseCrashlytics? crashlytics]) : _given = crashlytics;

  final FirebaseCrashlytics? _given;

  /// Lazy: `FirebaseCrashlytics.instance` needs `Firebase.initializeApp`, which `startup()` runs first.
  late final _crashlytics = _given ?? FirebaseCrashlytics.instance;

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stack, {
    required String reason,
    required Map<String, String> keys,
  }) async {
    // Crashlytics keeps keys for the session: each is set, and awaited, before the report that carries them.
    for (final MapEntry(:key, :value) in keys.entries) {
      await _crashlytics.setCustomKey(key, value);
    }
    await _crashlytics.recordError(error, stack, reason: reason);
  }

  @override
  Future<void>? setCustomKey(String key, String value) =>
      _crashlytics.setCustomKey(key, value);

  @override
  Future<void>? log(String message) => _crashlytics.log(message);
}

/// One sink for the app's life.
final crashSink = FespalierCrashlytics(FirebaseCrashReporter());
```

`startup()` runs the SDK's start-up first, then the two handlers, then adds the sink. Where Crashlytics does not run it does nothing,
so the sink is not added there either. `flutterfire configure` writes `DefaultFirebaseOptions`: pass them to `initializeApp` when the
app has them.

```dart
// lib/app/startup.dart
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';

import '../crash/firebase_crash_reporter.dart';

/// Where Crashlytics runs. Elsewhere this does nothing: no Firebase, no sink.
const Set<TargetPlatform> _crashlyticsPlatforms = {
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
};

/// Before the router is built, so the first navigation is reported. The handlers are the app's: each skips what the sink reported.
Future<void> startup() async {
  if (kIsWeb || !_crashlyticsPlatforms.contains(defaultTargetPlatform)) return;
  // `flutterfire configure` writes DefaultFirebaseOptions: pass them here when the app has them.
  await Firebase.initializeApp();
  FlutterError.onError = (details) {
    if (crashSink.reported(details.exception)) {
      FlutterError.presentError(details);
    } else {
      unawaited(FirebaseCrashlytics.instance.recordFlutterFatalError(details));
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    if (!crashSink.reported(error)) {
      unawaited(FirebaseCrashlytics.instance.recordError(error, stack, fatal: true));
    }
    return true;
  };
  // add, not install (install replaces the one slot, and it would drop an adapter's or Sentry's sink);
  // and not twice: the splash's retry runs startup() again.
  if (!FespalierTelemetry.contains(crashSink)) FespalierTelemetry.add(crashSink);
}
```

The options of the sink, in `lib/crash/firebase_crash_reporter.dart`, are `FespalierCrashlytics(FirebaseCrashReporter(), logs: false,
capture: ..., repeatWindow: Duration.zero)`. `capture:` takes `(Object error, TelemetryStart start)`: the default,
`FespalierCrashlytics.unexpected`, is every failure except a `FieldErrors`, an `auth` step and a `custom` operation.

## Testing

`package:fespalier_crashlytics/testing.dart` has `RecordingCrashlytics`, a reporter that keeps what it is given: `errors` (each a
`RecordedError`, with the error object, its stack trace, its reason and a snapshot of the keys), `keys` (the session's keys, as
Crashlytics keeps them), `logs`, `lines` (one per call: `key <name>=<value>`, `log <message>`, `error <ExceptionType> <reason>`) and
`strings` (every reason, every key value ever set and every log line, never an error object). `throwing: true` makes every call throw
after it records, and `failing: true` makes every call return a failed `Future`: a test of "the app does not notice a broken reporter".
`clear()` forgets what was recorded and keeps the session keys, as Crashlytics does.

```dart
// test/crash_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_crashlytics/fespalier_crashlytics.dart';
import 'package:fespalier_crashlytics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('a data error is one report named by its route and file, and no text is sent', () {
    final crash = RecordingCrashlytics();
    FespalierTelemetry.install(FespalierCrashlytics(crash));
    final token = FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.data,
        site: TelemetrySite(r'orders/$id/data.dart', route: '/orders/:id'),
      ),
    );
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(TelemetryOutcome.error, error: StateError('order 4242 is gone')),
    );
    expect(crash.lines, [r'error StateError in data orders/$id/data.dart on /orders/:id']);
    expect(crash.strings, everyElement(isNot(contains('4242'))));
  });
}
```

Traps:

- **A sync throw reaches the sink as the `StateError`, but `read` throws Riverpod's wrapper.** The provider's `ProviderException` is
  what the caller of `container.read` catches; the report holds the `StateError`.
- **`clear()` keeps the session keys.** After a test clears what its own boot recorded, `keys` still holds the screen the boot set:
  the sink sends an unchanged key only once, so a test that expects a key line for it must navigate to another screen first.
- **Pump before reading** the reporter in a widget test: a `data()` error reaches the sink when its `Future` settles.

## Where the code is

`packages/fespalier_crashlytics/`: `lib/src/sink.dart` (`FespalierCrashlytics`: the reasons, the keys, the repeat window, `reported`,
the log lines), `lib/src/reporter.dart` (the `CrashReporter` port), `lib/src/keys.dart` (`CrashlyticsKeys`, the five names) and
`lib/testing.dart` (`RecordingCrashlytics`, `RecordedError`). Its tests pin the reasons, the never-sent list (`privacy_test.dart`), the
identity rule (`reported_test.dart`), that it stays sync (`sync_test.dart`) and that it has no Firebase in it (`no_sdk_test.dart`).
The sink's contract is core's `FespalierTelemetry` (`packages/fespalier/lib/src/telemetry.dart`).
