// `SentryNavigatorObserver` next to this sink: `FespalierSentry.navigatorObserver()` makes no
// transaction (it is there for release health on the web, the app-start screen's name and
// `view_names`), and `transactions: false` hands the transactions to a plain observer, which this
// sink adds data spans, time to full display and its events to.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('FespalierSentry.navigatorObserver()', () {
    testWidgets('pushed twice makes no transaction', (tester) async {
      final rig = Rig(tracing: true);
      final observer = FespalierSentry.navigatorObserver(hub: rig.sentry.hub);
      final r = await rig.boot(tester, observers: [observer]);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      // Only this sink's transactions: one per navigation, none for a push of the observer's.
      expect(
        (await rig.lines(tester)).where((l) => l.startsWith('transaction')),
        [
          'transaction ui.load /other status=ok ttid ttfd',
          'transaction ui.load /other status=ok ttid ttfd',
        ],
      );
    });

    testWidgets(
      'its own breadcrumbs are dropped: this sink\'s say the same with '
      'the pattern',
      (tester) async {
        final rig = Rig();
        final observer = FespalierSentry.navigatorObserver(hub: rig.sentry.hub);
        final r = await rig.boot(tester, observers: [observer]);
        r.go('/items/7');
        await tester.pumpAndSettle();
        unawaited(r.push<void>('/other'));
        await tester.pumpAndSettle();
        expect(rig.sentry.breadcrumbs, [
          'navigation enter /home',
          'navigation enter /items/:id',
          'navigation enter /other',
        ]);
      },
    );

    testWidgets('observerBreadcrumbs: true keeps them', (tester) async {
      final rig = Rig(
        configured: false,
        configure: (o) => FespalierSentry.configure(
          o,
          dsn: Rig.dsn,
          observerBreadcrumbs: true,
        ),
      );
      final observer = FespalierSentry.navigatorObserver(hub: rig.sentry.hub);
      final r = await rig.boot(tester, observers: [observer]);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(
        rig.sentry.rawBreadcrumbs.where((b) => b.data?['state'] == 'didPush'),
        isNotEmpty,
      );
    });
  });

  group('transactions: false, next to the transaction an observer made', () {
    /// The observer's own transaction is bound to the scope by hand: `SentryNavigatorObserver`
    /// starts a timer for the transaction it makes (`autoFinishAfter`), which a test cannot leave
    /// pending. What this sink reads is the transaction on the scope, whoever bound it.
    Rig rigWith(FakeDisplay display) =>
        Rig(tracing: true, transactions: false, currentDisplay: (_) => display);

    testWidgets('makes no transaction, guard, redirect or deferred span of its '
        'own', (tester) async {
      final rig = rigWith(FakeDisplay());
      final observer = SentryNavigatorObserver(
        hub: rig.sentry.hub,
        enableAutoTransactions: false,
      );
      final r = await rig.boot(tester, observers: [observer]);
      r.go('/shop');
      await tester.pumpAndSettle();
      expect(await rig.lines(tester), isEmpty);
    });

    testWidgets('a data span is a child of the transaction the observer made, '
        'and Sentry is told when the data is in', (tester) async {
      final answer = Completer<String>();
      load = (_) => answer.future;
      final display = FakeDisplay();
      final rig = rigWith(display);
      final r = await rig.boot(tester);
      // The first screen, which has no data, was reported at once.
      final before = display.reported;
      // What the observer does on a push: a transaction bound to the scope.
      final observersTx = rig.sentry.hub.startTransaction(
        'items',
        'ui.load',
        bindToScope: true,
      );
      r.go('/items/5');
      await tester.pumpAndSettle();
      expect(
        display.reported,
        before,
        reason: 'the page is up, its data is not',
      );
      answer.complete('five');
      await tester.pumpAndSettle();
      expect(display.reported, before + 1);
      await observersTx.finish(status: const SpanStatus.ok());
      expect(await rig.lines(tester), [
        'transaction ui.load items status=ok',
        r'  span fespalier.data data items/$id/data.dart status=ok',
      ]);
    });

    testWidgets('a screen without data is reported at once', (tester) async {
      final display = FakeDisplay();
      final rig = rigWith(display);
      final r = await rig.boot(tester);
      expect(display.reported, 1, reason: 'the first screen');
      r.go('/other');
      await tester.pumpAndSettle();
      expect(display.reported, 2);
    });

    testWidgets('an error is still an event, and the route is still its '
        'transaction name', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = rigWith(FakeDisplay());
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(await rig.lines(tester), [
        r'event StateError operation=data route=/items/:id file=items/$id/data.dart',
      ]);
      expect(rig.sentry.transactionName, '/items/:id');
    });
  });
}
