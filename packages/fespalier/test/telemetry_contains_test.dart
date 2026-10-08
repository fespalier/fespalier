// FespalierTelemetry.contains (since 0.13.0): whether a sink is still in the slot, alone or inside
// a combine, so an adapter can tell that a later `install` dropped it.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('nothing installed contains nothing', () {
    expect(FespalierTelemetry.contains(RecordingTelemetry()), isFalse);
  });

  test('the installed sink, alone or combined, is contained', () {
    final a = RecordingTelemetry();
    final b = RecordingTelemetry();
    FespalierTelemetry.install(a);
    expect(FespalierTelemetry.contains(a), isTrue);
    expect(FespalierTelemetry.contains(b), isFalse);
    FespalierTelemetry.add(b);
    expect(FespalierTelemetry.contains(a), isTrue);
    expect(FespalierTelemetry.contains(b), isTrue);
  });

  test('install replaces the slot: the earlier sinks are gone', () {
    final a = RecordingTelemetry();
    final b = RecordingTelemetry();
    FespalierTelemetry.add(a);
    FespalierTelemetry.install(b);
    expect(FespalierTelemetry.contains(a), isFalse);
    expect(FespalierTelemetry.contains(b), isTrue);
    FespalierTelemetry.install(null);
    expect(FespalierTelemetry.contains(b), isFalse);
  });
}
