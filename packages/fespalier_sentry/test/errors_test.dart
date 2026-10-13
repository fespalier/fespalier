// What a failure becomes in Sentry, which is the point of the package: an event tagged with the
// route pattern, the app file and the action, grouped by file, and never a validation answer.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

/// The events (not transactions) among [sent].
List<Map<String, Object?>> events(List<Map<String, Object?>> sent) =>
    sent.where((e) => e['type'] != 'transaction').toList();

/// The first exception of an event.
Map<String, Object?> exception(Map<String, Object?> event) =>
    map((map(event['exception'])['values']! as List).first);

final ActionProvider<String, String> rename = actionProvider<String, String>(
  (ref, input) async {
    if (input == 'fail') throw StateError('rename refused');
    if (input == 'invalid') {
      throw const FieldErrors(<String, String>{'name': 'taken'});
    }
    return input;
  },
  invalidates: () => const [],
  telemetry: actionSite,
);

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('a data.dart that fails', () {
    testWidgets('is one event: four tags, the file, a mechanism and a context', (
      tester,
    ) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig();
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      final sent = events(await rig.sent(tester));
      expect(sent, hasLength(1));
      final event = sent.single;
      final tags = map(event['tags']);
      expect(tags['fespalier.operation'], 'data');
      expect(tags['fespalier.route'], '/items/:id');
      expect(tags['fespalier.file'], r'items/$id/data.dart');
      expect(tags.containsKey('fespalier.action'), isFalse);
      // Grouped by the file, not by the Riverpod frames on top of the stack.
      expect(event['fingerprint'], ['{{ default }}', r'items/$id/data.dart']);
      final error = exception(event);
      expect(error['type'], 'StateError');
      expect(error['value'], 'Bad state: no such item');
      expect(map(error['mechanism']), containsPair('type', 'fespalier.data'));
      expect(map(error['mechanism']), containsPair('handled', true));
      expect(map(map(event['contexts'])['fespalier']), {
        'fespalier.operation': 'data',
        'fespalier.route': '/items/:id',
        'fespalier.file': r'items/$id/data.dart',
        'fespalier.async': true,
        'fespalier.data.keyed': true,
      });
      // The screen is the event's transaction, so the issue list can be searched by it.
      expect(event['transaction'], '/items/:id');
      expect(await rig.lines(tester), [
        r'event StateError operation=data route=/items/:id file=items/$id/data.dart',
      ]);
    });

    test('a sync throw is one too', () async {
      final rig = Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<String>(
        (ref) => traceDataCall<String>(
          ref,
          'd1',
          null,
          () => throw StateError('sync'),
          telemetry: dataSite,
        ),
      );
      expect(() => c.read(provider), throwsA(isA<Object>()));
      expect(await rig.plainLines(), [
        r'event StateError operation=data route=/items/:id file=items/$id/data.dart',
      ]);
    });

    testWidgets('failing again inside the repeat window is a breadcrumb', (
      tester,
    ) async {
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
        expect(events(await rig.sent(tester)), hasLength(1));
        expect(
          rig.sentry.breadcrumbs,
          contains(r'fespalier.data data items/$id/data.dart StateError again'),
        );
      });
    });

    testWidgets('and after it, an event again', (tester) async {
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
      expect(events(await rig.sent(tester)), hasLength(2));
    });

    testWidgets('repeatWindow: Duration.zero sends every one', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(repeatWindow: Duration.zero);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      r.go('/home');
      await tester.pumpAndSettle();
      r.go('/items/8');
      await tester.pumpAndSettle();
      expect(events(await rig.sent(tester)), hasLength(2));
    });
  });

  group('an action', () {
    test('that fails is an event with its name, and the error is the '
        'caller\'s', () async {
      final rig = Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      await expectLater(c.read(rename.notifier).call('fail'), throwsStateError);
      final event = events(await rig.plainSent()).single;
      final tags = map(event['tags']);
      expect(tags['fespalier.operation'], 'action');
      expect(tags['fespalier.action'], 'rename');
      expect(tags['fespalier.file'], r'items/$id/action.dart');
      expect(tags['fespalier.route'], '/items/:id');
      expect(event['fingerprint'], ['{{ default }}', r'items/$id/action.dart']);
      expect(
        map(exception(event)['mechanism']),
        containsPair('type', 'fespalier.action'),
      );
      expect(await rig.plainLines(), [
        r'event StateError operation=action route=/items/:id file=items/$id/action.dart action=rename',
      ]);
    });

    test('that is a validation answer is no event: a breadcrumb', () async {
      final rig = Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      await expectLater(
        c.read(rename.notifier).call('invalid'),
        throwsA(isA<FieldErrors>()),
      );
      expect(await rig.plainSent(), isEmpty);
      expect(rig.sentry.breadcrumbs, [
        r'fespalier.action action items/$id/action.dart rejected',
      ]);
    });

    test(
      'that works is a breadcrumb with its result, never its input',
      () async {
        final rig = Rig();
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.listen(rename, (_, _) {});
        await c.read(rename.notifier).call('a secret name');
        expect(rig.sentry.breadcrumbs, [
          r'fespalier.action items/$id/action.dart#rename ok',
        ]);
        expect(rig.sentry.breadcrumbs.join(), isNot(contains('secret')));
      },
    );
  });

  group('the other operations', () {
    testWidgets('a guard that throws is an event on its file', (tester) async {
      checkout = () => Future<String?>.error(StateError('boom'));
      final rig = Rig();
      final r = await rig.boot(tester);
      // go_router turns a throwing guard into a GoException the app would show: not this test's
      // business.
      await runZonedGuarded(() async {
        r.go('/checkout');
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
      }, (error, _) {});
      expect(await rig.lines(tester), [
        'event StateError operation=guard route=/checkout file=checkout/guard.dart',
      ]);
    });

    testWidgets('an auth step that fails is no event: a breadcrumb with the '
        'class of the error and not its text', (tester) async {
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
      expect(await rig.sent(tester), isEmpty);
      expect(rig.sentry.breadcrumbs, [
        'fespalier.auth auth refresh StateError',
      ]);
    });

    testWidgets('a custom operation that fails is no event by default: a '
        'breadcrumb with the class and not the text', (tester) async {
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
      expect(await rig.sent(tester), isEmpty);
      expect(rig.sentry.breadcrumbs, [
        'fespalier.custom custom fespalier.push.open StateError',
      ]);
      expect(rig.sentry.breadcrumbs.join(), isNot(contains('abc123')));
    });

    testWidgets('a custom operation an app opts into is an event tagged '
        'with its name and grouped by it', (tester) async {
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
      final event = events(await rig.sent(tester)).single;
      expect(
        map(event['tags'])['fespalier.custom.name'],
        'fespalier.push.open',
      );
      expect(
        map(map(event['contexts'])['fespalier'])['fespalier.custom.name'],
        'fespalier.push.open',
      );
      expect(event['fingerprint'], ['{{ default }}', 'fespalier.push.open']);
    });

    testWidgets('an image that fails has no error object: a breadcrumb with '
        'its status', (tester) async {
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
      expect(await rig.sent(tester), isEmpty);
      expect(rig.sentry.breadcrumbs, [
        'fespalier.image image emgr error status=404',
      ]);
    });

    testWidgets('a custom capture decides', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(capture: (error, start) => start.op != TelemetryOp.data);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(await rig.sent(tester), isEmpty);
      expect(
        rig.sentry.breadcrumbs,
        contains(r'fespalier.data data items/$id/data.dart StateError'),
      );
    });

    testWidgets('breadcrumbs: false keeps the events and drops the rest', (
      tester,
    ) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(breadcrumbs: false);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(events(await rig.sent(tester)), hasLength(1));
      expect(rig.sentry.breadcrumbs, isEmpty);
    });
  });

  group('with tracing: true', () {
    testWidgets('the event belongs to the span of the operation that failed', (
      tester,
    ) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      final sent = await rig.sent(tester);
      final event = events(sent).single;
      final transaction = sent.singleWhere((e) => e['type'] == 'transaction');
      final span = (transaction['spans']! as List)
          .map(map)
          .singleWhere((s) => s['op'] == 'fespalier.data');
      expect(span['status'], 'internal_error');
      expect(map(span['data']), containsPair('fespalier.data.state', 'error'));
      final trace = map(map(event['contexts'])['trace']);
      expect(trace['span_id'], span['span_id']);
      expect(trace['trace_id'], span['trace_id']);
    });

    test('a validation answer is a span with status invalid_argument, and no '
        'event', () async {
      final rig = Rig(tracing: true);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      await expectLater(
        c.read(rename.notifier).call('invalid'),
        throwsA(isA<FieldErrors>()),
      );
      final sent = await rig.plainSent();
      expect(events(sent), isEmpty);
      expect(
        map(map(sent.single['contexts'])['trace'])['status'],
        'invalid_argument',
      );
    });
  });
}
