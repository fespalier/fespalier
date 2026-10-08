# Flag sources: Firebase Remote Config, LaunchDarkly, PostHog, GrowthBook, OpenFeature

Since 0.9.0. A [`FlagSource`](feature-flags.md) is four synchronous typed reads and an optional stream of changes, so a
bridge to a vendor is 15 to 40 lines of mapping with nothing of fespalier left in it: the synchronous read, the change
plumbing, disposal, the guard and the tests are in `fespalier_flags`. That is why each vendor is a **recipe on this page,
not a package**: a package per vendor would cost a release, a CI entry that resolves the vendor's SDK and a fake of its
singleton (`Posthog()`, `FirebaseRemoteConfig.instance`) to test 20 lines. **Promote a recipe to a package** only when its
glue grows fespalier-specific logic or past about 60 lines, or when OpenFeature is stable and a `fespalier_flags_openfeature`
replaces most of them.

The samples below are built by `just skill-samples` (`fsp gen`, `flutter analyze`): none of them runs a vendor at test
time. Last built on 2026-10-03 against `firebase_remote_config` 6.7.0, `launchdarkly_flutter_client_sdk` 4.21.0,
`posthog_flutter` 5.50.13, `growthbook_sdk_flutter` 4.4.0 and `openfeature_dart_client_sdk` 0.0.1-beta.2 (all five
resolve together). Vendor SDKs release weekly: when a major lands, rebuild this page. Each recipe's
`# pubspec.yaml dependencies` block is the caret range it was built against, and **its floors are the app's, not
fespalier's** (Firebase and PostHog need Flutter 3.27, LaunchDarkly 3.22, OpenFeature Dart 3.10).

```yaml
# pubspec.yaml dependencies
  firebase_remote_config: ^6.7.0
  launchdarkly_flutter_client_sdk: ^4.21.0
  posthog_flutter: ^5.50.13
  growthbook_sdk_flutter: ^4.4.0
  openfeature_dart_client_sdk: ^0.0.1-beta.2
```

## The rules every recipe follows

- **Reads come from the vendor's memory.** Guards and menus call them, so nothing awaits, reads a file or crosses a
  platform channel. A vendor with only an async read (PostHog) keeps a copy of the keys the app uses.
- **`startup()` awaits only what is local**: the vendor's disk cache, not the network. From the first frame every read is a
  synchronous call. A vendor whose start waits for the network goes in `AsyncFlags(start(), meanwhile: ...)`: the
  fallbacks until the `Future` completes, then one `FlagsChanged.all()`. Nothing here starts a timer; a `.timeout()` you
  add to `startup()` is yours.
- **`changes` is listened to by one subscription per `ProviderContainer`**, opened by the first watched flag and cancelled
  by the last, so a vendor stream is only open while a flag (a menu on screen, a guard) is watched. Say **which keys**
  changed when the vendor says so: LaunchDarkly counts an evaluation per read and GrowthBook may track an exposure, and a
  keyed `FlagsChanged({'checkout_v2'})` re-reads only that flag.
- **A read that throws is the flag's fallback** (printed in debug); a vendor SDK that is not started must not take a guard
  down.

## Firebase Remote Config

`getBool`, `getString`, `getInt` and `getDouble` read a Dart-side map of the activated values, synchronously; a key that
was never fetched or defaulted has the source `ValueSource.valueStatic`, which is how the recipe tells "no value" from
`false`. `startup()` does what is local, `ensureInitialized()` and `activate()` (the values the previous session
fetched), so the UI does not change under the user at start (the "load for next start" pattern); published changes are
activated and read again through `onConfigUpdated`.

```dart
// lib/flags/remote_config_flags.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Flags from Firebase Remote Config. Reads are the activated values; with [realtime] (not on the web, where Remote
/// Config has no real-time updates) a published change is activated and read again.
final class RemoteConfigFlags implements FlagSource {
  RemoteConfigFlags(this._config, {this.realtime = true});

  /// For startup(): the values the previous session fetched, activated; no wait for the network. Without real time, a
  /// fetch for the next start runs in the background.
  static Future<RemoteConfigFlags> start({bool realtime = true}) async {
    final config = FirebaseRemoteConfig.instance;
    await config.ensureInitialized();
    await config.activate();
    if (!realtime || kIsWeb) unawaited(config.fetch().catchError((Object _) {}));
    return RemoteConfigFlags(config, realtime: realtime);
  }

  final FirebaseRemoteConfig _config;

  /// Whether published changes apply while the app runs.
  final bool realtime;

  bool _has(String key) => _config.getValue(key).source != ValueSource.valueStatic;

  @override
  bool boolValue(String key, bool fallback) => _has(key) ? _config.getBool(key) : fallback;

  @override
  String stringValue(String key, String fallback) => _has(key) ? _config.getString(key) : fallback;

  @override
  int intValue(String key, int fallback) => _has(key) ? _config.getInt(key) : fallback;

  @override
  double doubleValue(String key, double fallback) => _has(key) ? _config.getDouble(key) : fallback;

  @override
  Stream<FlagsChanged>? get changes => realtime && !kIsWeb
      ? _config.onConfigUpdated.asyncMap((update) async {
          await _config.activate();
          return FlagsChanged(update.updatedKeys);
        })
      : null;
}

/// startup() returns this: Firebase is initialized by the app before (`Firebase.initializeApp`).
Future<List<Override>> startWithRemoteConfig() async => [
  flagSource.overrideWithValue(await RemoteConfigFlags.start()),
];
```

