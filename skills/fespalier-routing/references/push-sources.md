# Push sources: Firebase Messaging, local notifications, APNs only

Since 0.13.0. A [`PushSource`](push.md) is `initialTap()`, `taps`, `received`, `tokens`, `permission()` and
`requestPermission()`, so a bridge to a vendor is 40 lines of mapping with nothing of fespalier left in it. That is why
each vendor is a **recipe on this page, not a package**: `fespalier_push` would otherwise link Firebase into every app that
lists it, an app on OneSignal, Expo push or raw APNs would carry pods it does not use, and one `firebase_messaging` range
cannot stay inside every app's Flutter floor. **Promote the Firebase recipe to a `fespalier_push_firebase` package** only
when apps ask for a turnkey one; it would carry the Firebase pods.

The samples below are built by `just skill-samples` (`fsp gen`, `flutter analyze`): none of them runs a vendor at test time.
Built on 2026-10-07 against `firebase_core` 4.15.0, `firebase_messaging` 16.7.0 and `flutter_local_notifications` 22.3.1.
Vendor SDKs release weekly: when a major lands, rebuild this page. **The floors are the app's, not fespalier's**:
`firebase_messaging` 16.x needs Flutter 3.27 (16.0.0 resolves on 3.32 with `firebase_core ^4.0.0`), and
`flutter_local_notifications` 22.x needs Flutter 3.38.

```yaml
# pubspec.yaml dependencies
  firebase_core: ^4.15.0
  firebase_messaging: ^16.7.0
  flutter_local_notifications: ^22.3.1
```

## The rules every source follows

- **`initialTap()` is a local read**, answered once. It runs before the first frame, so it must not wait for the network.
  Firebase's `getInitialMessage()` is one platform-channel call.
