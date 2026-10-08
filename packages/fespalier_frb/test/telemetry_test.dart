// The package's own telemetry contract: one custom operation, constants only.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
