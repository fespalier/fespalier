# Push sources: Firebase, APNs, HMS, UnifiedPush, OneSignal, JPush, flutter_mix_push, local notifications

Since 0.13.0; the tokens are `PushToken` and `PushTokenRevoked` since 0.14.0 (they were `String`). A [`PushSource`](push.md) is
`initialTap()`, `taps`, `received`, `tokens`, `revocations` (default: none), `permission()` and `requestPermission()`, so a bridge to a vendor is 40 lines of mapping with nothing of fespalier left in it. That is why
each vendor is a **recipe on this page, not a package**: `fespalier_push` would otherwise link Firebase into every app that
lists it, an app on OneSignal, Expo push or raw APNs would carry pods it does not use, and one `firebase_messaging` range
cannot stay inside every app's Flutter floor. **Promote the Firebase recipe to a `fespalier_push_firebase` package** only
when apps ask for a turnkey one; it would carry the Firebase pods.

The samples below are built by `just skill-samples` (`fsp gen`, `flutter analyze`): none of them runs a vendor at test time.
Built on 2026-10-08 against `firebase_core` 4.15.0, `firebase_messaging` 16.7.0, `flutter_local_notifications` 22.3.1,
`huawei_push` 6.15.0+300, `unifiedpush` 6.2.0, `onesignal_flutter` 5.7.0, `jpush_flutter` 3.5.8 and `flutter_mix_push` 1.0.0
(the APNs recipe uses no package). Only `analyze` runs: no vendor starts, and the native side (keys, manifests, entitlements)
is never built.
Vendor SDKs release weekly: when a major lands, rebuild this page. **The floors are the app's, not fespalier's**:
`firebase_messaging` 16.x needs Flutter 3.27 (16.0.0 resolves on 3.32 with `firebase_core ^4.0.0`), and
`flutter_local_notifications` 22.x needs Flutter 3.38.

```yaml
# pubspec.yaml dependencies
  firebase_core: ^4.15.0
  firebase_messaging: ^16.7.0
  flutter_local_notifications: ^22.3.1
  huawei_push: ^6.15.0+300
  unifiedpush: ^6.2.0
  onesignal_flutter: ^5.7.0
  jpush_flutter: ^3.5.8
  flutter_mix_push: ^1.0.0
```

## The rules every source follows

- **`initialTap()` is a local read**, answered once. It runs before the first frame, so it must not wait for the network.
  Firebase's `getInitialMessage()` is one platform-channel call.
