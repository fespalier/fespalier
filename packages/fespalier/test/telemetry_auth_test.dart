// What an adapter package (fespalier_auth, since 0.9.0) reports through `FespalierTelemetry.begin`
// and `finish`: the same sink and the same guarantees as fespalier's own call sites. A separate
// file, because the sink's "printed once" is per isolate.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('with no sink, begin returns null and finish does nothing', () {
    FespalierTelemetry.install(null);
    final token = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.auth, authStep: 'restore'),
    );
    expect(token, isNull);
    FespalierTelemetry.finish(token, const TelemetryEnd(TelemetryOutcome.none));
  });

  test('a sink is told the start, and gets its own token back', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.auth,
        authStep: 'refresh',
        authBackend: 'oidc',
        authTrigger: 'unauthorized',
        authDpop: true,
      ),
    );
    FespalierTelemetry.finish(
      token,
      const TelemetryEnd(TelemetryOutcome.ok, isAsync: true),
    );
    expect(rec.log, [
      '#1 start auth refresh backend=oidc trigger=unauthorized dpop',
      '#1 end auth ok async',
    ]);
  });

  test('the recording sink writes a line for each step, and each outcome', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    for (final (step, outcome) in const [
      ('restore', TelemetryOutcome.none),
      ('restore', TelemetryOutcome.expired),
      ('sign_in', TelemetryOutcome.cancelled),
      ('sign_in', TelemetryOutcome.rejected),
      ('sign_out', TelemetryOutcome.ok),
    ]) {
      final token = FespalierTelemetry.begin(
        TelemetryStart(TelemetryOp.auth, authStep: step, authBackend: 'fake'),
      );
      FespalierTelemetry.finish(token, TelemetryEnd(outcome));
    }
    expect(rec.log, [
      '#1 start auth restore backend=fake',
      '#1 end auth none',
      '#2 start auth restore backend=fake',
      '#2 end auth expired',
      '#3 start auth sign_in backend=fake',
      '#3 end auth cancelled',
      '#4 start auth sign_in backend=fake',
      '#4 end auth rejected',
      '#5 start auth sign_out backend=fake',
      '#5 end auth ok',
    ]);
  });

  test('a sink that throws is caught and printed once', () {
    FespalierTelemetry.install(_Throwing());
    final printed = <String>[];
    final old = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
    try {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.auth, authStep: 'sign_in'),
      );
      expect(token, isNull);
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(TelemetryOutcome.error),
      );
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(TelemetryOutcome.error),
      );
    } finally {
      debugPrint = old;
    }
    expect(printed, ['fespalier telemetry: Bad state: sink (not shown again)']);
  });

  test('the outcome strings are the contract values', () {
    expect(TelemetryOutcome.none, 'none');
    expect(TelemetryOutcome.expired, 'expired');
    expect(TelemetryOutcome.rejected, 'rejected');
    expect(TelemetryOutcome.cancelled, 'cancelled');
  });
}

final class _Throwing extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('sink');

  @override
  void end(Object? token, TelemetryEnd end) => throw StateError('sink');
}
