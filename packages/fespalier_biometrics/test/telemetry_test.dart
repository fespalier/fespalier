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
    expect(biometricSecretOp, 'fespalier.biometrics.secret');
    expect(biometricSecretOpAttribute, 'fespalier.biometrics.secret_op');
  });

  test('a secret operation reports only constants', () async {
    const key = 'card-number-of-alice';
    const value = '4242-4242-secret';
    const reason = 'Show Alice\'s card';
    final secrets = FakeBiometricSecrets(
      stored: {key: value},
      outcomes: [
        BiometricOutcome.success,
        BiometricOutcome.success,
        BiometricOutcome.cancelled,
        BiometricOutcome.lockedOut,
      ],
    );
    final container = ProviderContainer(
      overrides: biometricTestOverrides(
        FakeBiometricPrompt(),
        secrets: secrets,
      ),
    );
    addTearDown(container.dispose);
    container.listen(biometricUnlock, (_, _) {});
    final notifier = container.read(biometricUnlock.notifier);
    await notifier.readSecret(key, reason); // found
    await notifier.readSecret('other', reason); // missing
    await notifier.readSecret(key, reason); // cancelled
    await notifier.writeSecret(key, value, reason); // lockedOut
    await notifier.writeSecret(key, value, reason); // success
    await notifier.deleteSecret(key);
    secrets.throws = StateError('PlatformException: no item $key $value');
    await notifier.readSecret(key, reason); // failed, a store that threw
    await notifier.writeSecret(key, value, reason);
    expect(sink.log, [
      '#1 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=read',
      '#1 end custom ok async fespalier.biometrics.result=found',
      '#2 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=read',
      '#2 end custom skipped async fespalier.biometrics.result=missing',
      '#3 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=read',
      '#3 end custom cancelled async fespalier.biometrics.result=cancelled',
      '#4 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=write',
      '#4 end custom rejected async fespalier.biometrics.result=lockedOut',
      '#5 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=write',
      '#5 end custom ok async fespalier.biometrics.result=success',
      '#6 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=delete',
      '#6 end custom ok async fespalier.biometrics.result=success',
      '#7 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=read',
      '#7 end custom error async fespalier.biometrics.result=failed',
      '#8 start custom fespalier.biometrics.secret fespalier.biometrics.secret_op=write',
      '#8 end custom error async fespalier.biometrics.result=failed',
    ]);
    final all = sink.log.join('\n');
    for (final leak in [key, value, reason, 'Alice', 'PlatformException']) {
      expect(all, isNot(contains(leak)));
    }
  });

  test('a secret end carries no error object', () async {
    final seen = <TelemetryEnd>[];
    FespalierTelemetry.install(_Ends(seen));
    final secrets = FakeBiometricSecrets()
      ..throws = StateError('names the key');
    final container = ProviderContainer(
      overrides: biometricTestOverrides(
        FakeBiometricPrompt(),
        secrets: secrets,
      ),
    );
    addTearDown(container.dispose);
    container.listen(biometricUnlock, (_, _) {});
    await container.read(biometricUnlock.notifier).readSecret('k', 'r');
    expect(seen, hasLength(1));
    expect(seen.single.outcome, TelemetryOutcome.error);
    expect(seen.single.error, isNull);
    expect(seen.single.stackTrace, isNull);
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

class _Ends extends FespalierTelemetry {
  _Ends(this.ends);

  final List<TelemetryEnd> ends;

  @override
  Object? start(TelemetryStart start) => Object();

  @override
  void end(Object? token, TelemetryEnd end) => ends.add(end);
}