- **Initialise the vendor inside the source, lazily.** `launch()` runs after the binding exists and inside the adapters'
  zones, so `Firebase.initializeApp()` belongs in the first call that needs it, not in `main()` before `AppMain.run()`
  (a binding created outside the zone `AppMain.run()` uses draws Flutter's zone-mismatch warning).
- **`taps` and `received` are listened to once per `ProviderScope`**: make them broadcast streams (a rebuilt scope listens again). The Firebase source below ends them with `asBroadcastStream()`.
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

import 'with_tokens.dart';

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

  // Static streams of the plugin; Firebase is started before either is read, whatever ran first.
  @override
  Stream<PushMessage> get taps => Stream.fromFuture(
    _messaging,
  ).asyncExpand((_) => FirebaseMessaging.onMessageOpenedApp.map(_message)).asBroadcastStream();

  @override
  Stream<PushMessage> get received => Stream.fromFuture(
    _messaging,
  ).asyncExpand((_) => FirebaseMessaging.onMessage.map(_message)).asBroadcastStream();

  // kind `fcm` on every platform: Firebase hands out its own token on iOS too (the APNs one stays inside it).
  // `tokens` is listened to more than once (the pushToken provider and the adapter): SharedTokens (with_tokens.dart)
  // opens Firebase's refresh stream once and gives every listener the current token first.
  late final SharedTokens _tokens = SharedTokens(onFirstListen: () => unawaited(_begin()));

  @override
  Stream<PushToken> get tokens => _tokens.stream;

  Future<void> _begin() async {
    try {
      final messaging = await _messaging;
      // Refreshes first, so one that arrives between getToken() and the first listener is not lost.
      messaging.onTokenRefresh.listen(_publish, onError: _tokens.addError);
      await register();
    } on Object catch (error, stack) {
      _tokens.reset(); // the next listen of `tokens` starts again
      _tokens.addError(error, stack);
    }
  }

  void _publish(String value) => _tokens.add(PushToken(kind: PushTokenKind.fcm, value: value));

  // Firebase has no "token invalidated" callback (a dead token is the send API's `UNREGISTERED`): a revocation is the
  // app's own call to [revoke], on sign-out.
  final StreamController<PushTokenRevoked> _revoked = StreamController<PushTokenRevoked>.broadcast();

  @override
  Stream<PushTokenRevoked> get revocations => _revoked.stream;

  /// Deletes the token, then reports the revocation.
  Future<void> revoke() async {
    await (await _messaging).deleteToken();
    _tokens.forget();
    _revoked.add(PushTokenRevoked(kind: PushTokenKind.fcm));
  }

  /// Asks Firebase for the token and delivers it to `tokens`. Done once at start; after [revoke] (a new sign-in) the app
  /// must call it: Firebase makes no token by itself after `deleteToken`.
  Future<void> register() async {
    try {
      final value = await (await _messaging).getToken();
      if (value != null) _publish(value);
    } on FirebaseException {
      // iOS: the APNs token is not there yet; onTokenRefresh brings it
    }
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
DefaultFirebaseOptions.currentPlatform)), route: pushRoute, onToken: ..., onTokenRevoked: ...)` in `main()` (`push.md`). On iOS a foreground message shows nothing unless you call `FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true)`; on Android set `com.google.firebase.messaging.default_notification_channel_id` in the manifest for the channel notifications use. On Android 13 and later
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
        ? PushMessage(id: data['fcm_id'] as String?, data: data)
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

  /// Show a foreground message; [data] is what the tap will map. Put the Firebase `messageId` in
  /// `data['fcm_id']` (or leave it out): it is the tap's message id, and a constant would stop
  /// the package telling two notifications apart.
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
you need no extra dependency), and the `received` handler calls `local.show(...)`. The tap's message id is the Firebase
`messageId` kept in the payload as `fcm_id` (null when absent), never the plugin's own notification id, which is often a
constant: the package opens every tap but the one that cold-started the app twice. The plugin's
`show` and `initialize` take named parameters from 20.0; an older range uses positional ones.

## The token side of a vendor: `PushToken` and `PushTokenRevoked`

Since 0.14.0 a source hands over a `PushToken` (an open `kind`, a non-null `value`, `properties` for what the backend
needs besides the token) and, separately, a `PushTokenRevoked` when the vendor says the registration is gone. Before 0.14.0
it was a `String`, which fitted FCM and APNs and nothing else. Two rules of the recipes below:

- **`kind` is a `PushTokenKind` constant when there is one** (`fcm`, `apns`, `hms`, `unifiedpush`, `onesignal`, `mipush`,
  `oppo`, `vivo`, `honor`, `jpush`) and any string otherwise (Meizu's `meizu` below). The backend routes by it.
- **`properties` holds what the backend cannot derive from `value`**: OneSignal's subscription id, a UnifiedPush instance and
  Web Push keys, the APNs environment. Keep secrets out: a `PushToken` prints its kind only, but `properties` still travels
  to whatever `onToken` does.
- **Most vendors have no client-side "token invalidated" callback.** FCM, APNs, HMS and JPush only change a token (a refresh
  on `tokens`) or stop on the app's own call (`deleteToken`, `unregisterForRemoteNotifications`, `stopPush`); the backend learns
  of a dead token from the vendor's answer to a send (APNs `410`, FCM `UNREGISTERED`). Their recipes emit a
  `PushTokenRevoked` **when the app calls the vendor's unregister**, so that `onTokenRevoked` runs on sign-out. UnifiedPush
  and OneSignal do have a callback, and the recipes map it.

The recipes below implement the token half as a `TokenFeed`, and `WithTokens` joins it to whatever gives the taps (a
local-notifications source, one of your own). One file all of them share:

```dart
// lib/push/with_tokens.dart
import 'dart:async';

