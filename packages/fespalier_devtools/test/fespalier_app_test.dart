// The screen: the status line in each of its states, the tabs, the header's buttons.
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

void main() {
  group('status', () {
    testWidgets('says what it is waiting for', (tester) async {
      final client = FakeFespalierClient();
      client.connected.value = false;
      await pumpApp(tester, client);
      expect(find.text('Waiting for the app…'), findsWidgets);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(const Key('goto-location')), findsNothing);
    });

    testWidgets(
      'says the app has no fespalier 0.7.0 or later, or is a release build',
      (tester) async {
        final client = FakeFespalierClient();
        client.hasFespalier.value = false;
        await pumpApp(tester, client);
        expect(
          find.text(
            'This app does not use fespalier 0.7.0 or later, or runs in release mode',
          ),
          findsWidgets,
        );
        expect(find.byType(TabBar), findsNothing);
      },
    );

    testWidgets('says which protocol the app speaks', (tester) async {
      await pumpApp(tester, FakeFespalierClient(protocol: 2));
      expect(
        find.text('The app speaks protocol 2; this extension speaks 1'),
        findsWidgets,
      );
    });

    testWidgets('says no router is attached, and how to attach one', (
      tester,
    ) async {
      await pumpApp(
        tester,
        FakeFespalierClient(
          attached: false,
          snapshot: {
            ...fixture('snapshot_catalog'),
            'attached': false,
            'location': null,
            'stack': <Object?>[],
          },
        ),
      );
      expect(
        find.text(
          'fespalier is loaded but no router is attached: '
          'call devToolsAttach(router) if you mount() into your own GoRouter',
        ),
        findsWidgets,
      );
      // The tree is there, so the Routes tab still works; there is nowhere to go, so no go-to bar.
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byKey(const Key('goto-location')), findsNothing);
    });

    testWidgets('says the app has not mounted its routes', (tester) async {
      await pumpApp(tester, FakeFespalierClient(registered: false));
      expect(
        find.text(
          'fespalier is loaded, but the app has not mounted its routes yet',
        ),
        findsWidgets,
      );
    });

    testWidgets('says what failed, and retries', (tester) async {
      var failing = true;
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.snapshot: (_) {
            if (failing) throw StateError('the VM went away');
            return fixture('snapshot_catalog');
          },
        },
      );
      await pumpApp(tester, client);
      expect(
        find.text('Could not read the app: Bad state: the VM went away'),
        findsWidgets,
      );
      failing = false;
      await tester.tap(find.byKey(const Key('retry')));
      await settle(tester);
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets(
      'has the app, protocol, folder and router in the line when all is well',
      (tester) async {
        await pumpApp(tester, FakeFespalierClient());
        expect(
          find.text('fespalier · protocol 1 · lib/app · router attached'),
          findsOneWidget,
        );
      },
    );

    testWidgets('goes from waiting to ready when the app appears', (
      tester,
    ) async {
      final client = FakeFespalierClient();
      client.connected.value = false;
      await pumpApp(tester, client);
      client.connected.value = true;
      await settle(tester);
      expect(find.byType(TabBar), findsOneWidget);
    });
  });

  group('tabs', () {
    testWidgets('are Location, Stack, Routes, Guards, Data and Actions', (
      tester,
    ) async {
      await pumpApp(tester, FakeFespalierClient());
      for (final name in [
        'Location',
        'Stack',
        'Routes',
        'Guards',
        'Data',
        'Actions',
      ]) {
        expect(find.widgetWithText(Tab, name), findsOneWidget, reason: name);
      }
      expect(find.byType(Tab), findsNWidgets(6));
    });

    testWidgets('switch between the panels', (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      expect(find.text('History'), findsOneWidget);
      await openTab(tester, 'Routes');
      expect(find.byKey(const Key('routes-filter')), findsOneWidget);
      await openTab(tester, 'Stack');
      expect(find.text('shell'), findsOneWidget);
    });
  });

  group('header', () {
    testWidgets('refresh fetches the tree and the snapshot again', (
      tester,
    ) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      client.calls.clear();
      await tester.tap(find.byKey(const Key('refresh')));
      await settle(tester);
      expect(client.calls.map((c) => c.$1), [
        DevToolsMethods.hello,
        DevToolsMethods.tree,
        DevToolsMethods.snapshot,
      ]);
    });

    testWidgets('clear history and clear all ask the app', (tester) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      await tester.tap(find.byKey(const Key('clear-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear history'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('clear-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear all'));
      await settle(tester);
      expect(client.callsTo(DevToolsMethods.clear), [
        {'what': 'history'},
        {'what': 'all'},
      ]);
    });
  });

  group('cost', () {
    testWidgets('no timer and no frame is left once everything has arrived', (
      tester,
    ) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      expect(tester.binding.hasScheduledFrame, isFalse);
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(
          8,
          const NavigationRecord(
            seq: 4,
            at: 1696230004000,
            kind: NavigationKind.go,
            uri: '/x',
            fullPath: '/x',
            depth: 0,
          ),
        ),
      );
      await settle(tester);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a navigation event shows in the history without a refresh', (
      tester,
    ) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      client.snapshot = fixture('snapshot_pushed');
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(
          12,
          const NavigationRecord(
            seq: 11,
            at: 1696230003000,
            kind: NavigationKind.refresh,
            uri: '/orders/5',
            fullPath: '/orders/:id',
            depth: 1,
          ),
        ),
      );
      await settle(tester);
      expect(find.text('/orders/5'), findsWidgets);
      expect(find.text('push'), findsOneWidget);
    });
  });
}
