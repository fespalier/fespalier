// The app as `flutter run` builds it: startup()'s wiring over the in-process demo server, with nothing
// scripted. The package's fakes are in the other tests; this one proves the demo behind the example works.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline/app.g.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/wiring.dart';

Future<ProviderContainer> _open(
  WidgetTester tester,
  String location,
) => pumpRouter(
  tester,
  AppRoutes.router(initialLocation: location),
  overrides: [
    localStore.overrideWithValue(InMemoryLocalStore()),
    appResumeSignal.overrideWith(RefetchSignal.new),
    ...appWiring(),
    noteRowSync(),
    // startup() has the app's own timer here; a test fires the tick by hand.
    syncTicker.overrideWith(ManualSyncTicker.new),
  ],
);

Future<void> _flip(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('network-switch')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the orders: a shipped one is refused, another is cancelled once after the wait',
    (tester) async {
      final container = await _open(tester, '/orders');
      final server = container.read(demoServer);
      expect(find.text('Order 3: Cast-iron pan (shipped)'), findsOneWidget);

      await tester.tap(find.text('Cancel order 3'));
      await tester.pumpAndSettle();
      expect(
        find.text('The shop refused: ORDER_ALREADY_SHIPPED'),
        findsOneWidget,
      );

      await _flip(tester); // offline
      await tester.tap(find.text('Cancel order 1'));
      await tester.pumpAndSettle();
      expect(
        find.text('Cancelling, will send when back online'),
        findsOneWidget,
      );
      expect(server.runs('cancelOrder'), 0);

      await _flip(
        tester,
      ); // online again: the reconnect trigger drains the queue

      expect(server.runs('cancelOrder'), 1);
      expect(find.text('Order 1: Ceramic mug (cancelled)'), findsOneWidget);
      expect(find.textContaining('waiting to send'), findsNothing);
      expect(find.textContaining('Offline copy'), findsNothing);
    },
  );

  testWidgets(
    'a note: this phone and another edit different fields offline, and both edits survive',
    (tester) async {
      await _open(tester, '/notes/n1');
      expect(
        find.text('On this phone: Groceries / Milk, eggs'),
        findsOneWidget,
      );

      await _flip(tester); // offline
      await tester.enterText(
        find.widgetWithText(TextField, 'Body'),
        'Milk, eggs, tea',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting to sync'), findsOneWidget);

      // The other phone renames the note on the server, with a later stamp.
      await tester.pump(const Duration(minutes: 1));
      await tester.tap(find.text('Rename on the other phone'));
      await tester.pumpAndSettle();

      await _flip(tester); // online again: push the body, pull the title

      expect(
        find.text(
          'On this phone: Groceries (renamed elsewhere) / Milk, eggs, tea',
        ),
        findsOneWidget,
      );
      expect(find.text('Waiting to sync'), findsNothing);
    },
  );

  testWidgets(
    'a title the server refuses is undone on the phone, and the banner says so',
    (tester) async {
      await _open(tester, '/notes/n1');
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'x' * (maxTitle + 1),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('The server undid 1 edit (TITLE_TOO_LONG)'),
        findsOneWidget,
      );
      expect(
        find.text('On this phone: Groceries / Milk, eggs'),
        findsOneWidget,
      );
    },
  );
}