import 'package:fespalier_push/fespalier_push.dart';

/// The token half of a vendor SDK (since 0.14.0).
abstract interface class TokenFeed {
  /// The current token, then each refresh.
  Stream<PushToken> get tokens;

  /// A token that stopped being valid.
  Stream<PushTokenRevoked> get revocations;
}

/// A token stream that every listener may join (since 0.14.0). `PushSource.tokens` is listened to more than once (the
/// `pushToken` provider and the adapter each listen), and a vendor stream on a platform channel must be opened once:
/// Flutter's `EventChannel.receiveBroadcastStream()` makes a new controller per call, and two of them on one channel
/// replace each other's handler, so either cancel silences both. The first listen opens the vendor side ([source] and/or
/// [onFirstListen]); each listener then gets the current token first and every later one.
///
/// One per source, living as long as the app.
final class SharedTokens {
  SharedTokens({this.source, this.onFirstListen});

  /// Opens the vendor's stream; called once, on the first listen.
  final Stream<PushToken> Function()? source;

  /// Called once, on the first listen, to start the vendor side that feeds [add].
  final void Function()? onFirstListen;

  final StreamController<PushToken> _out = StreamController<PushToken>.broadcast();
  PushToken? _current;
  bool _opened = false;

  /// The tokens, for `PushSource.tokens`.
  Stream<PushToken> get stream => Stream.multi((listener) {
    if (!_opened) {
      _opened = true;
      try {
        source?.call().listen(add, onError: addError);
        onFirstListen?.call();
      } on Object {
        _opened = false; // the next listen retries
        rethrow;
      }
    }
    final current = _current;
    if (current != null) listener.add(current);
    final subscription = _out.stream.listen(listener.add, onError: listener.addError);
    listener.onCancel = subscription.cancel;
  });

  /// The vendor side failed to start (an `onFirstListen` that works asynchronously): the next listen starts it again.
  void reset() => _opened = false;

  /// A token from the vendor: the new current one.
  void add(PushToken token) {
    _current = token;
    _out.add(token);
  }

  /// A vendor error, for every listener.
  void addError(Object error, [StackTrace? stack]) => _out.addError(error, stack);

  /// The token was revoked: a later listener must not get it first.
  void forget() => _current = null;
}

/// [base]'s taps, messages and permission, with [feed]'s tokens and revocations.
final class WithTokens extends PushSource {
  const WithTokens(this.base, this.feed);

  final PushSource base;
  final TokenFeed feed;

  @override
  FutureOr<PushMessage?> initialTap() => base.initialTap();

  @override
  Stream<PushMessage> get taps => base.taps;

  @override
  Stream<PushMessage> get received => base.received;

  @override
  Stream<PushToken> get tokens => feed.tokens;

  @override
  Stream<PushTokenRevoked> get revocations => feed.revocations;

  @override
  Future<PushPermission> permission() => base.permission();

