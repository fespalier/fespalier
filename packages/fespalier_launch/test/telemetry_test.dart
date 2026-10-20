import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the names are the package contract', () {
    expect(FespalierLaunchConventions.open, 'fespalier.launch.open');
    expect(FespalierLaunchConventions.state, 'fespalier.launch.state');
    expect(FespalierLaunchConventions.kind, 'fespalier.launch.kind');
    expect(FespalierLaunchConventions.routed, 'fespalier.launch.routed');
    expect(FespalierLaunchConventions.cold, 'cold');
    expect(FespalierLaunchConventions.warm, 'warm');
  });

  test('they pass fespalier\'s debug checks and read as a span', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.custom,
        name: FespalierLaunchConventions.open,
        attributes: {
          FespalierLaunchConventions.state: 'warm',
          FespalierLaunchConventions.kind: 'shortcut',
        },
      ),
    );
    FespalierTelemetry.finish(
      token,
      const TelemetryEnd(
        TelemetryOutcome.ok,
        attributes: {FespalierLaunchConventions.routed: true},
      ),
    );
    expect(rec.log, [
      '#1 start custom fespalier.launch.open fespalier.launch.kind=shortcut fespalier.launch.state=warm',
      '#1 end custom ok fespalier.launch.routed=true',
    ]);
  });
}
