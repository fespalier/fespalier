import 'package:fespalier/fespalier.dart';

import 'message.dart';
import 'permission.dart';
import 'source.dart';
import 'token.dart';

/// The app's push provider. The adapter's `overrides()` binds it to the one handed to
/// `FespalierPush.configure`; a test overrides it with `pushTestOverrides`.
final pushSource = Provider<PushSource>(
  (ref) => throw StateError(
    'pushSource: no PushSource. Call FespalierPush.configure(...) in main() before '
    'AppMain.run(), or override pushSource in a test (pushTestOverrides).',
  ),
);

/// The current token, then each refresh, for an app that prefers Riverpod to `onToken`. A
/// [PushToken] since 0.14.0 (it was a `String`).
///
/// This is state, not an event log: it holds the last value (it keeps answering a token that was
/// revoked), and an equal repeat does not notify. For every event, including the same token
/// again after a revocation, use `onToken`.
final pushToken = StreamProvider<PushToken>(
  (ref) => ref.watch(pushSource).tokens,
  retry: (_, _) => null,
);

/// A token that stopped being valid (since 0.14.0), for an app that prefers Riverpod to
/// `onTokenRevoked`. Not a null [pushToken]: it is an event of its own.
///
/// As state it holds the last revocation, and an equal repeat does not notify: use `onTokenRevoked`
/// to hear every one.
final pushTokenRevoked = StreamProvider<PushTokenRevoked>(
  (ref) => ref.watch(pushSource).revocations,
  retry: (_, _) => null,
);

/// Messages delivered while the app is in the foreground. Nothing is shown for them.
final pushReceived = StreamProvider<PushMessage>(
  (ref) => ref.watch(pushSource).received,
  retry: (_, _) => null,
);

/// The notification permission as the platform reports it now. It never asks.
final pushPermission = FutureProvider.autoDispose<PushPermission>(
  (ref) => ref.watch(pushSource).permission(),
);

/// Shows the platform's own prompt (the app decides when), then refreshes [pushPermission].
Future<PushPermission> requestPushPermission(Ref ref) async {
  final answer = await ref.read(pushSource).requestPermission();
  if (ref.mounted) ref.invalidate(pushPermission);
  return answer;
}