  @override
  Future<PushPermission> requestPermission() => base.requestPermission();
}
```

## APNs, directly

`kind: PushTokenKind.apns`, `value`: the device token as hex, `properties`: `environment` (`sandbox` or `production`: the
backend must send to the matching APNs host, and a debug build's token is a sandbox one). **No Flutter package is recipe-grade
for it**: `flutter_apns_only` and `flutter_apns` were last released in 2022 against Dart 2, and `apns_flutter` in 2020. The
recipe is therefore a channel of your own, a dozen lines of Swift in `AppDelegate` and no third-party package:

```swift
// ios/Runner/AppDelegate.swift (sketch, not compiled by the skills' samples)
override func application(_ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
  let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
  #if DEBUG
  let environment = "sandbox"
  #else
  let environment = "production"
  #endif
  lastToken = ["token": hex, "environment": environment]  // kept: the token can arrive before Dart listens
  apnsSink?(lastToken!)                                    // the EventChannel's sink, kept from onListen
}
// StreamHandler.onListen(arguments:eventSink:): apnsSink = eventSink; if let t = lastToken { eventSink(t) }
// MethodChannel "unregister": UIApplication.shared.unregisterForRemoteNotifications()
// MethodChannel "register":   UIApplication.shared.registerForRemoteNotifications()
```

```dart
// lib/push/apns_tokens.dart
import 'dart:async';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:flutter/services.dart';

import 'with_tokens.dart';

/// The APNs device token through the app's own channels.
final class ApnsTokens implements TokenFeed {
  static const MethodChannel _methods = MethodChannel('app.example/apns');
  static const EventChannel _events = EventChannel('app.example/apns/token');

  final StreamController<PushTokenRevoked> _revoked = StreamController<PushTokenRevoked>.broadcast();

  // The native stream is opened once, on the first listen; every listener gets the current token first.
  late final SharedTokens _tokens = SharedTokens(
    source: () => _events.receiveBroadcastStream().map((event) {
      final map = Map<String, String>.from(event as Map);
      return PushToken(
        kind: PushTokenKind.apns,
        value: map['token']!,
        properties: {'environment': map['environment'] ?? 'production'},
      );
    }),
  );

  @override
  Stream<PushToken> get tokens => _tokens.stream;

  /// APNs has no client-side invalidation callback: a revocation is the app's own call (sign-out).
  @override
  Stream<PushTokenRevoked> get revocations => _revoked.stream;

  /// Asks iOS for a token; the person's permission is a separate prompt (`requestPermission`).
  Future<void> register() => _methods.invokeMethod<void>('register');

  /// Unregisters from APNs, then reports the revocation.
  Future<void> unregister() async {
    await _methods.invokeMethod<void>('unregister');
    _tokens.forget();
    _revoked.add(PushTokenRevoked(kind: PushTokenKind.apns));
  }
}
```

`WithTokens(yourTapSource, ApnsTokens())` is the source. The native half of the taps (`userNotificationCenter(_:didReceive:)`
and the launch options) is the same kind of channel and is not repeated here.

## Huawei Push Kit (`huawei_push`)

`kind: PushTokenKind.hms`, `value`: the Push Kit token, no `properties` needed. The plugin (6.15.0+300) is Android only and needs
HMS Core on the device and the AppGallery Connect setup (`agconnect-services.json`); `getToken(scope)` returns nothing, the token arrives
on `Push.getTokenStream` (with the errors), and a refresh arrives there too. `scope` is an empty string for the default
app. There is no invalidation callback; `Push.deleteToken('')` is the app's own.

```dart
// lib/push/hms_tokens.dart
import 'dart:async';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:huawei_push/huawei_push.dart';

import 'with_tokens.dart';

/// Huawei Push Kit tokens.
final class HmsTokens implements TokenFeed {
  final StreamController<PushTokenRevoked> _revoked = StreamController<PushTokenRevoked>.broadcast();

  // `Push.getTokenStream` makes a new platform stream per call: SharedTokens opens it once.
  late final SharedTokens _tokens = SharedTokens(source: _open);

  Stream<PushToken> _open() async* {
    // The answer comes on the stream one event-loop turn after this call, and `yield*` subscribes in this one.
    Push.getToken('');
    yield* Push.getTokenStream.map((value) => PushToken(kind: PushTokenKind.hms, value: value));
  }

  @override
  Stream<PushToken> get tokens => _tokens.stream;

