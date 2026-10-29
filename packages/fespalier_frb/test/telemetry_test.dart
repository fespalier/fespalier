// The package's own telemetry contract: one custom operation, constants only.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Remembers what the zone it was started in held under `#probe`: a sink such as `FespalierOtel`
/// reads its parent span from `Zone.current` in the same way.
final class ZoneProbeTelemetry extends FespalierTelemetry {
  /// The `#probe` value seen at each `start`.
  final List<Object?> seen = [];

  @override
  Object? start(TelemetryStart start) {
    seen.add(Zone.current[#probe]);
    return null;
  }
}

void main() {
  late RecordingTelemetry sink;

  setUp(() {
    sink = RecordingTelemetry();
    FespalierTelemetry.install(sink);
  });
  tearDown(() => FespalierTelemetry.install(null));

  test('the names are the contract', () {
    expect(frbInitOp, 'fespalier.frb.init');
    expect(frbResultAttribute, 'fespalier.frb.result');
  });

  test('a successful init is one span ending ok', () async {
    var calls = 0;
    await initRustCore(() async => calls++);
    expect(calls, 1);
    expect(sink.log, [
      '#1 start custom fespalier.frb.init',
      '#1 end custom ok async fespalier.frb.result=ok',
    ]);
  });

  test(
    'a failing init ends in error, rethrows, and never reports the text',
    () async {
      await expectLater(
        initRustCore(
          () async => throw StateError('library libcore.so missing'),
        ),
        throwsStateError,
      );
      expect(sink.log.first, '#1 start custom fespalier.frb.init');
      expect(sink.log.last, startsWith('#1 end custom error async'));
      expect(sink.log.last, contains('fespalier.frb.result=error'));
      expect(sink.log.last, isNot(contains('error=')));
    },
  );

  test('an init that throws before its first await is the same', () async {
    await expectLater(
      initRustCore(() => throw StateError('sync')),
      throwsStateError,
    );
    expect(sink.log, hasLength(2));
  });

  test('without a sink it is init and nothing else', () async {
    FespalierTelemetry.install(null);
    var calls = 0;
    await initRustCore(() async => calls++);
    expect(calls, 1);
    expect(sink.log, isEmpty);
  });

  test('the decode names are the contract', () {
    expect(frbDecodeOp, 'fespalier.frb.decode');
    expect(frbSkippedAttribute, 'fespalier.frb.skipped');
  });

  test('a decoded event reports nothing', () {
    final codec = ChangeCodec<String, int>(int.parse);
    for (var i = 0; i < 3; i++) {
      expect(codec.decode('1'), [1]);
    }
    expect(sink.log, isEmpty);
  });

  test('a skip is one span of constants, never the message or the error', () {
    final codec = ChangeCodec<String, int>(
      (raw) => raw == 'new' ? throw const UnknownChange() : int.parse(raw),
    );
    expect(codec.decode('secret-order-42'), isEmpty);
    expect(codec.decode('new'), isEmpty);
    expect(sink.log, [
      '#1 start custom fespalier.frb.decode',
      '#1 end custom error fespalier.frb.result=error fespalier.frb.skipped=1',
      '#2 start custom fespalier.frb.decode',
      '#2 end custom skipped fespalier.frb.result=unknown fespalier.frb.skipped=1',
    ]);
    expect(sink.log.join('\n'), isNot(contains('secret')));
    expect(sink.log.join('\n'), isNot(contains('FormatException')));
    // Since 0.25.0 the span is EventCodec's, under fespalier_frb's names: never fespalier_stream's.
    expect(sink.log.join('\n'), isNot(contains('fespalier.stream')));
  });

  test('a batch codec reports under the same names', () {
    final codec = ChangeCodec.batch<String, String, int>(
      (raw) => raw.split(','),
      int.parse,
    );
    expect(codec.decode('1,x'), [1]);
    expect(sink.log, [
      '#1 start custom fespalier.frb.decode',
      '#1 end custom error fespalier.frb.result=error fespalier.frb.skipped=1',
    ]);
  });

  test('skips are reported at the 1st, 2nd, 4th and 8th of a kind', () {
    final codec = ChangeCodec<String, int>(int.parse);
    for (var i = 0; i < 9; i++) {
      expect(codec.decode('x'), isEmpty);
    }
    final ends = sink.log.where((l) => l.contains(' end '));
    expect(
      [for (final l in ends) l.split('fespalier.frb.skipped=').last],
      ['1', '2', '4', '8'],
    );
    expect(codec.errorCount, 9);
  });

  test('without a sink a skip is counted and reports nothing', () {
    FespalierTelemetry.install(null);
    final codec = ChangeCodec<String, int>(int.parse);
    expect(codec.decode('x'), isEmpty);
    expect(sink.log, isEmpty);
    expect(codec.errorCount, 1);
  });

  test(
    'a skip is a root span, not a child of the zone that watched the feed',
    () {
      final probe = ZoneProbeTelemetry();
      FespalierTelemetry.install(probe);
      final codec = ChangeCodec<String, int>(int.parse);
      runZoned(() {
        expect(Zone.current[#probe], 'page A');
        expect(codec.decode('x'), isEmpty);
      }, zoneValues: {#probe: 'page A'});
      expect(probe.seen, [null]);
      expect(codec.errorCount, 1);
    },
  );
}
