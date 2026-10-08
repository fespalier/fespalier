// /orders: a read served from the device when the network is down (ref.serve), and a decision that is
// queued as an intent (IntentQueue.submit) and sent once when the network is back. The package's fakes play
// the shop; nothing waits on real time.
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Finder get _cancelOne => find.text('Cancel order 1');

void main() {
  group('a read, served', () {
    testWidgets('from the network when there is one', (tester) async {
      final shop = Harness();
      await shop.open(tester);

      expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);
      expect(find.textContaining('Offline copy'), findsNothing);
    });

    testWidgets(
      'from the copy on the device when the network is gone, with its time',
      (tester) async {
        final shop = Harness();
        await shop.open(tester);
        await shop.setNetwork(tester, online: false);

        // The cancel is a write; what it makes stale loads again, offline: the copy answers.
        await tester.tap(_cancelOne);
        await tester.pumpAndSettle();

        expect(find.textContaining('Offline copy, as of'), findsOneWidget);
        expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);
      },
    );

    testWidgets(
      'an empty answer when nothing was ever loaded: not loaded yet, not "no orders"',
      (tester) async {
        final shop = Harness(startOffline: true);
        await shop.open(tester);

        expect(
          find.text('Offline: not loaded on this phone yet'),
          findsOneWidget,
        );
        expect(find.textContaining('Order 1'), findsNothing);
      },
    );

    testWidgets(
      'a refusal is the answer: the copy on the device is never shown for it',
      (tester) async {
        final shop = Harness();
        await shop.open(tester);
        expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);

        // The account lost access. Going offline and online again is a reconnect: the list reads again.
        shop.transport.refuse('listOrders', 403, 'FORBIDDEN', 'not yours');
        await shop.setNetwork(tester, online: false);
        await shop.setNetwork(tester, online: true);

        expect(find.text('The shop refused this: FORBIDDEN'), findsOneWidget);
        expect(find.text('Order 1: Ceramic mug (placed)'), findsNothing);
      },
    );
  });

  group('a route with a freshness keeps its page, except for a refusal', () {
    testWidgets('a reload the shop refuses (403) shows error.dart instead of '
        'the page', (tester) async {
      final shop = Harness();
      await shop.open(tester);
      expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);

      shop.transport.refuse('listOrders', 403, 'FORBIDDEN', 'not yours');
      await shop.setNetwork(tester, online: false);
      await shop.setNetwork(tester, online: true);

      expect(find.text('The shop refused this: FORBIDDEN'), findsOneWidget);
      expect(find.text('Order 1: Ceramic mug (placed)'), findsNothing);

      // The shop lets the account back in: a retry brings the page back.
      shop.transport.heal('listOrders');
      await tester.tap(find.byType(TextButton).first);
      await tester.pumpAndSettle();
      expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);
    });

    testWidgets('a reload that fails with a 503 keeps the page', (
      tester,
    ) async {
      final shop = Harness();
      await shop.open(tester);

      shop.transport.refuse('listOrders', 503, 'UNAVAILABLE', 'down');
      await shop.setNetwork(tester, online: false);
      await shop.setNetwork(tester, online: true);

      expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);
      expect(find.textContaining('refused'), findsNothing);
    });
  });

  group('a decision, as an intent', () {
    testWidgets('online, the server answers and the order is cancelled', (
      tester,
    ) async {
      final shop = Harness();
      await shop.open(tester);

      await tester.tap(_cancelOne);
      await tester.pumpAndSettle();

      expect(find.text('Order 1 cancelled'), findsOneWidget);
      expect(find.text('Order 1: Ceramic mug (cancelled)'), findsOneWidget);
      expect(shop.transport.runs('cancelOrder'), 1);
    });

    testWidgets('offline, it is queued and says so; back online, it is sent once', (
      tester,
    ) async {
      final shop = Harness();
      final container = await shop.open(tester);
      await shop.setNetwork(tester, online: false);

      await tester.tap(_cancelOne);
      await tester.pumpAndSettle();

      // Never a success the server has not given.
      expect(
        find.text('Saved. It will be sent when you are back online'),
        findsOneWidget,
      );
      expect(
        find.text('Cancelling, will send when back online'),
        findsOneWidget,
      );
      expect(find.text('1 change waiting to send'), findsOneWidget);
      expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);
      expect(shop.transport.runs('cancelOrder'), 0);

      await shop.setNetwork(tester, online: true);

      // The reconnect trigger drained the queue: one run, from the intent the device had saved.
      expect(shop.transport.runs('cancelOrder'), 1);
      expect(find.text('Order 1: Ceramic mug (cancelled)'), findsOneWidget);
      expect(find.textContaining('waiting to send'), findsNothing);
      expect(await container.read(intentQueue).list(), isEmpty);

      // The key is <id>#<attempt>, and nothing sends it again, whatever triggers come.
      final keys = [for (final c in shop.sent('cancelOrder')) c.idempotencyKey];
      expect(keys, hasLength(1));
      expect(keys.single, matches(RegExp(r'^[0-9a-f]{32}#0$')));
      await tester.pump(const Duration(days: 1));
      tick(container);
      await tester.pumpAndSettle();
      expect(shop.transport.runs('cancelOrder'), 1);
    });

    testWidgets('a lost answer is replayed under the same key and runs once', (
      tester,
    ) async {
      final shop = Harness();
      final container = await shop.open(tester);
      // The server cancels it, and the answer never arrives.
      shop.transport.loseAnswer('cancelOrder');

      await tester.tap(_cancelOne);
      await tester.pumpAndSettle();
      expect(
        find.text('Saved. It will be sent when you are back online'),
        findsOneWidget,
      );
      expect(shop.transport.runs('cancelOrder'), 1);

      // The next sync sends the saved call again: the stored answer comes back, nothing runs twice.
      tick(container);
      await tester.pumpAndSettle();

      expect(shop.transport.runs('cancelOrder'), 1);
      // Two sends, one key: the second was a replay.
      expect(shop.sent('cancelOrder'), hasLength(2));
      expect({
        for (final c in shop.sent('cancelOrder')) c.idempotencyKey,
      }, hasLength(1));
      expect(find.text('Order 1: Ceramic mug (cancelled)'), findsOneWidget);
      expect(await container.read(intentQueue).list(), isEmpty);
    });

    testWidgets(
      'a refusal on the spot is shown, kept nowhere and never retried',
      (tester) async {
        final shop = Harness();
        final container = await shop.open(tester);
        shop.transport.refuse(
          'cancelOrder',
          422,
          'ORDER_ALREADY_SHIPPED',
          'a shipped order cannot be cancelled',
        );

        await tester.tap(find.text('Cancel order 3'));
        await tester.pumpAndSettle();

        expect(
          find.text('The shop refused: ORDER_ALREADY_SHIPPED'),
          findsOneWidget,
        );
        expect(await container.read(intentQueue).list(), isEmpty);
        int sends() => shop.sent('cancelOrder').length;
        expect(sends(), 1);

        // However long the app waits, and whatever trigger fires: it is not tried again.
        await tester.pump(const Duration(minutes: 30));
        tick(container);
        await tester.pumpAndSettle();
        expect(sends(), 1);
      },
    );

    testWidgets(
      'a refusal after the wait is kept as not sent, shown, and never retried',
      (tester) async {
        final shop = Harness();
        final container = await shop.open(tester);
        shop.transport.refuse(
          'cancelOrder',
          422,
          'ORDER_ALREADY_SHIPPED',
          'a shipped order cannot be cancelled',
        );
        await shop.setNetwork(tester, online: false);
        await tester.tap(find.text('Cancel order 3'));
        await tester.pumpAndSettle();
        expect(find.text('1 change waiting to send'), findsOneWidget);

        await shop.setNetwork(tester, online: true);

        expect(
          find.text(
            'Not sent: the shop refused order:3 (ORDER_ALREADY_SHIPPED)',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('waiting to send'), findsNothing);
        final intents = await container.read(intentQueue).list();
        expect(intents.single.status, IntentStatus.failed);
        expect(intents.single.reason, 'ORDER_ALREADY_SHIPPED');

        // Only the person decides what happens to it.
        tick(container);
        await tester.pumpAndSettle();
        expect(shop.sent('cancelOrder'), hasLength(1));
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Not sent'), findsNothing);
        expect(await container.read(intentQueue).list(), isEmpty);
      },
    );
  });

  group('signing out', () {
    testWidgets('wipes the queue and the saved reads before the session ends', (
      tester,
    ) async {
      final shop = Harness();
      final container = await shop.open(tester);
      await shop.setNetwork(tester, online: false);
      await tester.tap(_cancelOne);
      await tester.pumpAndSettle();
      expect(await container.read(intentQueue).list(), hasLength(1));

      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();

      expect(find.text('Sign in as ada'), findsOneWidget);
      // Nothing of the account is left on the phone but the device's own node id.
      expect(shop.store.keys('cs/ada/'), isEmpty);

      // The next account to sign in finds no queued decision, no rows and no copy of the orders.
      await tester.tap(find.text('Sign in as ada'));
      await tester.pumpAndSettle();
      expect(
        find.text('Offline: not loaded on this phone yet'),
        findsOneWidget,
      );
      await shop.setNetwork(tester, online: true);
      expect(shop.transport.runs('cancelOrder'), 0);
      expect(find.text('Order 1: Ceramic mug (placed)'), findsOneWidget);
    });
  });
}
