// A package's own operation (since 0.11.0): `TelemetryOp.custom` through
// `FespalierTelemetry.begin` and `finish`, the debug checks and the recording sink's lines.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('the recording sink writes the name and the sorted attributes', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.custom,
        name: 'fespalier.push.open',
        attributes: {'fespalier.push.b': true, 'fespalier.push.a': 'x'},
      ),
    );
    FespalierTelemetry.finish(
      token,
      const TelemetryEnd(
        TelemetryOutcome.ok,
        attributes: {'fespalier.push.n': 2},
      ),
    );
    expect(rec.log, [
      '#1 start custom fespalier.push.open '
          'fespalier.push.a=x fespalier.push.b=true',
      '#1 end custom ok fespalier.push.n=2',
    ]);
  });

  test('begin and finish go through combine to every sink', () {
    final a = RecordingTelemetry();
    final b = RecordingTelemetry();
    FespalierTelemetry.install(FespalierTelemetry.combine([a, b]));
    final token = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
    );
    FespalierTelemetry.finish(token, const TelemetryEnd(TelemetryOutcome.ok));
    for (final rec in [a, b]) {
      expect(rec.log, [
        '#1 start custom fespalier.push.open',
        '#1 end custom ok',
      ]);
    }
  });

  group('debug asserts', () {
    Matcher throwsAssertion(String text) => throwsA(
      isA<AssertionError>().having(
        (e) => '${e.message}',
        'message',
        contains(text),
      ),
    );

    test('a custom start needs a well-formed name', () {
      FespalierTelemetry.install(RecordingTelemetry());
      for (final name in [
        null,
        'push.open',
        'fespalier.push',
        'fespalier.Push.open',
      ]) {
        expect(
          () => FespalierTelemetry.begin(
            TelemetryStart(TelemetryOp.custom, name: name),
          ),
          throwsAssertion('needs a name'),
        );
      }
    });

    test("an attribute key starts with the name's package prefix", () {
      expect(
        () => FespalierTelemetry.begin(
          const TelemetryStart(
            TelemetryOp.custom,
            name: 'fespalier.push.open',
            attributes: {'fespalier.auth.x': 1},
          ),
        ),
        throwsAssertion('must start with "fespalier.push."'),
      );
    });

    test('an attribute value is a String, int, double or bool', () {
      expect(
        () => FespalierTelemetry.begin(
          const TelemetryStart(
            TelemetryOp.custom,
            name: 'fespalier.push.open',
            attributes: {
              'fespalier.push.x': <int>[1],
            },
          ),
        ),
        throwsAssertion('must be a String, int, double or bool'),
      );
    });
  });
}
