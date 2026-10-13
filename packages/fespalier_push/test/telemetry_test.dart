import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the names are the package contract', () {
    expect(FespalierPushConventions.open, 'fespalier.push.open');
    expect(FespalierPushConventions.state, 'fespalier.push.state');
    expect(FespalierPushConventions.routed, 'fespalier.push.routed');
    expect(FespalierPushConventions.cold, 'cold');
    expect(FespalierPushConventions.warm, 'warm');
  });

  test('they pass fespalier\'s debug checks and read as a span', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.custom,
        name: FespalierPushConventions.open,
        attributes: {FespalierPushConventions.state: 'warm'},
      ),
    );
    FespalierTelemetry.finish(
      token,
      const TelemetryEnd(
        TelemetryOutcome.ok,
        attributes: {FespalierPushConventions.routed: true},
      ),
    );
    expect(rec.log, [
      '#1 start custom fespalier.push.open fespalier.push.state=warm',
      '#1 end custom ok fespalier.push.routed=true',
    ]);
  });
}
