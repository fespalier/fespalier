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
      FespalierTelemetry.install(RecordingTelemetry());
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

    test("a package segment is not one of fespalier's own namespaces", () {
      FespalierTelemetry.install(RecordingTelemetry());
      for (final pkg in ['custom', 'image', 'auth', 'operation']) {
        expect(
          () => FespalierTelemetry.begin(
            TelemetryStart(TelemetryOp.custom, name: 'fespalier.$pkg.x'),
          ),
          throwsAssertion('own attribute namespaces'),
        );
      }
    });

    test('with no sink installed a bad start is not asserted', () {
      expect(
        FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.custom, name: 'bad'),
        ),
        isNull,
      );
    });

    test('an end attribute has a fespalier.<pkg>. key and a plain value', () {
      FespalierTelemetry.install(RecordingTelemetry());
      expect(
        () => FespalierTelemetry.finish(
          null,
          const TelemetryEnd(TelemetryOutcome.ok, attributes: {'x': 1}),
        ),
        throwsAssertion('must start with fespalier.<pkg>.'),
      );
      expect(
        () => FespalierTelemetry.finish(
          null,
          const TelemetryEnd(
            TelemetryOutcome.ok,
            attributes: {
              'fespalier.push.x': <int>[1],
            },
          ),
        ),
        throwsAssertion('must be a String, int, double or bool'),
      );
    });

    test('the recorder has no trailing space for empty end attributes', () {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
      );
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(TelemetryOutcome.ok, attributes: {}),
      );
      expect(rec.log.last, '#1 end custom ok');
    });

    test('an attribute value is a String, int, double or bool', () {
      FespalierTelemetry.install(RecordingTelemetry());
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
