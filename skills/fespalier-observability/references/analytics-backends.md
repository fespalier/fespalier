# Analytics backends: Firebase Analytics, PostHog, Mixpanel, Amplitude

Since 0.13.0. An [`AnalyticsBackend`](analytics.md) is `screenView`, `screenTime` and `consentChanged`, so a bridge to a vendor is
twenty lines of mapping with nothing of fespalier left in it. That is why each vendor is a **recipe on this page, not a package**:
`fespalier_analytics` would otherwise link Firebase into every app that lists it, an app on PostHog would carry pods it does not
use, and one vendor range cannot stay inside every app's Flutter floor. The same rule keeps `fespalier_flags` free of its sources.

The samples below are built by `just skill-samples` (`fsp gen`, `flutter analyze`): none of them runs a vendor at test time.
Built on 2026-10-07 against `firebase_core` 4.15.0, `firebase_analytics` 12.6.0, `posthog_flutter` 5.51.1, `mixpanel_flutter` 2.15.0 and
`amplitude_flutter` 4.7.3. Vendor SDKs release weekly: when a major lands, rebuild this page. **The floors are the app's, not
fespalier's**: `firebase_analytics` 12.x needs Flutter 3.27, `posthog_flutter` 5.x needs Flutter 3.27, and the Mixpanel and Amplitude
packages need 3.19.

```yaml
# pubspec.yaml dependencies
  firebase_core: ^4.15.0
  firebase_analytics: ^12.6.0
  posthog_flutter: ^5.51.1
  mixpanel_flutter: ^2.15.0
  amplitude_flutter: ^4.7.3
```

## The rules every backend follows

- **The vendor starts with collection off, and `consentChanged` turns it on.** The sink never tells the backend the initial
  `consent:`, and an SDK that collects from its first line has already sent something before the person answered. Each recipe
  names its switch.
- **Return at once; never await.** The sink calls the backend synchronously from the router. A vendor call that returns a `Future`
  goes through `ignoreFuture`, which reports a failure with `FlutterError.reportError` and throws nothing.
- **Initialise the vendor lazily, after the binding exists.** `FespalierAnalytics.configure` runs in `main()` before
  `AppMain.run()`, before `WidgetsFlutterBinding.ensureInitialized()`; a platform-channel call there fails. Mixpanel and Amplitude
  are created on first use (`late final`); Firebase's `initializeApp` is yours, in `startup()` or the first call.
- **One screen, one count.** Switch off the vendor's own screen tracking (an observer such as `FirebaseAnalyticsObserver`,
  `PosthogObserver` or `AmplitudeNavigatorObserver`, or an autocapture of screens): fespalier reports the page.
- **Send the pattern, not the URL.** `view.name` and `view.pattern` hold no segment value; put `view.source` and `view.returning`
  in properties if you want them. Never add the location of the router to an event.
- **Time on screen is an event of your own** (`screen_time`), with the seconds; the vendors' own "time on screen" needs their observers.

## Shared: `ignoreFuture`

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
```

## Firebase Analytics

`logScreenView(screenName:, screenClass:, parameters:)` (an event `screen_view`), `logEvent`, `setConsent` and
`setAnalyticsCollectionEnabled`. Collection starts off with `firebase_analytics_collection_enabled` set to `false` in the Android
manifest (`<meta-data android:name="firebase_analytics_collection_enabled" android:value="false" />`), `FIREBASE_ANALYTICS_COLLECTION_ENABLED`
set to `NO` in `Info.plist`, and, on the web, `setAnalyticsCollectionEnabled(false)` right after `Firebase.initializeApp`. Google's
consent mode (`setConsent`) gets the same answer for `analytics_storage` **only**: `ad_storage`, `ad_user_data` and
`ad_personalization` need their own question, so this recipe leaves them alone. Their defaults are `google_analytics_default_allow_ad_storage`,
`..._ad_user_data` and `..._ad_personalization` (Android manifest, `false` to deny) and the `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE`,
`..._AD_USER_DATA` and `..._AD_PERSONALIZATION` keys of `Info.plist` (`NO` to deny), next to `google_analytics_default_allow_analytics_storage`
and `GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE`. Firebase's automatic screen reporting on iOS and Android is for native
view controllers and activities: it sees one screen in a Flutter app, so it does not count twice, but turn it off with
`FirebaseAutomaticScreenReportingEnabled` (`false`) and `google_analytics_automatic_screen_reporting_enabled` (`false`) if you want the
numbers clean.

```dart
// lib/analytics/firebase_backend.dart
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:my_app/analytics/ignore.dart';

