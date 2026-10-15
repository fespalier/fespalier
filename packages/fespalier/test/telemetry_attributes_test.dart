// Telemetry attributes (since 0.18.0): which try a data load is (`fespalier.data.attempt`), where a
// `dataCache` load's content came from (`fespalier.data.source`), whether an optimistic write was
// undone (`fespalier.action.rolled_back`) and whether validation stopped a run
// (`fespalier.action.invalid`). A `RecordingTelemetry` keeps the lines; a `Fields` sink keeps the
// typed values a real sink reads.

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite dataSite = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);
const TelemetrySite saveSite = TelemetrySite(
  'items/\$id/action.dart',
  route: '/items/:id',
  name: 'save',
);

/// Keeps what a sink is told as typed values.
final class Fields extends FespalierTelemetry {
  final List<TelemetryStart> starts = [];
  final List<TelemetryEnd> ends = [];

  /// The `dataAttempt` of each data start, in order.
  List<int?> get dataAttempts => [
    for (final s in starts)
      if (s.op == TelemetryOp.data) s.dataAttempt,
  ];

  @override
  Object? start(TelemetryStart start) {
    starts.add(start);
    return starts.length;
  }

  @override
  void end(Object? token, TelemetryEnd end) => ends.add(end);
}

/// A `data()` whose first [failures] calls fail with an async error, then answers its call number.
final class Flaky {
  Flaky(this.failures);

  final int failures;
  int calls = 0;

  Future<int> call() async {
    calls++;
    if (calls <= failures) throw StateError('try $calls');
    return calls;
  }
}

/// What the test drives the retries with: fails each retry at once, and never more than 5 times.
ProviderContainer retrying() =>
    ProviderContainer(retry: (n, _) => n < 5 ? Duration.zero : null);

/// Lets Riverpod's zero-length retry timers run, and the futures they wait for.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A `data()` of a `dataCache` provider that is [Server]: the Nth load yields N, or throws while
/// [offline].
class Server {
  int loads = 0;
  bool offline = false;

  Future<int> call() async {
    loads++;
    if (offline) throw Exception('offline');
    return loads;
  }
}

Future<ProviderContainer> bootWith(
  WidgetTester tester,
  MemoryDataStorage storage,
) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: <Override>[dataCacheStorage.overrideWithValue(storage)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      // A new element, so Riverpod refreshes on this container's frames, not on timers.
      key: UniqueKey(),
      container: container,
      child: const SizedBox.shrink(),
    ),
  );
  return container;
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