  @override
  Stream<PushTokenRevoked> get revocations => _revoked.stream;

  /// Asks Push Kit for a token again; it arrives on `tokens`. `_open` ran once, so after [deleteToken] the app must call
  /// this (a new sign-in): Push Kit makes no token by itself.
  void register() => Push.getToken('');

  /// Deletes the token (the app's sign-out), then reports the revocation.
  Future<void> deleteToken() async {
    await Push.deleteToken('');
    _tokens.forget();
    _revoked.add(PushTokenRevoked(kind: PushTokenKind.hms));
  }
}
```

## UnifiedPush (`unifiedpush`)

`kind: PushTokenKind.unifiedpush`, **`value`: the endpoint URL** the distributor gave, `properties`: `instance` (always),
and `pub_key` and `auth` when the endpoint has Web Push keys (an app server that encrypts needs them). UnifiedPush has the
callback the others lack: `onUnregistered(instance)` is the distributor dropping the registration (the user removed the
app from it, or uninstalled the distributor), and the recipe maps it to a `PushTokenRevoked` with the `instance`. Messages
arrive on `onMessage` as bytes the app shows itself; they are not notification taps, so this feed has no taps.
unifiedpush 6.2.0 is Android (and Linux with D-Bus options); the user picks a distributor, or the app uses the default one.

```dart
// lib/push/unifiedpush_tokens.dart
import 'dart:async';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'with_tokens.dart';

/// UnifiedPush endpoints as tokens.
final class UnifiedPushTokens implements TokenFeed {
  final StreamController<PushToken> _tokens = StreamController<PushToken>.broadcast();
  final StreamController<PushTokenRevoked> _revoked = StreamController<PushTokenRevoked>.broadcast();
  PushToken? _current;

  /// Wires the callbacks and registers with the distributor the user chose (or the default one).
  /// Answers false when there is none: show a picker (`UnifiedPush.getDistributors`, `saveDistributor`).
  Future<bool> start({String instance = 'default'}) async {
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, instance) {
        final keys = endpoint.pubKeySet;
        final token = PushToken(
          kind: PushTokenKind.unifiedpush,
          value: endpoint.url,
          properties: {
            'instance': instance,
            if (keys != null) 'pub_key': keys.pubKey,
            if (keys != null) 'auth': keys.auth,
          },
        );
        _current = token;
        _tokens.add(token);
      },
      onUnregistered: (instance) {
        _current = null;
        _revoked.add(PushTokenRevoked(kind: PushTokenKind.unifiedpush, properties: {'instance': instance}));
      },
    );
    if (!await UnifiedPush.tryUseCurrentOrDefaultDistributor()) return false;
    await UnifiedPush.register(instance: instance);
    return true;
  }

  @override
  Stream<PushToken> get tokens async* {
    final current = _current;
    if (current != null) yield current;
    yield* _tokens.stream;
  }

  @override
  Stream<PushTokenRevoked> get revocations => _revoked.stream;
}
```

## OneSignal (`onesignal_flutter`)

`kind: PushTokenKind.onesignal`, `value`: the push subscription's token (the FCM or APNs token OneSignal registered),
`properties`: `subscription_id`, **the id OneSignal's own API sends to**: a backend that sends through OneSignal needs it, not the
token. OneSignal has an observer on the push subscription: when the token is gone or the user is opted out the recipe emits a
`PushTokenRevoked` with the previous `subscription_id`. The click listener buffers a click that arrived before it existed, so
a cold-start tap comes through `taps` (after the first frame) and `initialTap()` answers null. Call
`OneSignal.initialize(appId)` in `main()` before `FespalierPush.configure`; the plugin is a static singleton, so there is no lazy start to
keep. `onesignal_flutter` 5.7.0.

```dart
// lib/push/onesignal_push_source.dart
import 'dart:async';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

PushMessage _message(OSNotification notification) => PushMessage(
  id: notification.notificationId,
  data: {...?notification.additionalData},
  raw: notification,
);