- **Initialise the vendor inside the source, lazily.** `launch()` runs after the binding exists and inside the adapters'
  zones, so `Firebase.initializeApp()` belongs in the first call that needs it, not in `main()` before `AppMain.run()`
  (a binding created outside the zone `AppMain.run()` uses draws Flutter's zone-mismatch warning).
- **`taps` and `received` are listened to once per `ProviderScope`**: a single-subscription stream is fine.
- **A token that is not there yet is not an error.** On iOS `getToken()` throws `apns-token-not-set` until the APNs token
  arrives; the source yields nothing then and the refresh stream delivers the token.
- **Never put the payload in `raw` for the package to read**: `raw` is for your `PushRoute` only.

## Firebase Messaging

`getInitialMessage`, `onMessageOpenedApp` (a tap while the app is in the background), `onMessage` (a foreground delivery;
nothing is shown by the plugin), `getToken`, `onTokenRefresh`, `getNotificationSettings` and `requestPermission`.
`RemoteMessage.messageId` is the id the package deduplicates by.

```dart
// lib/push/firebase_push_source.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fespalier_push/fespalier_push.dart';

PushMessage _message(RemoteMessage m) =>
    PushMessage(id: m.messageId, data: {...m.data}, category: m.category, raw: m);

// A wildcard for the rest: 16.7 added `deniedPermanently`, which 16.0 does not have.
PushPermission _permission(AuthorizationStatus status) => switch (status) {
  AuthorizationStatus.authorized => PushPermission.granted,
  AuthorizationStatus.provisional => PushPermission.provisional,
  AuthorizationStatus.notDetermined => PushPermission.notDetermined,
  _ => PushPermission.denied,
};

/// Firebase Messaging as a [PushSource]. [initialize] is your `Firebase.initializeApp(options: ...)`.
final class FirebasePushSource extends PushSource {
  FirebasePushSource({Future<FirebaseApp> Function()? initialize})
    : _initialize = initialize ?? Firebase.initializeApp;

  final Future<FirebaseApp> Function() _initialize;

  // Lazy: the first call that needs Firebase starts it, once.
  late final Future<FirebaseMessaging> _messaging = _start();

  Future<FirebaseMessaging> _start() async {
    if (Firebase.apps.isEmpty) await _initialize();
    return FirebaseMessaging.instance;
  }

  @override
  Future<PushMessage?> initialTap() async {
    final message = await (await _messaging).getInitialMessage();
    return message == null ? null : _message(message);
  }

  // Both are static streams of the plugin; initialTap() ran first, so Firebase is started.
  @override
  Stream<PushMessage> get taps => FirebaseMessaging.onMessageOpenedApp.map(_message);

  @override
  Stream<PushMessage> get received => FirebaseMessaging.onMessage.map(_message);

  @override
  Stream<String> get tokens async* {
    final messaging = await _messaging;
    String? token;
    try {
      token = await messaging.getToken();
    } on FirebaseException {
      token = null; // iOS: the APNs token is not there yet; onTokenRefresh brings it
    }
    if (token != null) yield token;
    yield* messaging.onTokenRefresh;
  }

  @override
  Future<PushPermission> permission() async =>
      _permission((await (await _messaging).getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async =>
      _permission((await (await _messaging).requestPermission()).authorizationStatus);
}
```

Wire it with `FespalierPush.configure(source: FirebasePushSource(initialize: () => Firebase.initializeApp(options:
DefaultFirebaseOptions.currentPlatform)), route: pushRoute, onToken: ...)` in `main()` (`push.md`). On Android 13 and later
the notification permission is a runtime prompt: `requestPermission` is yours to call, at a moment the person understands.
`FirebaseMessaging.onBackgroundMessage` (a data message while the app is not running) is a top-level function of your own and
has nothing to do with taps.

## flutter_local_notifications: a foreground message shown locally

Firebase shows nothing for a message that arrives in the foreground (`received`). An app that shows it itself with
`flutter_local_notifications` gets the tap from that plugin, not from Firebase, so the source merges the two. The local
notification's `payload` carries the original `data` as JSON, and the same `PushRoute` maps both. The plugin tells a tap
that cold-started the app with `getNotificationAppLaunchDetails()`, and one while running with
`onDidReceiveNotificationResponse`.

```dart
// lib/push/local_taps.dart
import 'dart:async';
import 'dart:convert';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

PushMessage? _fromPayload(NotificationResponse? response) {
  final payload = response?.payload;
  if (payload == null) return null;
  try {
    final data = jsonDecode(payload);
    return data is Map<String, Object?>
        ? PushMessage(id: '${response?.id}', data: data)
        : null;
  } on FormatException {
    return null;
  }
}

/// The taps on notifications this app showed itself.
final class LocalTaps {
  LocalTaps(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<PushMessage> _taps = StreamController<PushMessage>.broadcast();

  /// Call once, before the source is used (the first thing its `initialTap()` awaits).
  Future<void> start() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (response) {
        final message = _fromPayload(response);
        if (message != null) _taps.add(message);
      },
    );
  }

  /// The tap that launched the app, if it was one of ours.
  Future<PushMessage?> launchTap() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.didNotificationLaunchApp == true
        ? _fromPayload(details?.notificationResponse)
        : null;
  }

  Stream<PushMessage> get taps => _taps.stream;

  /// Show a foreground message; [data] is what the tap will map.
  Future<void> show(int id, String title, String body, Map<String, Object?> data) => _plugin.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails('default', 'Notifications'),
      iOS: DarwinNotificationDetails(),
    ),
    payload: jsonEncode(data),
  );
}
```

In the Firebase source, `initialTap()` is `await local.launchTap() ?? firebaseInitial`, `taps` merges `local.taps` into
`FirebaseMessaging.onMessageOpenedApp` (`StreamGroup.merge` from `package:async`, or an `async*` with `yield*` in turn if
you need no extra dependency), and the `received` handler calls `local.show(...)`. A notification the plugin shows has an
id of its own, not Firebase's `messageId`, so a tap on it is never taken for the cold-start one by mistake. The plugin's
`show` and `initialize` take named parameters from 20.0; an older range uses positional ones.

## An APNs-only source

An app that sends to APNs directly (or through a provider with its own SDK) writes the same six members over whatever
plugin hands it a launch notification, a tap stream and a device token. The package asks only for those: `initialTap()`
from the plugin's "launch options" read, `taps` from its "opened" stream, `tokens` from its registration callback (the APNs
device token as hex is a String like any other). No APNs-only plugin has been evaluated here, so there is no recipe: the
shape of the Firebase one is the pattern, with the lazy start inside the source and no network in `initialTap()`.