/// Firebase Analytics as an [AnalyticsBackend]. `Firebase.initializeApp` is the app's.
class FirebaseAnalyticsBackend extends AnalyticsBackend {
  /// Reports to [analytics], or to `FirebaseAnalytics.instance`.
  FirebaseAnalyticsBackend([FirebaseAnalytics? analytics])
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  @override
  void screenView(ScreenView view) => ignoreFuture(
    _analytics.logScreenView(
      screenName: view.name,
      screenClass: view.pattern,
      parameters: {
        if (view.source != null) 'source': view.source!,
        if (view.returning) 'returning': 'true',
      },
    ),
    'logScreenView',
  );

  @override
  void screenTime(ScreenTime time) => ignoreFuture(
    _analytics.logEvent(
      name: 'screen_time',
      parameters: {
        'screen_name': time.name,
        'screen_class': time.pattern,
        'seconds': time.duration.inSeconds,
      },
    ),
    'logEvent screen_time',
  );

  @override
  void consentChanged(AnalyticsConsent consent) {
    final on = consent == AnalyticsConsent.granted;
    ignoreFuture(
      _analytics.setAnalyticsCollectionEnabled(on),
      'setAnalyticsCollectionEnabled',
    );
    ignoreFuture(
      // Analytics storage only: the ad_* flags are a separate question, asked and stored apart.
      _analytics.setConsent(analyticsStorageConsentGranted: on),
      'setConsent',
    );
  }
}
```

## PostHog

`Posthog().screen(screenName:, properties:)`, `capture(eventName:, properties:)`, `optIn()` and `optOut()`. Set up the SDK with
`config.optOut = true` (the default is `false`), which keeps it silent until `consentChanged` calls `optIn()`; leave the screen
observer (`PosthogObserver`) out of `MaterialApp.router`. `Posthog().setup(config)` is yours, in `startup()`.

```dart
// lib/analytics/posthog_backend.dart
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:my_app/analytics/ignore.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// PostHog as an [AnalyticsBackend]. `Posthog().setup(config)` is the app's, with `config.optOut = true`.
class PostHogBackend extends AnalyticsBackend {
  /// Reports to [posthog], or to the `Posthog()` singleton.
  PostHogBackend([Posthog? posthog]) : _posthog = posthog ?? Posthog();

  final Posthog _posthog;

  @override
  void screenView(ScreenView view) => ignoreFuture(
    _posthog.screen(
      screenName: view.name,
      properties: {
        'pattern': view.pattern,
        if (view.source != null) 'source': view.source!,
        'returning': view.returning,
      },
    ),
    'screen',
  );

  @override
  void screenTime(ScreenTime time) => ignoreFuture(
    _posthog.capture(
      eventName: 'screen_time',
      properties: {
        'screen_name': time.name,
        'pattern': time.pattern,
        'seconds': time.duration.inSeconds,
      },
    ),
    'capture screen_time',
  );

  @override
  void consentChanged(AnalyticsConsent consent) => ignoreFuture(
    consent == AnalyticsConsent.granted
        ? _posthog.optIn()
        : _posthog.optOut(),
    'optIn or optOut',
  );
}
```

## Mixpanel

`Mixpanel.init(token, optOutTrackingDefault:, trackAutomaticEvents:)` (a `Future`), `track(eventName, properties:)`,
`optInTracking()` and `optOutTracking()`. Start with `optOutTrackingDefault: true` and `trackAutomaticEvents: false`. The
backend creates the SDK on first use, after the binding exists; the calls queue behind that future.

```dart
// lib/analytics/mixpanel_backend.dart
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:mixpanel_flutter/mixpanel_flutter.dart';
import 'package:my_app/analytics/ignore.dart';