PushToken? _tokenOf(OSPushSubscriptionState state) {
  final token = state.token;
  if (token == null || !state.optedIn) return null;
  return PushToken(
    kind: PushTokenKind.onesignal,
    value: token,
    properties: {if (state.id != null) 'subscription_id': state.id!},
  );
}

/// OneSignal as a [PushSource].
final class OneSignalPushSource extends PushSource {
  OneSignalPushSource();

  // Lazy and once: the listeners are the plugin's, added on the first listen.
  late final Stream<PushMessage> _taps = _listenTaps();
  late final Stream<PushMessage> _received = _listenReceived();
  final StreamController<PushToken> _tokens = StreamController<PushToken>.broadcast();
  final StreamController<PushTokenRevoked> _revoked = StreamController<PushTokenRevoked>.broadcast();
  bool _observing = false;

  // Once, from both `tokens` and `revocations`: an app with only onTokenRevoked must hear a revocation too.
  void _observe() {
    if (_observing) return;
    _observing = true;
    OneSignal.User.pushSubscription.addObserver((changes) {
      final now = _tokenOf(changes.current);
      if (now != null) {
        _tokens.add(now);
      } else if (_tokenOf(changes.previous) case final before?) {
        _revoked.add(PushTokenRevoked(kind: before.kind, properties: before.properties));
      }
    });
  }

  Stream<PushMessage> _listenTaps() {
    final controller = StreamController<PushMessage>.broadcast();
    OneSignal.Notifications.addClickListener((event) => controller.add(_message(event.notification)));
    return controller.stream;
  }

  Stream<PushMessage> _listenReceived() {
    final controller = StreamController<PushMessage>.broadcast();
    OneSignal.Notifications.addForegroundWillDisplayListener(
      (event) => controller.add(_message(event.notification)),
    );
    return controller.stream;
  }

  /// A cold-start tap is delivered on [taps]: OneSignal buffers it until the first listener.
  @override
  PushMessage? initialTap() => null;

  @override
  Stream<PushMessage> get taps => _taps;

  @override
  Stream<PushMessage> get received => _received;

  @override
  Stream<PushToken> get tokens async* {
    _observe();
    final subscription = OneSignal.User.pushSubscription;
    final token = subscription.token;
    if (token != null && (subscription.optedIn ?? false)) {
      yield PushToken(
        kind: PushTokenKind.onesignal,
        value: token,
        properties: {if (subscription.id != null) 'subscription_id': subscription.id!},
      );
    }
    yield* _tokens.stream;
  }

  @override
  Stream<PushTokenRevoked> get revocations {
    _observe();
    return _revoked.stream;
  }

  @override
  Future<PushPermission> permission() async => switch (await OneSignal.Notifications.permissionNative()) {
    OSNotificationPermission.authorized => PushPermission.granted,
    OSNotificationPermission.provisional || OSNotificationPermission.ephemeral => PushPermission.provisional,
    OSNotificationPermission.notDetermined => PushPermission.notDetermined,
    OSNotificationPermission.denied => PushPermission.denied,
  };

  @override
  Future<PushPermission> requestPermission() async {
    await OneSignal.Notifications.requestPermission(false);
    return permission();
  }
}
```

## JPush (`jpush_flutter`)

`kind: PushTokenKind.jpush`, `value`: the **registration id** JPush assigns (`getRegistrationID()`; it is JPush's own id, not
an APNs or vendor token, and an empty string before the SDK has connected), no `properties` needed. It arrives after `onConnected`.
Two traps of the plugin (3.5.8): `addEventHandler` stores each handler and the plugin calls it with `!`, so **an event
whose handler you left out throws a null-check error when it arrives**, and the native side sends `onReceiveDeviceToken`,
`onReceiveNotificationAuthorization`, `onCommandResult` and `onNotifyMessageUnShow` besides the obvious ones: pass a handler for every
parameter of `addEventHandler`, a no-op for those the app ignores. And `JPush.newJPush()` makes a new object: keep one. There is no invalidation callback; `stopPush()` is the
app's own, and the recipe reports a revocation then.

```dart
// lib/push/jpush_tokens.dart
import 'dart:async';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:jpush_flutter/jpush_flutter.dart';

