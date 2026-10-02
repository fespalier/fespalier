// The Location tab: where the router is, its parameters, query and extra, and the history.
import 'package:fespalier_devtools/src/ui/chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

void main() {
  testWidgets('shows the location, its route, path and file', (tester) async {
    await pumpApp(tester, FakeFespalierClient());
    expect(find.text('/catalog/p1/reviews?page=2'), findsWidgets);
    expect(find.text('ReviewsRoute'), findsOneWidget);
    expect(find.text('/catalog/:productId/reviews'), findsOneWidget);
    expect(find.text('catalog/\$productId/reviews/page.dart'), findsOneWidget);
  });

  testWidgets(
    'has a row for each typed parameter, with its name, type and value',
    (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      final table = find.byKey(const Key('location-params'));
      expect(table, findsOneWidget);
      // The type is the app's own spelling from the tree (`int?`), not the value's runtime type.
      for (final text in ['productId', 'String', 'p1', 'page', 'int?', '2']) {
        expect(
          find.descendant(of: table, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
    },
  );

  testWidgets('shows the query, each key with its values', (tester) async {
    await pumpApp(tester, FakeFespalierClient());
    expect(find.text('Query'), findsOneWidget);
    expect(find.text('page'), findsWidgets);
  });

  testWidgets('shows the extra with its type', (tester) async {
    await pumpApp(tester, FakeFespalierClient());
    expect(find.text('extra'), findsOneWidget);
    expect(find.text('from-link'), findsOneWidget);
    expect(find.widgetWithText(KindChip, 'String'), findsOneWidget);
  });

  testWidgets('has no extra row when the navigation carried none', (
    tester,
  ) async {
    await pumpApp(
      tester,
      FakeFespalierClient(snapshot: fixture('snapshot_pushed')),
    );
    expect(find.text('extra'), findsNothing);
  });

  testWidgets(
    'says why when no route has the location, and falls back on go_router\'s parameters',
    (tester) async {
      await pumpApp(
        tester,
        FakeFespalierClient(snapshot: fixture('snapshot_not_found')),
      );
      expect(find.byKey(const Key('location-error')), findsOneWidget);
      expect(
        find.text('GoException: no routes for location: /no/such/page'),
        findsOneWidget,
      );
      expect(find.text('/no/such/page'), findsWidgets);
      expect(find.text('Parameters'), findsNothing);
    },
  );

  testWidgets(
    'shows go_router\'s path parameters when the app\'s matcher knows none',
    (tester) async {
      final snapshot = fixture('snapshot_catalog');
      final location = Map<String, Object?>.of(
        snapshot['location']! as Map<String, Object?>,
      )..['params'] = null;
      await pumpApp(
        tester,
        FakeFespalierClient(snapshot: {...snapshot, 'location': location}),
      );
      final table = find.byKey(const Key('location-params'));
      expect(
        find.descendant(of: table, matching: find.text('productId')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: table, matching: find.text('p1')),
        findsOneWidget,
      );
    },
  );

  group('history', () {
    testWidgets(
      'lists the newest first, with a time, a kind chip and the uri',
      (tester) async {
        await pumpApp(tester, FakeFespalierClient());
        final rows = [
          for (final seq in [3, 2, 1])
            tester.getTopLeft(find.byKey(Key('history-$seq'))).dy,
        ];
        expect(rows, orderedEquals([...rows]..sort()));
        expect(find.text(formatClock(1696230002789)), findsOneWidget);
        expect(find.widgetWithText(KindChip, 'initial'), findsOneWidget);
        expect(find.widgetWithText(KindChip, 'go'), findsNWidgets(2));
        final newest = find.byKey(const Key('history-3'));
        expect(
          find.descendant(
            of: newest,
            matching: find.text('/catalog/p1/reviews?page=2'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('marks a navigation that found no route with a red chip', (
      tester,
    ) async {
      await pumpApp(
        tester,
        FakeFespalierClient(snapshot: fixture('snapshot_not_found')),
      );
      final row = find.byKey(const Key('history-2'));
      expect(
        find.descendant(of: row, matching: find.text('not found')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('history-1')),
          matching: find.text('not found'),
        ),
        findsNothing,
      );
    });

    testWidgets('names push, replace and refresh', (tester) async {
      await pumpApp(
        tester,
        FakeFespalierClient(snapshot: fixture('snapshot_pushed')),
      );
      for (final kind in ['initial', 'push', 'replace', 'refresh']) {
        expect(
          find.widgetWithText(KindChip, kind),
          findsOneWidget,
          reason: kind,
        );
      }
    });

    testWidgets('formats the time as hh:mm:ss.mmm', (tester) async {
      expect(
        formatClock(DateTime(2023, 10, 2, 9, 5, 7, 42).millisecondsSinceEpoch),
        '09:05:07.042',
      );
    });
  });
}