/// Mixpanel as an [AnalyticsBackend]; the SDK starts opted out, on first use.
class MixpanelBackend extends AnalyticsBackend {
  /// Reports to the project of [token]. A project token is public: it is in the app anyway.
  MixpanelBackend(this._token);

  final String _token;

  late final Future<Mixpanel> _mixpanel = Mixpanel.init(
    _token,
    optOutTrackingDefault: true,
    trackAutomaticEvents: false,
  );

  @override
  void screenView(ScreenView view) => ignoreFuture(
    _mixpanel.then(
      (m) => m.track(
        'Screen View',
        properties: {
          'screen_name': view.name,
          'pattern': view.pattern,
          if (view.source != null) 'source': view.source!,
          'returning': view.returning,
        },
      ),
    ),
    'track Screen View',
  );

  @override
  void screenTime(ScreenTime time) => ignoreFuture(
    _mixpanel.then(
      (m) => m.track(
        'Screen Time',
        properties: {
          'screen_name': time.name,
          'pattern': time.pattern,
          'seconds': time.duration.inSeconds,
        },
      ),
    ),
    'track Screen Time',
  );

  @override
  void consentChanged(AnalyticsConsent consent) => ignoreFuture(
    _mixpanel.then(
      (m) => consent == AnalyticsConsent.granted
          ? m.optInTracking()
          : m.optOutTracking(),
    ),
    'optInTracking or optOutTracking',
  );
}
```

## Amplitude

`Amplitude(Configuration(apiKey:, optOut:))`, `track(BaseEvent(type, eventProperties:))` and `setOptOut(bool)`. Start with
`optOut: true`; the SDK is created on first use, because its constructor calls the platform channel. Leave
`AmplitudeNavigatorObserver` out and autocapture of screens off.

```dart
// lib/analytics/amplitude_backend.dart
import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:my_app/analytics/ignore.dart';

/// Amplitude as an [AnalyticsBackend]; the SDK starts opted out, on first use.
class AmplitudeBackend extends AnalyticsBackend {
  /// Reports to the project of [apiKey]. A project API key is public: it is in the app anyway.
  AmplitudeBackend(this._apiKey);

  final String _apiKey;

  late final Amplitude _amplitude = Amplitude(
    Configuration(apiKey: _apiKey, optOut: true),
  );

  @override
  void screenView(ScreenView view) => ignoreFuture(
    _amplitude.track(
      BaseEvent(
        'Screen View',
        eventProperties: {
          'screen_name': view.name,
          'pattern': view.pattern,
          if (view.source != null) 'source': view.source,
          'returning': view.returning,
        },
      ),
    ),
    'track Screen View',
  );

  @override
  void screenTime(ScreenTime time) => ignoreFuture(
    _amplitude.track(
      BaseEvent(
        'Screen Time',
        eventProperties: {
          'screen_name': time.name,
          'pattern': time.pattern,
          'seconds': time.duration.inSeconds,
        },
      ),
    ),
    'track Screen Time',
  );

  @override
  void consentChanged(AnalyticsConsent consent) => ignoreFuture(
    _amplitude.setOptOut(consent != AnalyticsConsent.granted),
    'setOptOut',
  );
}
```

## Loading the stored answer

Asking is the app's, and so is storing the answer. Load it in `startup()`, which runs before the router, so the first screen is
not lost, and configure the sink in `main()` with whichever backend you chose:

```dart
// In lib/main.dart and lib/app/startup.dart (fragments):
Future<void> main() {
  FespalierAnalytics.configure(PostHogBackend(), screenName: screenName);
  return AppMain.run();
}

Future<List<Override>> startup() async {
  final stored = await loadConsent(); // your storage: AnalyticsConsent.undecided on a first launch
  FespalierAnalytics.sink?.consent = stored; // tells the backend, only when it is not undecided
  return [];
}
```

A first launch is `undecided`: nothing is sent, nothing is kept, and a banner (or a settings row) calls
`ref.read(analyticsConsent.notifier).set(...)` and stores the answer. A person who changed their mind has `denied` stored, and the
backend is told at start-up before the first screen.
