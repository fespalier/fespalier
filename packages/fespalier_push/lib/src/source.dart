import 'dart:async';

import 'message.dart';
import 'permission.dart';
import 'token.dart';

/// What a push provider gives fespalier_push (since 0.13.0). One per app, handed over with
/// `FespalierPush.configure`; `package:fespalier_push/testing.dart` has `FakePushSource`. The
/// vendor classes (Firebase Messaging, a local-notifications plugin) are recipes in the
/// fespalier-routing skill, not dependencies of this package.
///
/// Implementations keep the rules of an adapter: nothing here may start a timer, and the reads
/// that run before the first frame ([initialTap]) are local ones, never the network.
abstract class PushSource {
  /// Constant, so a source with no state is `const`.
  const PushSource();

  /// The tap that cold-started the app, answered once (a second call answers null). A local read:
  /// it runs before the first frame, so a `Future` delays that frame by one channel round trip.
  FutureOr<PushMessage?> initialTap();

  /// Taps on a notification while the app runs or sits in the background. Listened to once per
  /// `ProviderScope`; make it a broadcast stream, so a tap that arrives before the subscription
  /// does not wait for it (and a rebuilt scope can listen again).
  Stream<PushMessage> get taps;

  /// Messages delivered while the app is in the foreground. Nothing is shown for them: it is
  /// `pushReceived`, for an app that updates a badge or its own list.
  Stream<PushMessage> get received => const Stream.empty();

  /// The current token, then each refresh (a [PushToken] since 0.14.0: it was a `String`).
  Stream<PushToken> get tokens;

  /// A token that stopped being valid (since 0.14.0): the vendor's unregister or invalidation
  /// callback. The default never revokes, so a source without one leaves it out. Make it a
  /// broadcast stream, like [taps].
  Stream<PushTokenRevoked> get revocations => const Stream.empty();

  /// What the user has answered so far. Never asks.
  Future<PushPermission> permission();

  /// The platform's own prompt. fespalier_push never calls it: the app decides when
  /// (`requestPushPermission`).
  Future<PushPermission> requestPermission();
}