```dart
// in lib/app/startup.dart (a fragment: the line above is the whole start)
Future<List<Override>> startup() => startWithRemoteConfig();
```

- **Listening to `onConfigUpdated` opens Remote Config's real-time connection**, so it is open while a flag is watched (a menu
  on screen keeps it open). `FirebaseRemoteConfig`'s own docs say real-time updates are not available for the web: the recipe
  fetches in the background there and the change applies at the next start.
- `minimumFetchInterval` throttles `fetch()`; set it in `setConfigSettings`, with `setDefaults` for the first launch.
- The values activated at start are the previous session's. To apply a fetch at once instead, `await config.fetchAndActivate()`
  in `startup()`: that waits for the network, so wrap it in `AsyncFlags` or give it a `.timeout()` of your own.

## LaunchDarkly

Its variations are synchronous (`boolVariation`, `stringVariation`, `intVariation`, `doubleVariation`) and each read is an
evaluation LaunchDarkly counts; `flagChanges` is a stream of the keys that changed. `start()` resolves on the cache when
there is one, but on a first launch it "may not complete until some time in the future when the device leaves airplane
mode", which is why LaunchDarkly recommends a timeout. So the recipe does not wait for it.

```dart
// lib/flags/launchdarkly_flags.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';

/// Flags from LaunchDarkly: its variations are synchronous, and each read is an evaluation LaunchDarkly counts.
final class LaunchDarklyFlags implements FlagSource {
  const LaunchDarklyFlags(this._client);

  final LDClient _client;

  @override
  bool boolValue(String key, bool fallback) => _client.boolVariation(key, fallback);

  @override
  String stringValue(String key, String fallback) => _client.stringVariation(key, fallback);

  @override
  int intValue(String key, int fallback) => _client.intVariation(key, fallback);

  @override
  double doubleValue(String key, double fallback) => _client.doubleVariation(key, fallback);

  @override
  Stream<FlagsChanged> get changes => _client.flagChanges.map((event) => FlagsChanged(event.keys.toSet()));
}

/// The client starts in the background: its cached flags arrive as a change a few milliseconds in, and fresh ones when
/// the network answers. Nothing here waits for the network, so no timeout is needed.
Future<List<Override>> startWithLaunchDarkly() async {
  final client = LDClient(
    LDConfig(CredentialSource.fromEnvironment(), AutoEnvAttributes.enabled),
    LDContextBuilder().kind('user', 'anonymous').anonymous(true).build(),
  );
  unawaited(client.start());
  return [flagSource.overrideWithValue(LaunchDarklyFlags(client))];
}
```

```dart
// in lib/app/startup.dart (a fragment)
Future<List<Override>> startup() => startWithLaunchDarkly();
```

A `startup()` that does not await `start()` reads fallbacks in the first frames. `await client.start()` makes warm starts
exact (it resolves on the cache), but a first launch offline waits until the network comes back: that wait is yours to bound
with a `.timeout()`, which is a timer of the app's own. `LDContextBuilder().kind(...)` returns an `LDAttributesBuilder`
(`anonymous(bool)`, `build()`), from `launchdarkly_dart_common`. Put the user's key in the context only when you have one,
and never an e-mail address or a name you do not need.

## PostHog

