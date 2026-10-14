// The package's providers answer once and keep what the source says, error included. A source
// that throws is an AsyncError the app reads, not a reason to ask again: Riverpod 3's default retry
// would re-ask a plugin up to ten times (about 50 seconds) with a Timer, which fespalier_push never
// starts.
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A source whose plugin throws an `Exception`, the way a `PlatformException` does, and counts
/// how many times it was asked.
final class _Throwing extends FakePushSource {
  int asked = 0;

  @override
  Future<PushPermission> permission() async {
    asked++;
    throw Exception('the plugin is gone');
  }
}

void main() {
  test('pushPermission answers what the source says', () async {
    final source = FakePushSource(permissionAnswer: PushPermission.denied);
    final container = ProviderContainer(overrides: pushTestOverrides(source));
    addTearDown(container.dispose);
    expect(await container.read(pushPermission.future), PushPermission.denied);
    expect(source.permissionRequests, 0);
  });

  test('a source whose permission() throws is asked once, with no timer', () {
    fakeAsync((async) {
      final source = _Throwing();
      final container = ProviderContainer(overrides: pushTestOverrides(source));
      final held = container.listen(pushPermission, (_, _) {});
      async.flushMicrotasks();

      expect(container.read(pushPermission), isA<AsyncError<PushPermission>>());
      expect(async.pendingTimers, isEmpty);
      // Riverpod's default would ask again after 200 ms, 400 ms, 800 ms...
      async.elapse(const Duration(minutes: 2));
      expect(source.asked, 1);
      expect(async.pendingTimers, isEmpty);

      held.close();
      container.dispose();
    });
  });

  test('a stream that fails is an error, listened to once, with no timer', () {
    fakeAsync((async) {
      final source = FakePushSource();
      final container = ProviderContainer(overrides: pushTestOverrides(source));
      final held = [
        container.listen(pushToken, (_, _) {}),
        container.listen(pushTokenRevoked, (_, _) {}),
        container.listen(pushReceived, (_, _) {}),
      ];
      async.flushMicrotasks();
      source
        ..tokenError(StateError('token plugin'))
        ..tapError(StateError('tap plugin'));
      async.flushMicrotasks();

      expect(container.read(pushToken), isA<AsyncError<PushToken>>());
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(minutes: 2));
      expect(async.pendingTimers, isEmpty);

      for (final h in held) {
        h.close();
      }
      container.dispose();
    });
  });
}
