// `FespalierTelemetry.within` on a single installed sink (since 0.9.0): what fespalier hands the
// sink, what it guarantees whatever the sink does, and what comes back. A file of its own because
// a sink's error is printed once per isolate, and this file asserts the one line.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sink that runs the body the way a test tells it to.
final class Hook extends FespalierTelemetry {
  Hook(this.hook);

  final void Function(Object? token, Object? Function() body) hook;

  @override
  Object? start(TelemetryStart start) => 'token';

  @override
  void within(Object? token, Object? Function() body) =>
      hook(token, () => body());
}

List<String> printed(void Function() body) {
  final lines = <String>[];
  final old = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add('$message');
  try {
    body();
  } finally {
    debugPrint = old;
  }
  return lines;
}

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  Object? begin() =>
      FespalierTelemetry.begin(const TelemetryStart(TelemetryOp.data));

  test('the sink is handed the body, with its own token', () {
    Object? gotToken;
    FespalierTelemetry.install(
      Hook((token, body) {
        gotToken = token;
        body();
      }),
    );
    expect(FespalierTelemetry.run(begin(), () => 1), 1);
    expect(gotToken, 'token');
  });

  test('what comes back is the very object, a value or a Future', () {
    FespalierTelemetry.install(Hook((token, body) => body()));
    final value = Object();
    expect(
      identical(FespalierTelemetry.run(begin(), () => value), value),
      isTrue,
    );
    final future = Future<int>.value(1);
    expect(
      identical(FespalierTelemetry.run(begin(), () => future), future),
      isTrue,
    );
    final stream = const Stream<int>.empty();
    expect(
      identical(FespalierTelemetry.run(begin(), () => stream), stream),
      isTrue,
    );
  });

  test('the body runs once, synchronously, before within returns', () {
    var runs = 0;
    var returned = false;
    FespalierTelemetry.install(
      Hook((token, body) {
        body();
        expect(runs, 1);
        returned = true;
      }),
    );
    FespalierTelemetry.run(begin(), () => ++runs);
    expect(returned, isTrue);
    expect(runs, 1);
  });

  test('a sink that calls the body twice, or later, does not run it again', () {
    final later = <Object? Function()>[];
    FespalierTelemetry.install(
      Hook((token, body) {
        final first = body();
        expect(identical(body(), first), isTrue);
        later.add(body);
        scheduleMicrotask(() => body());
      }),
    );
    var runs = 0;
    expect(FespalierTelemetry.run(begin(), () => ++runs), 1);
    expect(later.single(), 1);
    expect(runs, 1);
  });

  test('a sink that never calls the body: it runs after within returned', () {
    final order = <String>[];
    FespalierTelemetry.install(Hook((token, body) => order.add('within')));
    FespalierTelemetry.run(begin(), () => order.add('body'));
    expect(order, ['within', 'body']);
  });

  test('an exception comes back as it was, and the sink saw null', () {
    Object? seen = 'untouched';
    FespalierTelemetry.install(Hook((token, body) => seen = body()));
    final error = ArgumentError('no');
    Object? caught;
    StackTrace? where;
    try {
      FespalierTelemetry.run<void>(begin(), () => _failing(error));
    } catch (e, s) {
      caught = e;
      where = s;
    }
    expect(identical(caught, error), isTrue);
    expect(where.toString(), contains('_failing'));
    expect(seen, isNull);
  });

  test(
    'a sink that throws from within is printed once, and the body runs once',
    () {
      FespalierTelemetry.install(
        Hook((token, body) => throw StateError('within')),
      );
      var runs = 0;
      final lines = printed(() {
        expect(FespalierTelemetry.run(begin(), () => ++runs), 1);
        expect(FespalierTelemetry.run(begin(), () => ++runs), 2);
      });
      expect(runs, 2);
      expect(lines, [
        'fespalier telemetry: Bad state: within (not shown again)',
      ]);
    },
  );

  test('one that throws after calling the body does not run it again', () {
    FespalierTelemetry.install(
      Hook((token, body) {
        body();
        throw StateError('after');
      }),
    );
    var runs = 0;
    printed(() => expect(FespalierTelemetry.run(begin(), () => ++runs), 1));
    expect(runs, 1);
  });

  test('a sync body schedules no microtask and no timer of ours', () {
    FespalierTelemetry.install(Hook((token, body) => body()));
    fakeAsync((async) {
      expect(FespalierTelemetry.run(begin(), () => 1), 1);
      expect(async.microtaskCount, 0);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('with no token, or no sink, the body is just called', () {
    var hookCalls = 0;
    FespalierTelemetry.install(
      Hook((token, body) {
        hookCalls++;
        body();
      }),
    );
    expect(FespalierTelemetry.run(null, () => 2), 2);
    expect(hookCalls, 0);
    FespalierTelemetry.install(null);
    expect(FespalierTelemetry.run('token', () => 3), 3);
    expect(hookCalls, 0);
  });

  test('a sink that does not override within gets the default: the call', () {
    // `RecordingTelemetry` without recordWithin is a sink that does not care.
    FespalierTelemetry.install(_Plain());
    expect(FespalierTelemetry.run(begin(), () => 'x'), 'x');
  });

  test('a zone of values is current for what the body awaits', () async {
    const key = #withinTest;
    FespalierTelemetry.install(
      Hook((token, body) => runZoned(() => body(), zoneValues: {key: 'span'})),
    );
    final seen = FespalierTelemetry.run(begin(), () async {
      await Future<void>.delayed(Duration.zero);
      return Zone.current[key];
    });
    expect(await seen, 'span');
    expect(Zone.current[key], isNull);
  });
}

Object _failing(Object error) => throw error;

final class _Plain extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => 'plain';
}
