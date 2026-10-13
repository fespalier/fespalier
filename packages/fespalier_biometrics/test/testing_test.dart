import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'an outcome released before authenticate runs is the one it answers',
    () async {
      final prompt = FakeBiometricPrompt()..hold();
      prompt.release(BiometricOutcome.cancelled);
      expect(await prompt.authenticate('r'), BiometricOutcome.cancelled);
      // The hold is used up: the next prompt answers from the queue.
      expect(await prompt.authenticate('r'), BiometricOutcome.success);
    },
  );

  test('hold, then release after authenticate started', () async {
    final prompt = FakeBiometricPrompt()..hold();
    final answer = prompt.authenticate('r');
    prompt.release(BiometricOutcome.lockedOut);
    expect(await answer, BiometricOutcome.lockedOut);
  });
}
