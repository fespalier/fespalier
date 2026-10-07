import 'package:fespalier/fespalier.dart';

import 'message.dart';
import 'permission.dart';
import 'source.dart';

/// The app's push provider. The adapter's `overrides()` binds it to the one handed to
/// `FespalierPush.configure`; a test overrides it with `pushTestOverrides`.
final pushSource = Provider<PushSource>(
  (ref) => throw StateError(
    'pushSource: no PushSource. Call FespalierPush.configure(...) in main() before '
    'AppMain.run(), or override pushSource in a test (pushTestOverrides).',
  ),
);

/// The current token, then each refresh, for an app that prefers Riverpod to `onToken`.
final pushToken = StreamProvider<String>(
  (ref) => ref.watch(pushSource).tokens,
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