PostHog's Flutter SDK has **no synchronous read**: `getFeatureFlag` is a `Future<Object?>` through a platform channel, and
calling it in a guard would make the guard, and the menu entry behind it, pending (a blank first frame). So the recipe
keeps a copy of the keys the app uses, read in `startup()` (from the native SDK's cache) and again whenever PostHog loads
flags (`PostHogConfig.onFeatureFlags`). A flag is a `bool`, or the variant key (a `String`); the recipe reads a variant as
"on", and numbers are payloads, not flags.

```dart
// lib/flags/posthog_flags.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// Flags from PostHog. Its Flutter SDK reads flags through a platform channel (a Future), so this keeps a copy of the
/// [keys] the app uses, read in startup() and again whenever PostHog loads flags.
final class PostHogFlags implements FlagSource {
  PostHogFlags(this.keys);

  /// The flags the app reads.
  final Set<String> keys;

  final _values = <String, Object?>{};
  final _changes = StreamController<FlagsChanged>.broadcast();

  /// Reads every key from PostHog. Call it in startup() after `Posthog().setup(config)`, and from
  /// `config.onFeatureFlags`.
  Future<void> load() async {
    for (final key in keys) {
      _values[key] = await Posthog().getFeatureFlag(key);
    }
    _changes.add(FlagsChanged(keys));
  }

  @override
  bool boolValue(String key, bool fallback) => switch (_values[key]) {
    final bool on => on,
    String() => true, // a variant: the flag is on
    _ => fallback,
  };

  @override
  String stringValue(String key, String fallback) => switch (_values[key]) {
    final String variant => variant,
    _ => fallback,
  };

  @override
  int intValue(String key, int fallback) => fallback; // PostHog flags are on/off or a variant; numbers are payloads

  @override
  double doubleValue(String key, double fallback) => fallback;

  @override
  Stream<FlagsChanged> get changes => _changes.stream;
}

/// PostHog's own SDK answers from its cache in startup(); the callback copies fresh values when it loads them.
Future<List<Override>> startWithPostHog() async {
  final flags = PostHogFlags({'checkout_v2'});
  final config = PostHogConfig(const String.fromEnvironment('POSTHOG_KEY'))
    ..onFeatureFlags = () => unawaited(flags.load());
  await Posthog().setup(config);
  await flags.load();
  return [flagSource.overrideWithValue(flags)];
}
```

```dart
// in lib/app/startup.dart (a fragment)
Future<List<Override>> startup() => startWithPostHog();
```

- **Never `Posthog().isFeatureEnabled` in a guard**: it is a `Future`, so the guard answers a `Future`, the entry turns pending
  and the first frame is blank.
- `PostHogConfig.onFeatureFlags` is a plain callback slot ("invoked when feature flags are loaded"): nothing is subscribed,
  so there is nothing to dispose. A flag read can send a `$feature_flag_called` event
  (`getFeatureFlagResult(key, sendEvent: false)` suppresses it): read the keys the app uses, not every key.

## GrowthBook

`GrowthBookSDK.feature(id)` is synchronous (`.value` is `dynamic`, `.on` a bool). The builder's `initialize()` awaits a
`refresh()`: from the cache first, and from the network when the cache is missing or older than `ttlSeconds` (60 by
default). So `startup()` returns an `AsyncFlags` over it: the app starts at once with the fallbacks, and switches with one
event when GrowthBook answers. A later refresh sends `FlagsChanged.all()` through the builder's refresh handler.

```dart
// lib/flags/growthbook_flags.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:growthbook_sdk_flutter/growthbook_sdk_flutter.dart';

/// Flags from GrowthBook: `feature(id)` reads the features it fetched (the cache first), synchronously.
final class GrowthBookFlags implements FlagSource {
  GrowthBookFlags._(this._sdk, this._changes);

  /// Waits for GrowthBook's refresh, which can wait for the network: wrap it in [AsyncFlags].
  static Future<GrowthBookFlags> start({
    required String apiHost,
    required String clientKey,
    Map<String, Object?> attributes = const {},
    void Function(GBTrackData)? onExposure,
  }) async {
    final changes = StreamController<FlagsChanged>.broadcast();
    final sdk = await GBSDKBuilderApp(
      hostURL: apiHost,
      apiKey: clientKey,
      attributes: attributes,
      // Experiment exposures: send them to your analytics here, or nowhere.
      growthBookTrackingCallBack: onExposure ?? (_) {},
    ).setRefreshHandlerV2((ok, error) {
      if (ok) changes.add(const FlagsChanged.all());
    }).initialize();
    return GrowthBookFlags._(sdk, changes);
  }

  final GrowthBookSDK _sdk;
  final StreamController<FlagsChanged> _changes;

  @override
  bool boolValue(String key, bool fallback) => switch (_sdk.feature(key).value) {
    final bool v => v,
    _ => fallback,
  };

  @override
  String stringValue(String key, String fallback) => switch (_sdk.feature(key).value) {
    final String v => v,
    _ => fallback,
  };

  @override
  int intValue(String key, int fallback) => switch (_sdk.feature(key).value) {
    final int v => v,
    _ => fallback,
  };

  @override
  double doubleValue(String key, double fallback) => switch (_sdk.feature(key).value) {
    final num v => v.toDouble(),
    _ => fallback,
  };

  @override
  Stream<FlagsChanged> get changes => _changes.stream;
}

/// The app starts at once with the fallbacks, and switches when GrowthBook answers.
Future<List<Override>> startWithGrowthBook() async => [
  flagSource.overrideWithValue(
    AsyncFlags(
      GrowthBookFlags.start(
        apiHost: 'https://cdn.growthbook.io',
        clientKey: const String.fromEnvironment('GROWTHBOOK_KEY'),
      ),
    ),
  ),
];
```

```dart
// in lib/app/startup.dart (a fragment)
Future<List<Override>> startup() => startWithGrowthBook();
```

- **A read can start a refresh.** `feature(id)` fetches in the background when the cache is older than `ttlSeconds` (no
  timer: it happens on a read), and the refresh handler then sends the event. `backgroundSync: true` (server-sent events)
  is the SDK's own streaming, by its settings.
- GrowthBook's **tracking plugin** runs a `Timer.periodic` flush when the app registers it. That timer is the app's choice,
  and tests override `flagSource`, so they never construct it.
- A cold deep link before GrowthBook answers sees the fallbacks, so a guard sends it to `orElse`. If that is wrong, await the
  SDK in `startup()` with a `.timeout()` of your own, or give `AsyncFlags` a `meanwhile: ConstFlags({...last known})`.

## OpenFeature (a sketch)

OpenFeature is the common interface the vendors above are converging on, and `FlagSource` mirrors it: its static-context
client has `getBooleanValue`, `getStringValue`, `getIntegerValue` and `getDoubleValue`, synchronously ("a resolver must use
local state"), and a provider event, `ProviderEventType.configurationChanged`, with the keys that changed.
**`openfeature_dart_client_sdk` was `0.0.1-beta.2` when this page was written and is `0.0.1` since 2026-10-05 (the sample still builds on it, re-checked 2026-10-08)**, a `0.0.x` interface that must not be fespalier's public API, so it is a
recipe: the API may change, and fespalier will converge on it when it is stable and has Dart providers for the vendors.

```dart
// lib/flags/openfeature_flags.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';

/// Flags from an OpenFeature client: the four typed reads, and its `configurationChanged` event as `changes`.
final class OpenFeatureFlags implements FlagSource {
  OpenFeatureFlags(this._client);

  final OpenFeatureClient _client;

  @override
  bool boolValue(String key, bool fallback) => _client.getBooleanValue(key, fallback);

  @override
  String stringValue(String key, String fallback) => _client.getStringValue(key, fallback);

  @override
  int intValue(String key, int fallback) => _client.getIntegerValue(key, fallback);

  @override
  double doubleValue(String key, double fallback) => _client.getDoubleValue(key, fallback);

  /// A handler is registered while something listens, and cancelled with the last listener.
  @override
  Stream<FlagsChanged> get changes {
    ProviderEventSubscription? subscription;
    late final StreamController<FlagsChanged> controller;
    controller = StreamController<FlagsChanged>.broadcast(
      onListen: () {
        subscription = _client.addHandler(ProviderEventType.configurationChanged, (details) {
          controller.add(
            details.flagsChanged.isEmpty
                ? const FlagsChanged.all()
                : FlagsChanged(details.flagsChanged.toSet()),
          );
        });
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }
}

/// [provider] is the vendor's OpenFeature provider. `setProviderAndWait` bounds its own lifecycle wait with a 30 second
/// timer: an app that awaits it in startup() accepts that timer, and `setProvider` does not wait.
Future<List<Override>> startWithOpenFeature(FeatureProvider provider) async {
  await OpenFeatureAPI.instance.setProviderAndWait(provider);
  return [flagSource.overrideWithValue(OpenFeatureFlags(OpenFeatureAPI.instance.getClient()))];
}
```

## Other vendors

**Flagsmith** (`flagsmith` 6.2.0), **Unleash** (`unleash_proxy_client_flutter` 1.9.8, last released 2025-08) and **Statsig**
(`statsig` 1.2.9, no verified publisher) have the same five members: a synchronous check on a client that holds the
flags in memory (or a copy of them), a stream or callback for updates, and a start that is either local or waits for the
network. Write the four reads and `changes` as above, and decide with the vendor's start whether it goes in `startup()` or in
an `AsyncFlags`. There is no compiled sample: add one when an app needs it.

## Check before you copy

- **Is the read synchronous?** If the SDK only has a `Future`, copy the values into a map the source reads, and send a
  `FlagsChanged` when you reload them (PostHog).
- **Does the start wait for the network?** Then it goes in `AsyncFlags`, or in `startup()` with your own `.timeout()`.
- **Does the stream start something while listened?** Remote Config's real-time connection does: it is open while a flag is
  watched. Make `changes` `null` where the vendor has no events, and the app reads the values at the next start.
- **What does a read cost?** LaunchDarkly counts evaluations and GrowthBook may track exposures: use keyed `FlagsChanged`
  events, and never read a flag in a `build` that runs every frame.
- **What goes to the vendor?** Never put personal information in a context or attribute you do not need.
