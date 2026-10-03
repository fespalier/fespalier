// The wrappers a generated file puts around guards, data and actions are pass-through: they
// return the very object, so a sync guard or `data()` stays sync and a `Future` is never
// replaced, whether or not a sink is installed. And fespalier's side of telemetry schedules
// nothing: no microtask for a sync operation (the recording sink schedules none itself).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite site = TelemetrySite(
  'a/data.dart',
  route: '/a',
  name: 'act',
);

/// The state a guard is given; telemetry reads its `uri` and nothing else.
final class FakeState implements GoRouterState {
  FakeState(String location) : uri = Uri.parse(location);

  @override
  final Uri uri;

  @override
  String? get fullPath => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

final ActionProvider<String, Object> syncAction =
    actionProvider<String, Object>(
      (ref, input) => Object(),
      invalidates: () => const [],
      telemetry: site,
    );

void main() {
  late RecordingTelemetry rec;
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('traceGuard', () {
    test('returns the very answer: sync stays sync, a Future is the same', () {
      final state = FakeState('/a');
      expect(traceGuard(state, 'g1@1', null, telemetry: site), isNull);
      expect(traceGuard(state, 'g1@1', '/login', telemetry: site), '/login');
      final later = Future<String?>.value('/x');
      expect(
        identical(traceGuard(state, 'g1@1', later, telemetry: site), later),
        isTrue,
      );
      expect(rec.log, hasLength(5));
    });

    test('schedules no microtask for a sync answer', () {
      fakeAsync((async) {
        traceGuard(FakeState('/a'), 'g1@1', '/login', telemetry: site);
        expect(rec.log, [
          '#1 start guard a/data.dart',
          '#1 end guard redirect -> /login',
        ]);
        expect(async.microtaskCount, 0);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('with no site nothing is reported, with a sink installed', () {
      traceGuard(FakeState('/a'), 'g1@1', null);
      expect(rec.log, isEmpty);
    });

    test('with a site and no sink nothing runs', () {
      FespalierTelemetry.install(null);
      expect(
        traceGuard(FakeState('/a'), 'g1@1', '/login', telemetry: site),
        '/login',
      );
      expect(rec.log, isEmpty);
    });
  });

  group('traceData', () {
    test(
      'returns the very value, and adds no microtask to what Riverpod does',
      () {
        // Riverpod schedules work of its own when a provider is read; the wrapper must add none.
        int microtasks({required bool withSite}) {
          var count = -1;
          fakeAsync((async) {
            final c = ProviderContainer();
            final value = Object();
            final p = Provider<Object>(
              (ref) => traceData(
                ref,
                'd1',
                null,
                value,
                telemetry: withSite ? site : null,
              ),
            );
            expect(identical(c.read(p), value), isTrue);
            expect(async.pendingTimers, isEmpty);
            count = async.microtaskCount;
            c.dispose();
          });
          return count;
        }

        microtasks(withSite: false); // warms up what Riverpod sets up once
        final without = microtasks(withSite: false);
        expect(microtasks(withSite: true), without);
        expect(rec.log, ['#1 start data a/data.dart', '#1 end data data']);
      },
    );

    test('a Future is the same Future', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final later = Completer<int>().future;
      final p = Provider<Future<int>>(
        (ref) => traceData(ref, 'd1', null, later, telemetry: site),
      );
      expect(identical(c.read(p), later), isTrue);
    });

    test('with no site nothing is reported', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(Provider<int>((ref) => traceData(ref, 'd1', null, 1)));
      expect(rec.log, isEmpty);
    });
  });

  group('actions', () {
    test('a sync action returns what it returns and adds no microtask', () {
      int microtasks(ActionProvider<String, Object> action) {
        var count = -1;
        fakeAsync((async) {
          final c = ProviderContainer();
          c.listen(action, (_, _) {});
          final result = c.read(action.notifier).call('x');
          expect(result is Future, isFalse);
          count = async.microtaskCount;
          c.dispose();
        });
        return count;
      }

      final plain = actionProvider<String, Object>(
        (ref, input) => Object(),
        invalidates: () => const [],
      );
      expect(microtasks(syncAction), microtasks(plain));
      expect(rec.log, ['#1 start action a/data.dart#act', '#1 end action ok']);
    });

    test('an action made without telemetry reports nothing', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final plain = actionProvider<String, String>(
        (ref, input) => input,
        invalidates: () => const [],
      );
      c.listen(plain, (_, _) {});
      c.read(plain.notifier).call('x');
      expect(rec.log, isEmpty);
    });
  });
}
