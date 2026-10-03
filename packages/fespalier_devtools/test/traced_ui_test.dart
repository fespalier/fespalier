// What the guards, data and actions add to the other parts of the UI: the guards behind a history
// row, Open in IDE on the Routes tab, the clear menu, and the new tabs in a narrow panel.
import 'package:fespalier_devtools/src/client.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:fespalier_devtools/src/ui/fespalier_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';
import 'trace_fixtures.dart';

NavigationRecord navigation(
  int seq,
  String uri, {
  List<int> guards = const [],
}) => NavigationRecord(
  seq: seq,
  at: 1696230000000 + seq * 1000,
  kind: NavigationKind.go,
  uri: uri,
  fullPath: uri,
  depth: 0,
  guards: guards,
);

Finder row(String route, String pattern) =>
    find.byKey(Key('route-$route-$pattern'));

void main() {
  group('history', () {
    testWidgets('a navigation with guards has a badge that opens them', (
      tester,
    ) async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(
          guards: [
            guardRecord(
              10,
              result: GuardOutcome.redirect,
              location: '/login?from=%2Fadmin',
            ),
            guardRecord(11, site: 'r33', uri: '/login?from=%2Fadmin'),
          ],
          history: [
            navigation(1, '/'),
            navigation(2, '/login?from=%2Fadmin', guards: [10, 11]),
          ],
        ),
      );
      await pumpApp(tester, client);
      expect(find.byKey(const Key('history-guards-1')), findsNothing);
      final badge = find.byKey(const Key('history-guards-2'));
      expect(badge, findsOneWidget);
      expect(find.textContaining('2 guards'), findsOneWidget);
      expect(find.byKey(const Key('history-guards-list-2')), findsNothing);
      await tester.tap(badge);
      await tester.pump();
      final list = find.byKey(const Key('history-guards-list-2'));
      expect(list, findsOneWidget);
      // Both decisions of the chain, each with its file and result.
      expect(
        find.descendant(of: list, matching: find.byKey(const Key('guard-10'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('(members)/guard.dart')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: list,
          matching: find.text('old-search/redirect.dart'),
        ),
        findsOneWidget,
      );
      await tester.tap(badge);
      await tester.pump();
      expect(list, findsNothing);
    });

    testWidgets('says a guard is no longer kept when the app dropped it', (
      tester,
    ) async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(
          history: [
            navigation(2, '/x', guards: [3]),
          ],
        ),
      );
      await pumpApp(tester, client);
      expect(find.textContaining('1 guard'), findsOneWidget);
      expect(find.textContaining('1 guards'), findsNothing);
      await tester.tap(find.byKey(const Key('history-guards-2')));
      await tester.pump();
      expect(find.text('guard #3 is no longer kept'), findsOneWidget);
    });
  });

  group('Open in IDE', () {
    Future<void> select(
      WidgetTester tester,
      String route,
      String pattern,
    ) async {
      await tester.enterText(find.byKey(const Key('routes-filter')), route);
      await tester.pump();
      await tester.tap(row(route, pattern));
      await tester.pump();
    }

    testWidgets('asks the app to open the route\'s file', (tester) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      await openTab(tester, 'Routes');
      await select(tester, 'ProductDetailRoute', '/catalog/:productId');
      await tester.tap(find.byKey(const Key('open-in-ide')));
      await settle(tester);
      expect(client.callsTo(DevToolsMethods.open), [
        {'file': r'catalog/$productId/page.dart'},
      ]);
    });

    testWidgets('a site has a button of its own for its file', (tester) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      await openTab(tester, 'Routes');
      await select(tester, 'RefundRoute', '/orders/:id/refund');
      final button = find.byKey(const Key('open-site-g38@38'));
      // The details pane scrolls on its own.
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await settle(tester);
      expect(client.callsTo(DevToolsMethods.open), [
        {'file': r'orders/$id/refund/guard.dart'},
      ]);
    });

    testWidgets('says what the app said when it cannot', (tester) async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.open: (_) => throw const FespalierError(
            'the app folder is not a folder of a package under lib/',
          ),
        },
      );
      await pumpApp(tester, client);
      await openTab(tester, 'Routes');
      await select(tester, 'LoginRoute', '/login');
      await tester.tap(find.byKey(const Key('open-in-ide')));
      await settle(tester);
      expect(find.textContaining('under lib/'), findsOneWidget);
    });

    testWidgets('is not offered by an app that does not list open', (
      tester,
    ) async {
      await pumpApp(tester, FakeFespalierClient(features: firstFeatures));
      await openTab(tester, 'Routes');
      await select(tester, 'LoginRoute', '/login');
      expect(find.byKey(const Key('route-details')), findsOneWidget);
      expect(find.byKey(const Key('open-in-ide')), findsNothing);
    });

    testWidgets('is not offered when the tree has no package name', (
      tester,
    ) async {
      final tree = {...featuresTree()}..remove('package');
      await pumpApp(tester, FakeFespalierClient(tree: tree));
      await openTab(tester, 'Routes');
      await select(tester, 'LoginRoute', '/login');
      expect(find.byKey(const Key('route-details')), findsOneWidget);
      expect(find.byKey(const Key('open-in-ide')), findsNothing);
    });
  });

  group('clear menu', () {
    testWidgets('has guards and actions too', (tester) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      for (final item in ['Clear guards', 'Clear actions']) {
        await tester.tap(find.byKey(const Key('clear-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await settle(tester);
      }
      expect(client.callsTo(DevToolsMethods.clear), [
        {'what': 'guards'},
        {'what': 'actions'},
      ]);
    });
  });

  for (final width in [300.0, 420.0, 800.0]) {
    testWidgets('the new tabs do not overflow at $width wide', (tester) async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(
          guards: [
            guardRecord(
              1,
              uri: '/a/very/long/location/that/goes/on?and=on&and=on',
              result: GuardOutcome.redirect,
              location: '/login?from=%2Fa%2Fvery%2Flong%2Flocation',
              isAsync: true,
              ms: 120,
            ),
            guardRecord(
              2,
              result: GuardOutcome.error,
              error: 'a long error text ' * 6,
            ),
          ],
          data: [
            dataRecord(1, value: Shown('Refund', 'a long value ' * 12)),
            dataRecord(
              2,
              state: DataState.error,
              value: null,
              error: 'x' * 120,
            ),
          ],
          actions: [
            actionRecord(
              1,
              input: Shown('RefundInput', 'a long input ' * 12),
              error: null,
            ),
          ],
          history: [
            navigation(1, '/', guards: [1, 2]),
          ],
        ),
      );
      tester.view.physicalSize = Size(width, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: FespalierApp(client: client)));
      await settle(tester);
      final badge = find.byKey(const Key('history-guards-1'));
      await tester.ensureVisible(badge);
      await tester.tap(badge);
      await tester.pump();
      await openTab(tester, 'Guards');
      await openTab(tester, 'Data');
      await openTab(tester, 'Actions');
      await openTab(tester, 'Routes');
      await tester.enterText(find.byKey(const Key('routes-filter')), 'refund');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('route-RefundRoute-/orders/:id/refund')),
      );
      await tester.pump();
      // A route with a Go button as well as Open in IDE.
      await tester.enterText(find.byKey(const Key('routes-filter')), 'login');
      await tester.pump();
      await tester.tap(find.byKey(const Key('route-LoginRoute-/login')));
      await tester.pump();
      expect(find.byKey(const Key('open-in-ide')), findsOneWidget);
      expect(find.byKey(const Key('route-go')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