void main() {
  late RecordingTelemetry rec;
  late Fields fields;

  setUp(() {
    rec = RecordingTelemetry();
    fields = Fields();
    FespalierTelemetry.install(FespalierTelemetry.combine([rec, fields]));
  });

  tearDown(() => FespalierTelemetry.install(null));

  group('fespalier.data.attempt', () {
    test('a load Riverpod retries on its own counts its tries', () async {
      final flaky = Flaky(2);
      final p = FutureProvider.autoDispose<int>(
        (ref) =>
            traceDataCall(ref, 'd9', null, flaky.call, telemetry: dataSite),
      );
      final c = retrying();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});
      await settle();
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data error async error=Bad state: try 1',
        '#2 start data items/\$id/data.dart attempt=2',
        '#2 end data error async error=Bad state: try 2',
        '#3 start data items/\$id/data.dart attempt=3',
        '#3 end data data async',
      ]);
      // A success resets the count: the next load, after a reload the app asks for, is try 1.
      c.invalidate(p);
      await settle();
      expect(rec.log.last, '#4 end data data async');
      expect(rec.log[rec.log.length - 2], '#4 start data items/\$id/data.dart');
    });

    test('a reload the app asks for is try 1, not a retry', () async {
      final flaky = Flaky(1);
      final p = FutureProvider.autoDispose<int>(
        (ref) =>
            traceDataCall(ref, 'd9', null, flaky.call, telemetry: dataSite),
      );
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});
      await settle();
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data error async error=Bad state: try 1',
      ]);
      c.invalidate(p);
      await settle();
      expect(rec.log, contains('#2 start data items/\$id/data.dart'));
      expect(rec.log.last, '#2 end data data async');
    });

    test('each family key counts its tries apart', () async {
      final flakies = {1: Flaky(1), 2: Flaky(0)};
      final p = FutureProvider.autoDispose.family<int, int>(
        (ref, id) => traceDataCall(
          ref,
          'd9',
          id,
          () => flakies[id]!.call(),
          telemetry: dataSite,
        ),
      );
      final c = retrying();
      addTearDown(c.dispose);
      // Key 1 fails and is retried; key 2 is loaded before that retry, for the first time.
      c.listen(p(1), (_, _) {}, onError: (_, _) {});
      c.listen(p(2), (_, _) {}, onError: (_, _) {});
      await settle();
      expect(rec.log, contains('#1 start data items/\$id/data.dart keyed'));
      expect(rec.log, contains('#2 start data items/\$id/data.dart keyed'));
      expect(
        rec.log,
        contains('#3 start data items/\$id/data.dart keyed attempt=2'),
      );
      expect(rec.log, contains('#2 end data data async'));
      expect(rec.log.last, '#3 end data data async');
    });

    test('the sink is told the try as TelemetryStart.dataAttempt', () async {
      final flaky = Flaky(2);
      final p = FutureProvider.autoDispose<int>(
        (ref) =>
            traceDataCall(ref, 'd9', null, flaky.call, telemetry: dataSite),
      );
      final c = retrying();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});
      await settle();
      expect(fields.dataAttempts, [1, 2, 3]);
    });

    test('a synchronous load is try 1 and ends at once', () {
      final p = Provider.autoDispose<String>(
        (ref) => traceDataCall(ref, 'd9', null, () => 'x', telemetry: dataSite),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {});
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data data',
      ]);
      expect(fields.dataAttempts, [1]);
    });
  });

  group('fespalier.data.source', () {
    testWidgets('a dataCache load says fetch, then cache at the next start', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final server = Server();
      final p = cachedData<int>(
        (ref) =>
            traceDataCall(ref, 'd9', null, server.call, telemetry: dataSite),
        cache: DataCache<int>.json(
          toJson: (v) => v,
          fromJson: (j) => j! as int,
        ),
        name: 'items',
      );
      final first = await bootWith(tester, storage);
      final subscription = first.listen(p, (_, _) {});
      await frames(tester);
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data data async source=fetch',
      ]);
      subscription.close();
      await frames(tester);
      first.dispose();

      final second = await bootWith(tester, storage);
      final again = second.listen(p, (_, _) {});
      expect(second.read(p).isFromCache, isTrue);
      await frames(tester);
      expect(rec.log.last, '#2 end data data async source=cache');
      expect(rec.log[rec.log.length - 2], '#2 start data items/\$id/data.dart');
      again.close();
      await frames(tester);
    });

    testWidgets('a load that fails behind the saved copy still says cache', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final server = Server();
      final p = cachedData<int>(
        (ref) =>
            traceDataCall(ref, 'd9', null, server.call, telemetry: dataSite),
        cache: DataCache<int>.json(
          toJson: (v) => v,
          fromJson: (j) => j! as int,
        ),
        name: 'items',
      );
      final first = await bootWith(tester, storage);
      final subscription = first.listen(p, (_, _) {});
      await frames(tester);
      subscription.close();
      await frames(tester);
      first.dispose();

      server.offline = true;
      final second = await bootWith(tester, storage);
      final again = second.listen(p, (_, _) {});
      await frames(tester);
      expect(
        rec.log.last,
        '#2 end data error async source=cache error=Exception: offline',
      );
      again.close();
      await frames(tester);
    });

    test('a data.dart with no dataCache has no source', () async {
      final p = FutureProvider.autoDispose<int>(
        (ref) =>
            traceDataCall(ref, 'd9', null, () async => 1, telemetry: dataSite),
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {});
      await settle();
      expect(fields.ends.single.dataSource, isNull);
      expect(rec.log.last, '#1 end data data async');
    });
  });

  group('fespalier.action.rolled_back and fespalier.action.invalid', () {
    ActionProvider<int, int> saves(OptimisticLayerProvider<int> layer) =>
        actionProvider<int, int>(
          (ref, input) async {
            if (input < 0) throw StateError('no');
            return input;
          },
          invalidates: () => const [],
          optimistic: () => layer.patch((int v, int input) => input),
          telemetry: saveSite,
        );

    test('an optimistic write that fails is rolled back, one that works '
        'is not', () async {
      final data = FutureProvider.autoDispose<int>((ref) async => 1);
      final layer = optimisticLayer(data);
      final save = saves(layer);
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      c.listen(data, (_, _) {});
      c.listen(layer, (_, _) {});
      c.listen(save, (_, _) {});
      await expectLater(
        Future.value(c.read(save.notifier).call(-1)),
        throwsStateError,
      );
      expect(
        rec.log.last,
        '#1 end action error async rolled_back=true error=Bad state: no',
      );
      await c.read(save.notifier).call(5);
      expect(rec.log.last, '#2 end action ok async rolled_back=false');
      expect(fields.ends.map((e) => e.actionRolledBack), [true, false]);
    });

    test('a write whose patch nothing shows has no rolled_back', () async {
      final data = FutureProvider.autoDispose<int>((ref) async => 1);
      final layer = optimisticLayer(data);
      final save = saves(layer);
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      // The layer is not listened to, so nothing shows a patch.
      c.listen(save, (_, _) {});
      await expectLater(
        Future.value(c.read(save.notifier).call(-1)),
        throwsStateError,
      );
      expect(rec.log.last, '#1 end action error async error=Bad state: no');
      expect(fields.ends.single.actionRolledBack, isNull);
    });

    test('validate() that refuses is invalid', () {
      final rename = actionProvider<String, String>(
        (ref, input) => input.toUpperCase(),
        invalidates: () => const [],
        validate: (input) =>
            input.isEmpty ? const FieldErrors({'name': 'Required'}) : null,
        telemetry: saveSite,
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      expect(
        () => c.read(rename.notifier).call(''),
        throwsA(isA<FieldErrors>()),
      );
      expect(rec.log, [
        '#1 start action items/\$id/action.dart#save',
        '#1 end action error invalid error=name: Required',
      ]);
      expect(fields.ends.single.actionInvalid, isTrue);
    });

    test('an action that throws FieldErrors is invalid', () async {
      final take = actionProvider<String, String>(
        (ref, input) async {
          throw const FieldErrors({'name': 'Taken'});
        },
        invalidates: () => const [],
        telemetry: saveSite,
      );
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      c.listen(take, (_, _) {});
      await expectLater(
        Future.value(c.read(take.notifier).call('a')),
        throwsA(isA<FieldErrors>()),
      );
      expect(
        rec.log.last,
        '#1 end action error async invalid error=name: Taken',
      );
    });

    test(
      'any other failure is not invalid, and a success is neither',
      () async {
        final fails = actionProvider<String, String>(
          (ref, input) => throw StateError('no'),
          invalidates: () => const [],
          telemetry: saveSite,
        );
        final ok = actionProvider<String, String>(
          (ref, input) => input,
          invalidates: () => const [],
          telemetry: saveSite,
        );
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.listen(fails, (_, _) {});
        c.listen(ok, (_, _) {});
        expect(() => c.read(fails.notifier).call('a'), throwsStateError);
        expect(rec.log[1], '#1 end action error error=Bad state: no');
        expect(c.read(ok.notifier).call('a'), 'a');
        expect(rec.log.last, '#2 end action ok');
        expect(fields.ends.map((e) => e.actionInvalid), [false, false]);
        expect(fields.ends.map((e) => e.actionRolledBack), [null, null]);
      },
    );
  });
}