import 'with_tokens.dart';

/// JPush registration ids as tokens.
final class JPushTokens implements TokenFeed {
  JPushTokens({required String appKey, bool production = true}) : _production = production, _appKey = appKey;

  final String _appKey;
  final bool _production;
  final _jpush = JPush.newJPush();
  final StreamController<PushToken> _tokens = StreamController<PushToken>.broadcast();
  final StreamController<PushTokenRevoked> _revoked = StreamController<PushTokenRevoked>.broadcast();
  PushToken? _current;
  bool _started = false;

  Future<void> _publish() async {
    final id = await _jpush.getRegistrationID();
    if (id.isEmpty) return;
    final token = PushToken(kind: PushTokenKind.jpush, value: id);
    _current = token;
    _tokens.add(token);
  }

  /// Starts the SDK; call once, at a moment the person has accepted notifications.
  void start() {
    if (_started) return;
    _started = true;
    _jpush.addEventHandler(
      onConnected: (event) async => _publish(),
      // The plugin calls every handler with `!`, and the native side sends all of these: pass one for each
      // parameter, a no-op for those the app ignores.
      onReceiveNotification: (event) async {},
      onOpenNotification: (event) async {},
      onReceiveMessage: (event) async {},
      onReceiveNotificationAuthorization: (event) async {},
      onNotifyMessageUnShow: (event) async {},
      onInAppMessageClick: (event) async {},
      onInAppMessageShow: (event) async {},
      onNotifyButtonClick: (event) async {},
      onCommandResult: (event) async {},
      onReceiveDeviceToken: (event) async {},
      onVoipMessage: (event) async {},
    );
    _jpush.setup(appKey: _appKey, production: _production);
  }

  @override
  Stream<PushToken> get tokens async* {
    final current = _current;
    if (current != null) yield current;
    yield* _tokens.stream;
  }

  @override
  Stream<PushTokenRevoked> get revocations => _revoked.stream;

  /// Stops the push (the app's sign-out), then reports the revocation.
  Future<void> stop() async {
    await _jpush.stopPush();
    _current = null;
    _revoked.add(PushTokenRevoked(kind: PushTokenKind.jpush));
  }
}
```

## Xiaomi, OPPO, vivo, Honor (and Huawei, Meizu): `flutter_mix_push`

One plugin for the Chinese Android vendor channels (and APNs on iOS), derived from MixPush: `kind` follows the vendor that
issued the id (`mi` is `PushTokenKind.mipush`, `huawei` is `hms`, `honor`, `oppo`, `vivo` and `apns` are the same-named constants,
and `meizu`, which has no constant, stays the string `meizu`), `value`: the vendor's `regId`. **`flutter_mix_push` 1.0.0 needs
Flutter 3.44 and Dart 3.12.1**, above fespalier's own floor (3.32): it is the app's floor if it uses it. This repository's
pinned Flutter (3.47.5) builds it, and this recipe is compiled by `just skill-samples` with it; on an older Flutter, `pub get`
fails and the recipe is prose only. The vendor keys are Gradle manifest placeholders (`MI_APP_ID`, `OPPO_APP_KEY`, ...: the
plugin's README), and a vendor without one is skipped. The plugin reports **no revocation** (no unregister event), so
`revocations` is empty. It has no read-only permission query, so `permission()` answers `notDetermined` until
`requestPermission()` ran (that is the app's moment to call it). **Call `MixPushSource.start()` once at launch** (it is `FlutterMixPush.register()`; the source does not do it from `tokens`, which an app with no token callback never listens to), within 60 seconds of the first listen of `tokens` or followed by `refresh()`: the native `getRegisterId` polls for up to 60 seconds, then answers null.

**Three trade-offs of the plugin's design (1.0.0).** `onRegisterSucceed`, `onMessage` and `onNotificationClicked` each open their own listener on one EventChannel, and a second listener replaces the first one's handler, so only one of them can be used. The recipe keeps `onNotificationClicked`, for `taps`. So: there is **no foreground `received`** (it stays at the default, none); **a changed `regId` is not pushed**, so the app calls `refresh()` (on resume, for example) to read it again; and the app must **not listen to `FlutterMixPush.onMessage` or `onRegisterSucceed` anywhere else**, or taps stop arriving. The alternative is one `EventChannel('flutter_mix_push/events').receiveBroadcastStream()` of the app's own, split by `event['type']` (`notificationClicked`, `messageArrived`, `registerSucceed`): it recovers all three event kinds, at the cost of depending on the plugin's private channel name. The payload is the vendor message's `payload` string, JSON by
convention: the source decodes it into `PushMessage.data`.

```dart
// lib/push/mix_push_source.dart
import 'dart:async';
import 'dart:convert';

