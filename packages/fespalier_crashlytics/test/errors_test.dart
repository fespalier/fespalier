// What a failure becomes in Crashlytics, which is the point of the package: a non-fatal named by the
// route pattern and the app file that threw, with the keys of its site, grouped by nothing Riverpod
// adds, and never a validation answer.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('a data.dart that fails', () {
    testWidgets('is one report: its reason, its keys and the very error', (
      tester,
    ) async {
      final thrown = StateError('no such item');
      load = (_) => Future<String>.error(thrown);
      final rig = Rig();
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(rig.crash.errors, hasLength(1));
      expect(
        rig.crash.lines,
        contains(r'error StateError in data items/$id/data.dart on /items/:id'),
      );
      final report = rig.crash.errors.single;
      expect(identical(report.error, thrown), isTrue);
      expect(report.reason, r'in data items/$id/data.dart on /items/:id');
      expect(report.keys, {
        'fespalier_operation': 'data',
        'fespalier_route': '/items/:id',
        'fespalier_file': r'items/$id/data.dart',
        'fespalier_action': '',
        'fespalier_screen': '/items/:id',
      });
    });

    test('a sync throw is one report too', () async {
      final rig = Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<String>(
        (ref) => traceDataCall<String>(
          ref,
          'd3',
          null,
          () => throw StateError('sync'),
          telemetry: dataSite,
        ),
      );
      // Riverpod wraps what a provider threw in its own exception, so the test accepts any.
      expect(() => c.read(provider), throwsA(isA<Object>()));
      expect(rig.crash.errors.single.error, isA<StateError>());
      expect(rig.crash.lines, [
        r'error StateError in data items/$id/data.dart on /items/:id',
      ]);
    });

    testWidgets('failing again inside the repeat window is a log line, not '
        'another report', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      await withClock(Clock.fixed(DateTime(2026, 10, 4, 12)), () async {
        final rig = Rig();
        final r = await rig.boot(tester);
        r.go('/items/7');
        await tester.pumpAndSettle();
        // Riverpod's retry, or a second visit, fails the same way.
        r.go('/home');
        await tester.pumpAndSettle();
        r.go('/items/8');
        await tester.pumpAndSettle();
        expect(rig.crash.errors, hasLength(1));
        expect(
          rig.crash.logs,
          contains(r'data items/$id/data.dart StateError again'),
        );
      });
    });

    testWidgets('and after the window, a report again', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final start = DateTime(2026, 10, 4, 12);
      final rig = Rig();
      final r = await rig.boot(tester);
      await withClock(Clock.fixed(start), () async {
        r.go('/items/7');
        await tester.pumpAndSettle();
      });
      r.go('/home');
      await tester.pumpAndSettle();
      await withClock(
        Clock.fixed(start.add(const Duration(seconds: 31))),
        () async {
          r.go('/items/8');
          await tester.pumpAndSettle();
        },
      );
      expect(rig.crash.errors, hasLength(2));
    });

    testWidgets('with repeatWindow: Duration.zero, every one is reported', (
      tester,
    ) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(repeatWindow: Duration.zero);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      r.go('/home');
      await tester.pumpAndSettle();
      r.go('/items/8');
      await tester.pumpAndSettle();
      expect(rig.crash.errors, hasLength(2));
    });
  });

  group('an action', () {
    test('that fails is one report whose reason names the action', () async {
      final rig = Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      await expectLater(c.read(rename.notifier).call('fail'), throwsStateError);
      expect(rig.crash.errors, hasLength(1));
      final report = rig.crash.errors.single;
      expect(
        report.reason,
        r'in action items/$id/action.dart#rename on /items/:id',
      );
      expect(report.error, isA<StateError>());
      expect(report.keys['fespalier_operation'], 'action');
      expect(report.keys['fespalier_action'], 'rename');
      expect(report.keys['fespalier_file'], r'items/$id/action.dart');
      expect(report.keys['fespalier_route'], '/items/:id');
    });

    test(
      'that is a validation answer is no report: a log line by class',
      () async {
        final rig = Rig();
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.listen(rename, (_, _) {});
        await expectLater(
          c.read(rename.notifier).call('invalid'),
          throwsA(isA<FieldErrors>()),
        );
        expect(rig.crash.errors, isEmpty);
        expect(rig.crash.logs, [r'action items/$id/action.dart rejected']);
      },
    );
  });

  group('the other operations', () {
    testWidgets('a guard that throws is one report on its file', (
      tester,
    ) async {
      checkout = () => Future<String?>.error(StateError('boom'));
      final rig = Rig();
      final r = await rig.boot(tester);
      // go_router turns a throwing guard into an error the app shows: not this test's business.
      await runZonedGuarded(() async {
        r.go('/checkout');
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
      }, (error, _) {});
      expect(rig.crash.errors, hasLength(1));
      expect(
        rig.crash.lines,
        contains('error StateError in guard checkout/guard.dart on /checkout'),
      );
      expect(rig.crash.errors.single.keys['fespalier_operation'], 'guard');
    });

    test('a deferred load that fails is one report on its page file', () {
      final rig = Rig();
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.deferred,
          file: 'shop/page.dart',
          route: '/shop',
        ),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: StateError('load failed'),
        ),
      );
      expect(rig.crash.lines, [
        'error StateError in deferred shop/page.dart on /shop',
      ]);
    });

    test('an auth step that fails is no report: a log line by class', () {
      final rig = Rig();
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.auth,
          authStep: 'refresh',
          authBackend: 'oidc',
        ),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: StateError('connect to https://idp.example.com failed'),
        ),
      );
      expect(rig.crash.errors, isEmpty);
      expect(rig.crash.logs, ['auth refresh StateError']);
    });

    test('a custom operation that fails is no report by default: a log line '
        'with the class and not the text', () {
      final rig = Rig();
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: StateError('push token abc123 refused'),
        ),
      );
      expect(rig.crash.errors, isEmpty);
      expect(rig.crash.logs, ['custom fespalier.push.open StateError']);
      expect(rig.crash.strings.join(), isNot(contains('abc123')));
    });

    test('a custom operation the app opts into is a report named by its '
        'operation', () {
      final rig = Rig(capture: (error, start) => true);
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: StateError('push token abc123 refused'),
        ),
      );
      expect(rig.crash.errors, hasLength(1));
      expect(rig.crash.errors.single.reason, 'in custom fespalier.push.open');
      expect(rig.crash.errors.single.keys['fespalier_operation'], 'custom');
    });

    test('an image that fails with no error object is a log line with its '
        'status', () {
      final rig = Rig();
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 320,
        ),
      );
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          imageStatus: 404,
        ),
      );
      expect(rig.crash.errors, isEmpty);
      expect(rig.crash.logs, ['image emgr error status=404']);
    });

    testWidgets('a custom capture decides', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(capture: (error, start) => start.op != TelemetryOp.data);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(rig.crash.errors, isEmpty);
      expect(rig.crash.logs, contains(r'data items/$id/data.dart StateError'));
    });
  });
}
