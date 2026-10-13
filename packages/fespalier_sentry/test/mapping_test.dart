// `FespalierSentry(tracing: true)`, the opt-in: what a navigation, a guard, a data load and a
// deferred load become in Sentry, from a hand-built router that calls the runtime helpers the way
// a generated app.g.dart does, on a real Sentry hub with a recording transport.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// The one transaction [lines] holds, as the SDK's JSON.
Map<String, Object?> only(List<Map<String, Object?>> sent) {
  final transactions = sent.where((e) => e['type'] == 'transaction').toList();
  expect(transactions, hasLength(1), reason: '$transactions');
  return transactions.single;
}

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('with tracing: true', () {
    testWidgets(
      'a guard, a deferred load and a data load are spans of the transaction of their screen',
      (tester) async {
        final rig = Rig(tracing: true);
        final r = await rig.boot(tester);
        r.go('/shop');
        await tester.pumpAndSettle();
        expect(await rig.lines(tester), [
          'transaction ui.load /shop status=ok ttid ttfd',
          r'  span fespalier.deferred deferred shop/page.dart status=ok',
          r'  span fespalier.guard guard shop/guard.dart status=ok',
          r'  span fespalier.data data items/$id/data.dart status=ok',
          '  span ui.load.initial_display /shop initial display status=ok',
          '  span ui.load.full_display /shop full display status=ok',
        ]);
      },
    );

    testWidgets('the transaction says how the navigation went, and never a '
        'value', (tester) async {
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/items/7?tab=2');
      await tester.pumpAndSettle();
      final tx = only(await rig.sent(tester));
      final trace = map(map(tx['contexts'])['trace']);
      expect(trace['op'], 'ui.load');
      expect(trace['origin'], 'auto.navigation.fespalier');
      expect(map(tx['transaction_info'])['source'], 'route');
      expect(tx['transaction'], '/items/:id');
      final tags = map(tx['tags']);
      expect(tags['fespalier.navigation.outcome'], 'ok');
      expect(tags['fespalier.navigation.kind'], 'go');
      final data = map(trace['data']);
      expect(data['fespalier.navigation.from'], '/home');
      expect(data['fespalier.navigation.redirected'], false);
      expect(data['fespalier.navigation.depth'], 0);
      // The path and the query are app data: not recorded unless asked.
      expect(data.containsKey('url.path'), isFalse);
      expect(tx.toString(), isNot(contains('tab=2')));
      expect(tx.toString(), isNot(contains('/items/7')));
      final measurements = map(tx['measurements']);
      expect(
        map(measurements['time_to_initial_display'])['unit'],
        'millisecond',
      );
      expect(map(measurements['time_to_full_display'])['unit'], 'millisecond');
    });

    testWidgets('the spans carry the conventions\' keys', (tester) async {
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      checkout = () async => '/login';
      r.go('/checkout');
      await tester.pumpAndSettle();
      final tx = only(await rig.sent(tester));
      final spans = (tx['spans']! as List).map(map).toList();
      final guard = spans.singleWhere((s) => s['op'] == 'fespalier.guard');
      final data = map(guard['data']);
      expect(data['fespalier.operation'], 'guard');
      expect(data['fespalier.route'], '/checkout');
      expect(data['fespalier.file'], 'checkout/guard.dart');
      expect(data['fespalier.guard.decision'], 'redirect');
      expect(data['fespalier.async'], true);
      // Where it redirected to is app data.
      expect(data.containsKey('fespalier.guard.location'), isFalse);
      expect(
        map(map(tx['contexts'])['trace'])['data'],
        containsPair('fespalier.navigation.redirected', true),
      );
      expect(tx['transaction'], '/login');
    });

    testWidgets(
      'recordLocations adds the path of the transaction and of a redirect',
      (tester) async {
        final rig = Rig(tracing: true, recordLocations: true);
        final r = await rig.boot(tester);
        checkout = () => '/login';
        r.go('/checkout?next=1');
        await tester.pumpAndSettle();
        final tx = only(await rig.sent(tester));
        expect(
          map(map(map(tx['contexts'])['trace'])['data']),
          containsPair('url.path', '/login'),
        );
        final guard = (tx['spans']! as List)
            .map(map)
            .singleWhere((s) => s['op'] == 'fespalier.guard');
        expect(
          map(guard['data']),
          containsPair('fespalier.guard.location', '/login'),
        );
        expect(tx.toString(), isNot(contains('next=1')));
      },
    );

    testWidgets(
      'a location that is no page is named navigate (not found), with neither '
      'a TTID nor a TTFD',
      (tester) async {
        final rig = Rig(tracing: true);
        final r = await rig.boot(tester);
        r.go('/nowhere');
        await tester.pumpAndSettle();
        expect(await rig.lines(tester), [
          'transaction ui.load navigate (not found) status=ok',
        ]);
        final tx = only(await rig.sent(tester));
        expect(map(tx['tags'])['fespalier.navigation.outcome'], 'not_found');
      },
    );

    testWidgets('a navigation that a newer one superseded is not sent', (
      tester,
    ) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/checkout');
      await tester.pump();
      r.go('/items/2');
      await tester.pumpAndSettle();
      answer.complete(null);
      await tester.pumpAndSettle();
      // The one for /items/2 is sent; the one that never committed was dropped by configure.
      expect(
        (await rig.lines(tester)).where((l) => l.startsWith('transaction')),
        ['transaction ui.load /items/:id status=ok ttid ttfd'],
      );
    });

    testWidgets('a pop makes no transaction, and a tab switch makes one', (
      tester,
    ) async {
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      rig.sentry.transport.envelopes.clear();
      r.pop();
      await tester.pumpAndSettle();
      expect(
        await rig.lines(tester),
        isEmpty,
        reason: 'a pop shows a built page',
      );
      r.go('/t1');
      await tester.pumpAndSettle();
      rig.sentry.transport.envelopes.clear();
      r.go('/t2');
      await tester.pumpAndSettle();
      expect(await rig.lines(tester), [
        'transaction ui.load /t2 status=ok ttid ttfd',
        '  span ui.load.initial_display /t2 initial display status=ok',
        '  span ui.load.full_display /t2 full display status=ok',
      ]);
    });

    testWidgets('a screen with no data has its TTFD at its TTID', (
      tester,
    ) async {
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(await rig.lines(tester), [
        'transaction ui.load /other status=ok ttid ttfd',
        '  span ui.load.initial_display /other initial display status=ok',
        '  span ui.load.full_display /other full display status=ok',
      ]);
    });

    testWidgets('a slow data load ends its screen when the data arrives', (
      tester,
    ) async {
      final answer = Completer<String>();
      load = (_) => answer.future;
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/items/5');
      await tester.pumpAndSettle();
      // The page is on screen, its data is not: the transaction waits, without a timer.
      expect(await rig.lines(tester), isEmpty);
      answer.complete('five');
      await tester.pumpAndSettle();
      expect(await rig.lines(tester), [
        'transaction ui.load /items/:id status=ok ttid ttfd',
        r'  span fespalier.data data items/$id/data.dart status=ok',
        '  span ui.load.initial_display /items/:id initial display status=ok',
        '  span ui.load.full_display /items/:id full display status=ok',
      ]);
    });

    testWidgets(
      'a new navigation first gives the old screen a TTFD that missed its '
      'deadline, and ends its open data span',
      (tester) async {
        final answer = Completer<String>();
        load = (_) => answer.future;
        final rig = Rig(tracing: true);
        final r = await rig.boot(tester);
        r.go('/items/5');
        await tester.pumpAndSettle();
        r.go('/other');
        await tester.pumpAndSettle();
        final lines = await rig.lines(tester);
        expect(lines, [
          'transaction ui.load /items/:id status=ok ttid',
          r'  span fespalier.data data items/$id/data.dart status=deadline_exceeded',
          '  span ui.load.initial_display /items/:id initial display status=ok',
          '  span ui.load.full_display /items/:id full display status=deadline_exceeded',
          'transaction ui.load /other status=ok ttid ttfd',
          '  span ui.load.initial_display /other initial display status=ok',
          '  span ui.load.full_display /other full display status=ok',
        ]);
        // The data finishing later changes nothing and throws nothing.
        answer.complete('late');
        await tester.pumpAndSettle();
        expect(await rig.lines(tester), hasLength(lines.length));
      },
    );

    testWidgets('fullDisplay: false ends a screen at its first frame', (
      tester,
    ) async {
      final answer = Completer<String>();
      load = (_) => answer.future;
      final rig = Rig(tracing: true, fullDisplay: false);
      final r = await rig.boot(tester);
      r.go('/items/5');
      await tester.pumpAndSettle();
      expect(
        await rig.lines(tester),
        contains('transaction ui.load /items/:id status=ok ttid'),
      );
      answer.complete('x');
      await tester.pumpAndSettle();
    });

    testWidgets('routeTag: false names no scope, but the transaction is still '
        'named by its route', (tester) async {
      final rig = Rig(tracing: true, routeTag: false);
      final r = await rig.boot(tester);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(
        (await rig.lines(tester)).first,
        startsWith('transaction ui.load /other '),
      );
      expect(rig.sentry.transactionName, isNull);
      expect(rig.sentry.tags, isEmpty);
    });

    testWidgets(
      'an action is a child of the screen\'s transaction while it is open, '
      'and a transaction of its own after',
      (tester) async {
        final answer = Completer<String>();
        load = (_) => answer.future;
        final rig = Rig(tracing: true);
        final r = await rig.boot(tester);
        r.go('/items/5');
        await tester.pumpAndSettle();
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final rename = actionProvider<String, String>(
          (ref, input) async => input,
          invalidates: () => const [],
          telemetry: actionSite,
        );
        c.listen(rename, (_, _) {});
        await c.read(rename.notifier).call('a');
        answer.complete('done');
        await tester.pumpAndSettle();
        expect(await rig.lines(tester), [
          'transaction ui.load /items/:id status=ok ttid ttfd',
          r'  span fespalier.data data items/$id/data.dart status=ok',
          '  span ui.load.initial_display /items/:id initial display status=ok',
          r'  span fespalier.action action items/$id/action.dart#rename status=ok',
          '  span ui.load.full_display /items/:id full display status=ok',
        ]);
        rig.sentry.transport.envelopes.clear();
        await c.read(rename.notifier).call('b');
        expect(await rig.lines(tester), [
          r'transaction fespalier.action action items/$id/action.dart#rename status=ok',
        ]);
      },
    );

    testWidgets('an auth step and an image load are spans of the open screen '
        'only when there is one', (tester) async {
      final answer = Completer<String>();
      load = (_) => answer.future;
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/items/5');
      await tester.pumpAndSettle();
      final auth = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.auth,
          authStep: 'refresh',
          authBackend: 'oidc',
          authTrigger: 'expired',
        ),
      );
      FespalierTelemetry.finish(
        auth,
        const TelemetryEnd(TelemetryOutcome.rejected, isAsync: true),
      );
      final image = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 320,
        ),
        underNavigation: true,
      );
      FespalierTelemetry.finish(
        image,
        const TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          imageStatus: 404,
        ),
      );
      answer.complete('x');
      await tester.pumpAndSettle();
      final tx = only(await rig.sent(tester));
      final spans = (tx['spans']! as List).map(map).toList();
      final authSpan = spans.singleWhere((s) => s['op'] == 'fespalier.auth');
      expect(authSpan['description'], 'auth refresh');
      expect(authSpan['status'], 'unauthenticated');
      expect(
        map(authSpan['data']),
        containsPair('fespalier.auth.backend', 'oidc'),
      );
      // The image load started after the navigation ended: no navigation to be a child of.
      expect(spans.where((s) => s['op'] == 'fespalier.image'), isEmpty);
    });

    testWidgets('a custom operation is a span of the open screen: its name and '
        'result, never its attributes (since 0.11.0)', (tester) async {
      final answer = Completer<String>();
      load = (_) => answer.future;
      final rig = Rig(tracing: true);
      final r = await rig.boot(tester);
      r.go('/items/5');
      await tester.pumpAndSettle();
      final op = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.custom,
          name: 'fespalier.push.open',
          attributes: {'fespalier.push.token': 'secret-token-123'},
        ),
      );
      FespalierTelemetry.finish(
        op,
        const TelemetryEnd(
          TelemetryOutcome.ok,
          attributes: {'fespalier.push.payload': 'secret-payload-456'},
        ),
      );
      answer.complete('x');
      await tester.pumpAndSettle();
      final tx = only(await rig.sent(tester));
      final spans = (tx['spans']! as List).map(map).toList();
      final span = spans.singleWhere((s) => s['op'] == 'fespalier.custom');
      expect(span['description'], 'fespalier.push.open');
      final data = map(span['data']);
      expect(data, containsPair('fespalier.operation', 'custom'));
      expect(data, containsPair('fespalier.custom.result', 'ok'));
      final everything = jsonEncode(tx);
      expect(everything, isNot(contains('secret-token-123')));
      expect(everything, isNot(contains('secret-payload-456')));
      expect(everything, isNot(contains('fespalier.push.token')));
    });
  });
}
