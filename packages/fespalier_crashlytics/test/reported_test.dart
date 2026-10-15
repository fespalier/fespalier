// `reported(error)`: the answer the app's own handlers use to skip an error the sink already saw, so
// that one error is reported once. Compared by identity, over the last 32 errors, whatever the sink
// did with each one.
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Fails a custom operation with [error]: the sink logs it by class and does not report it.
void failCustom(Object error) {
  final token = FespalierTelemetry.begin(
    const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
  );
  FespalierTelemetry.finish(
    token,
    TelemetryEnd(TelemetryOutcome.error, isAsync: true, error: error),
  );
}

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('is true for a reported error, a repeat and a logged FieldErrors, and '
      'false for an unrelated object', () {
    final rig = Rig();
    final reported = StateError('reported');
    final token = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.data, site: dataSite),
    );
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(TelemetryOutcome.error, isAsync: true, error: reported),
    );
    expect(rig.crash.errors, hasLength(1));
    expect(rig.sink.reported(reported), isTrue);

    // The same operation, inside the repeat window: a log line, and still reported.
    final repeat = StateError('a repeat');
    final again = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.data, site: dataSite),
    );
    FespalierTelemetry.finish(
      again,
      TelemetryEnd(TelemetryOutcome.error, isAsync: true, error: repeat),
    );
    expect(rig.crash.errors, hasLength(1));
    expect(rig.sink.reported(repeat), isTrue);

    // A validation answer: logged by class, and reported as seen.
    final fields = FieldErrors({'name': 'taken'});
    final rejected = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.action, site: actionSite),
    );
    FespalierTelemetry.finish(
      rejected,
      TelemetryEnd(TelemetryOutcome.error, isAsync: true, error: fields),
    );
    expect(rig.crash.logs, contains('action items/\$id/action.dart rejected'));
    expect(rig.sink.reported(fields), isTrue);

    expect(rig.sink.reported(StateError('never seen')), isFalse);
    expect(rig.sink.reported(Object()), isFalse);
  });

  test('keeps the last 32: the 33rd error pushes the first out', () {
    final rig = Rig();
    final errors = [for (var i = 0; i < 33; i++) StateError('$i')];
    for (final error in errors) {
      failCustom(error);
    }
    expect(rig.sink.reported(errors.first), isFalse);
    expect(rig.sink.reported(errors[1]), isTrue);
    expect(rig.sink.reported(errors.last), isTrue);
  });

  test('is true even with logs: false, which writes no log', () {
    final rig = Rig(logs: false);
    final fields = FieldErrors({'name': 'taken'});
    final token = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.action, site: actionSite),
    );
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(TelemetryOutcome.error, isAsync: true, error: fields),
    );
    expect(rig.sink.reported(fields), isTrue);
    expect(rig.crash.logs, isEmpty);
    expect(rig.crash.errors, isEmpty);
  });
}
