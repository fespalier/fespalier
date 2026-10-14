// biometricAvailable asks the plugin once. A plugin that throws is an AsyncError the unlock page
// reads, not a reason to ask again: Riverpod 3's default retry would re-ask it up to ten times (about
// 50 seconds) with a Timer, which fespalier_biometrics never starts.
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A prompt whose plugin throws an `Exception`, the way a `PlatformException` from local_auth does,
/// and counts how many times it was asked.
final class _ThrowingPrompt extends BiometricPrompt {
  int asked = 0;

  @override
  Future<bool> isAvailable() async {
    asked++;
    throw Exception('the plugin is gone');
  }

  @override
  Future<BiometricOutcome> authenticate(String reason) async =>
      BiometricOutcome.failed;
}

void main() {
  test('it answers what the prompt answers', () async {
    final prompt = FakeBiometricPrompt(available: false);
    final container = ProviderContainer(
      overrides: biometricTestOverrides(prompt),
    );
    addTearDown(container.dispose);
    expect(await container.read(biometricAvailable.future), isFalse);
    prompt.available = true;
    container.invalidate(biometricAvailable);
    expect(await container.read(biometricAvailable.future), isTrue);
  });

  test('a plugin that throws is an error, asked once, with no timer', () {
    fakeAsync((async) {
      final prompt = _ThrowingPrompt();
      final container = ProviderContainer(
        overrides: [biometricPrompt.overrideWithValue(prompt)],
      );
      final held = container.listen(biometricAvailable, (_, _) {});
      async.flushMicrotasks();

      expect(container.read(biometricAvailable), isA<AsyncError<bool>>());
      expect(async.pendingTimers, isEmpty);
      // Riverpod's default would ask again after 200 ms, 400 ms, 800 ms...
      async.elapse(const Duration(minutes: 2));
      expect(prompt.asked, 1);
      expect(async.pendingTimers, isEmpty);

      held.close();
      container.dispose();
    });
  });
}
