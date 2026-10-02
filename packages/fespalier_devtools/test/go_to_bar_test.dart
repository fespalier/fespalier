// The go-to bar: a location, a way to go, pop, and match.
import 'package:fespalier_devtools/src/client.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

Future<void> typeLocation(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('goto-location')), text);
  await tester.pump();
}

void main() {
  testWidgets('Enter goes to the location', (tester) async {
    final client = FakeFespalierClient();
    await pumpApp(tester, client);
    await typeLocation(tester, '/products/2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(client.callsTo(DevToolsMethods.navigate), [
      {'mode': 'go', 'location': '/products/2'},
    ]);
  });

  testWidgets('the Go button goes, the dropdown makes it push or replace', (
    tester,
  ) async {
    final client = FakeFespalierClient();
    await pumpApp(tester, client);
    await typeLocation(tester, '/cart');
    await tester.tap(find.byKey(const Key('goto-go')));
    await settle(tester);
    for (final mode in [NavigateMode.push, NavigateMode.replace]) {
      await tester.tap(find.byKey(const Key('goto-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(mode).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goto-go')));
      await settle(tester);
    }
    expect(client.callsTo(DevToolsMethods.navigate), [
      {'mode': 'go', 'location': '/cart'},
      {'mode': 'push', 'location': '/cart'},
      {'mode': 'replace', 'location': '/cart'},
    ]);
  });

  testWidgets('an empty location goes nowhere', (tester) async {
    final client = FakeFespalierClient();
    await pumpApp(tester, client);
    await tester.tap(find.byKey(const Key('goto-go')));
    await tester.tap(find.byKey(const Key('goto-match')));
    await settle(tester);
    expect(client.callsTo(DevToolsMethods.navigate), isEmpty);
    expect(client.callsTo(DevToolsMethods.match), isEmpty);
  });

  testWidgets('Pop pops, with no location', (tester) async {
    final client = FakeFespalierClient();
    await pumpApp(tester, client);
    await tester.tap(find.byKey(const Key('goto-pop')));
    await settle(tester);
    expect(client.callsTo(DevToolsMethods.navigate), [
      {'mode': 'pop'},
    ]);
  });

  group('Match', () {
    testWidgets('shows the route, its file and the typed parameters', (
      tester,
    ) async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.match: (params) => const MatchRecord(
            location: '/catalog/p1/reviews?page=2',
            route: 'ReviewsRoute',
            params: {
              'productId': Shown('String', 'p1'),
              'page': Shown('int', '2'),
            },
            data: 3,
          ).toJson(),
        },
      );
      await pumpApp(tester, client);
      await typeLocation(tester, '/catalog/p1/reviews?page=2');
      await tester.tap(find.byKey(const Key('goto-match')));
      await settle(tester);
      expect(
        find.text(
          'ReviewsRoute · catalog/\$productId/reviews/page.dart · '
          'productId: p1 (String), page: 2 (int?)',
        ),
        findsOneWidget,
      );
      expect(client.callsTo(DevToolsMethods.match), [
        {'location': '/catalog/p1/reviews?page=2'},
      ]);
      // It matched; it did not navigate.
      expect(client.callsTo(DevToolsMethods.navigate), isEmpty);
    });

    testWidgets('says so when no route matches', (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      await typeLocation(tester, '/nowhere');
      await tester.tap(find.byKey(const Key('goto-match')));
      await settle(tester);
      expect(find.text('no route matches (not found)'), findsOneWidget);
    });

    testWidgets('names a route without parameters by its file alone', (
      tester,
    ) async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.match: (params) => const MatchRecord(
            location: '/login',
            route: 'LoginRoute',
          ).toJson(),
        },
      );
      await pumpApp(tester, client);
      await typeLocation(tester, '/login');
      await tester.tap(find.byKey(const Key('goto-match')));
      await settle(tester);
      expect(find.text('LoginRoute · login/page.dart'), findsOneWidget);
    });

    testWidgets('is not debounced: it runs on the button, not as you type', (
      tester,
    ) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      await typeLocation(tester, '/c');
      await typeLocation(tester, '/ca');
      await typeLocation(tester, '/cat');
      expect(client.callsTo(DevToolsMethods.match), isEmpty);
    });
  });

  testWidgets('shows what the app said when it refuses', (tester) async {
    final client = FakeFespalierClient(
      handlers: {
        DevToolsMethods.navigate: (_) =>
            throw const FespalierError('missing parameter `location`'),
      },
    );
    await pumpApp(tester, client);
    await typeLocation(tester, '/x');
    await tester.tap(find.byKey(const Key('goto-go')));
    await settle(tester);
    expect(find.byKey(const Key('goto-error')), findsOneWidget);
    expect(find.text('missing parameter `location`'), findsOneWidget);
  });
}