import 'package:fespalier_push/fespalier_push.dart';
import 'package:flutter_mix_push/flutter_mix_push.dart';

import 'with_tokens.dart';

PushMessage _message(MixPushMessage message) {
  var data = const <String, Object?>{};
  final payload = message.payload;
  if (payload != null) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?>) data = decoded;
    } on FormatException {
      data = const {};
    }
  }
  return PushMessage(data: data, raw: message);
}

PushToken _token(MixPushPlatformInfo info) => PushToken(
  kind: switch (info.platform) {
    'mi' => PushTokenKind.mipush,
    'huawei' => PushTokenKind.hms,
    'honor' => PushTokenKind.honor,
    'oppo' => PushTokenKind.oppo,
    'vivo' => PushTokenKind.vivo,
    'apns' => PushTokenKind.apns,
    final other => other, // 'meizu'
  },
  value: info.regId,
);

/// flutter_mix_push as a [PushSource].
final class MixPushSource extends PushSource {
  MixPushSource();

  PushPermission _permission = PushPermission.notDetermined;

  @override
  Future<PushMessage?> initialTap() async {
    final message = await FlutterMixPush.getLaunchMessage();
    return message == null ? null : _message(message);
  }

  @override
  Stream<PushMessage> get taps => FlutterMixPush.onNotificationClicked.map(_message);

  // `received` is left at the default and `tokens` reads the id with a method call, on purpose: see the trade-offs above.
  late final SharedTokens _tokens = SharedTokens(onFirstListen: () => unawaited(refresh()));

  @override
  Stream<PushToken> get tokens => _tokens.stream;

  /// Registers with the vendor channels. **Call it once, at launch**: `tokens` only reads the id, so an app that never
  /// calls it gets no push. Call it within 60 seconds of the first listen of `tokens`, or call [refresh] after it: the native
  /// `getRegisterId` polls for up to 60 seconds, then answers null.
  Future<void> start() => FlutterMixPush.register();

  /// Reads the registration id (a method call, up to 60 seconds) and delivers it to `tokens`. `onToken` drops an equal
  /// repeat through the adapter's per-kind dedupe, and the `pushToken` provider through Riverpod's state equality.
  Future<void> refresh() async {
    try {
      final info = await FlutterMixPush.getRegisterId();
      if (info != null) _tokens.add(_token(info));
    } on Object catch (error, stack) {
      _tokens.addError(error, stack);
    }
  }

  @override
  Future<PushPermission> permission() async => _permission;

  @override
  Future<PushPermission> requestPermission() async {
    final granted = await FlutterMixPush.requestPermission();
    return _permission = granted ? PushPermission.granted : PushPermission.denied;
  }
}
```
