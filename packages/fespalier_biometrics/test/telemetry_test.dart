// The package's own telemetry contract: one custom operation, constants and enum names only.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RecordingTelemetry sink;

  setUp(() {
    sink = RecordingTelemetry();
    FespalierTelemetry.install(sink);
  });
  tearDown(() => FespalierTelemetry.install(null));

  ProviderContainer containerOf(BiometricPrompt prompt) {
    final container = ProviderContainer(
      overrides: [
        appShowSignal.overrideWith(RefetchSignal.new),
        biometricPrompt.overrideWithValue(prompt),
      ],
    );
    addTearDown(container.dispose);
    container.listen(biometricUnlock, (_, _) {});
    return container;
  }

  test('the names are the contract', () {
    expect(biometricPromptOp, 'fespalier.biometrics.prompt');
    expect(biometricResultAttribute, 'fespalier.biometrics.result');
  });

  test('a prompt is one span with the outcome, never the reason', () async {
    final container = containerOf(
      FakeBiometricPrompt(
        outcomes: [BiometricOutcome.success, BiometricOutcome.cancelled],
      ),
    );
    final notifier = container.read(biometricUnlock.notifier);
    await notifier.unlock('Pay 42 EUR to Alice');
    await notifier.unlock('Pay 42 EUR to Alice');
    expect(sink.log, [
      '#1 start custom fespalier.biometrics.prompt',
      '#1 end custom ok async fespalier.biometrics.result=success',
      '#2 start custom fespalier.biometrics.prompt',
      '#2 end custom cancelled async fespalier.biometrics.result=cancelled',
    ]);
    expect(sink.log.join(), isNot(contains('Alice')));
  });

  test('a guard run reports no prompt', () async {
    final container = containerOf(FakeBiometricPrompt());
    container.read(biometricUnlock);
    expect(sink.log, isEmpty);
  });

  test('a prompt that throws ends in error', () async {
    final container = containerOf(_Throws());
    await container.read(biometricUnlock.notifier).unlock('r');
    expect(sink.log.last, contains('end custom error'));
    expect(sink.log.last, contains('fespalier.biometrics.result=failed'));
  });
}

class _Throws extends BiometricPrompt {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<BiometricOutcome> authenticate(String reason) =>
      throw StateError('plugin crashed');
}
