// `FespalierTelemetry.traceOf` and `linkTrace` (since 0.9.0): the sink that makes OpenTelemetry
// spans tells the other sinks of a `combine` which trace an operation is in, so Sentry can tag
// an event with it. Each sink only ever sees its own tokens.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite site = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);

const TelemetryTrace known = TelemetryTrace(
  '0af7651916cd43dd8448eb211c80319c',
  'b7ad6b7169203331',
);

/// A sink like OpenTelemetry's: every operation is in a trace of its own, found from its token.
final class Tracer extends FespalierTelemetry {
  Tracer(this.log, {this.throwing = false});

  final List<String> log;
  final bool throwing;
  int _n = 0;

  @override
  Object? start(TelemetryStart start) => 'tracer:${++_n}';

  @override
  TelemetryTrace? traceOf(Object? token) {
    log.add('tracer traceOf $token');
    if (throwing) throw StateError('no tracer');
    return known;
  }

  @override
  void linkTrace(Object? token, TelemetryTrace trace) =>
      log.add('tracer linkTrace $token');
}

/// A sink like Sentry's: it keeps what it is told about each of its operations.
final class Linked extends FespalierTelemetry {
  Linked(this.log);

  final List<String> log;
  final Map<Object?, TelemetryTrace> traces = {};
  int _n = 0;

  @override
  Object? start(TelemetryStart start) => 'linked:${++_n}';

  @override
  void linkTrace(Object? token, TelemetryTrace trace) {
    log.add('linked linkTrace $token $trace');
    traces[token] = trace;
  }
}

/// A sink that returns no token: it has nothing to be told about.
final class Silent extends FespalierTelemetry {
  Silent(this.log);

  final List<String> log;

  @override
  void linkTrace(Object? token, TelemetryTrace trace) =>
      log.add('silent linkTrace $token');
}

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('a sink without a trace answers null, and linkTrace does nothing', () {
    const sink = _Plain();
    expect(sink.traceOf('token'), isNull);
    sink.linkTrace('token', known); // returns, throws nothing
  });

  test('a TelemetryTrace is a value', () {
    expect(const TelemetryTrace('a', 'b'), const TelemetryTrace('a', 'b'));
    expect(
      const TelemetryTrace('a', 'b'),
      isNot(const TelemetryTrace('a', 'c')),
    );
    expect(
      const TelemetryTrace('a', 'b').hashCode,
      const TelemetryTrace('a', 'b').hashCode,
    );
    expect(
      known.toString(),
      '0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331',
    );
  });

  test(
    'every other sink is told the trace of the sink that has one, with its own token',
    () {
      final log = <String>[];
      final linked = Linked(log);
      FespalierTelemetry.install(
        FespalierTelemetry.combine([linked, Tracer(log), Silent(log)]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: site),
      );
      expect(token, isNotNull);
      // The tracer is asked about its own token and tells the Linked sink under the Linked sink's
      // own: no sink sees another's token, and the one without a token hears nothing.
      expect(log, [
        'tracer traceOf tracer:1',
        'linked linkTrace linked:1 $known',
      ]);
      expect(linked.traces, {'linked:1': known});
    },
  );

  test('it is the same whichever order the sinks are listed in', () {
    final log = <String>[];
    FespalierTelemetry.install(
      FespalierTelemetry.combine([Tracer(log), Linked(log)]),
    );
    FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.guard, site: site),
    );
    expect(log, [
      'tracer traceOf tracer:1',
      'linked linkTrace linked:1 $known',
    ]);
  });

  test('one question and one answer per operation', () {
    final log = <String>[];
    FespalierTelemetry.install(
      FespalierTelemetry.combine([Tracer(log), Linked(log)]),
    );
    final token = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.data, site: site),
    );
    FespalierTelemetry.finish(token, const TelemetryEnd(TelemetryOutcome.data));
    expect(log, hasLength(2));
  });

  test('without a sink that has a trace, nobody is told anything', () {
    final log = <String>[];
    FespalierTelemetry.install(
      FespalierTelemetry.combine([Linked(log), Linked(log)]),
    );
    FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.data, site: site),
    );
    expect(log, isEmpty);
  });

  test(
    'a sink that throws from traceOf is isolated, and the next sink is asked',
    () {
      final log = <String>[];
      final lines = <String?>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message);
      addTearDown(() => debugPrint = original);
      final linked = Linked(log);
      FespalierTelemetry.install(
        FespalierTelemetry.combine([
          Tracer(log, throwing: true),
          Tracer(log),
          linked,
        ]),
      );
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: site),
      );
      expect(token, isNotNull);
      expect(linked.traces, {'linked:1': known});
      expect(lines.single, contains('no tracer in Tracer (not shown again)'));
    },
  );

  test('a sink that throws from linkTrace costs nothing to the others', () {
    final log = <String>[];
    final linked = Linked(log);
    FespalierTelemetry.install(
      FespalierTelemetry.combine([Tracer(log), _Throws(), linked]),
    );
    expect(
      FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: site),
      ),
      isNotNull,
    );
    expect(linked.traces, {'linked:1': known});
  });

  test('a single sink is not wrapped: it is asked nothing', () {
    final log = <String>[];
    FespalierTelemetry.install(FespalierTelemetry.combine([Tracer(log)]));
    FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.data, site: site),
    );
    expect(log, isEmpty);
  });
}

final class _Plain extends FespalierTelemetry {
  const _Plain();
}

final class _Throws extends FespalierTelemetry {
  int _n = 0;

  @override
  Object? start(TelemetryStart start) => 'throws:${++_n}';

  @override
  void linkTrace(Object? token, TelemetryTrace trace) =>
      throw StateError('no link');
}
