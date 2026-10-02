// DevTools' panel can be narrow (a docked tab, a small window): no tab may overflow in it.
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:fespalier_devtools/src/ui/fespalier_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

void main() {
  for (final width in [300.0, 420.0, 800.0]) {
    for (final snapshot in [
      'snapshot_catalog',
      'snapshot_pushed',
      'snapshot_not_found',
    ]) {
      testWidgets('nothing overflows at $width wide, with $snapshot', (
        tester,
      ) async {
        final client = FakeFespalierClient(
          snapshot: fixture(snapshot),
          handlers: {
            DevToolsMethods.match: (_) => const MatchRecord(
              location: '/catalog/p1/reviews?page=2',
              route: 'ReviewsRoute',
              params: {
                'productId': Shown('String', 'p1'),
                'page': Shown('int', '2'),
              },
            ).toJson(),
          },
        );
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(home: FespalierApp(client: client)),
        );
        await settle(tester);
        await tester.enterText(
          find.byKey(const Key('goto-location')),
          '/catalog/p1/reviews?page=2',
        );
        await tester.tap(find.byKey(const Key('goto-match')));
        await settle(tester);
        await openTab(tester, 'Stack');
        await openTab(tester, 'Routes');
        await tester.enterText(
          find.byKey(const Key('routes-filter')),
          'review',
        );
        await tester.pump();
        await tester.tap(find.textContaining('ReviewsRoute').first);
        await tester.pump();
        await openTab(tester, 'Location');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
