import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> boot(WidgetTester tester, String location) async {
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, __) => null,
      child: MaterialApp.router(
        routerConfig: AppRoutes.router(initialLocation: location),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('layouts and pages get the segments they ask for',
      (tester) async {
    await boot(tester, '/shops/acme');
    expect(find.text('Shop: acme'), findsOneWidget);
    expect(find.text('Welcome to acme'), findsOneWidget);
  });

  testWidgets('guards get segments', (tester) async {
    await boot(tester, '/shops/closed');
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('data keyed by two segments, bound to the page by type',
      (tester) async {
    await boot(tester, '/shops/acme/items/7');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Shop: acme'), findsOneWidget);
    expect(find.text('Item acme #7'), findsOneWidget);
    expect(
        const ItemRoute(shop: 'a b', id: 7).location, '/shops/a%20b/items/7');
  });

  testWidgets('error.dart bound by type; retry re-runs data.dart',
      (tester) async {
    await boot(tester, '/shops/acme/items/0');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Failed: Bad state: no item 0'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Failed:'), findsOneWidget);
  });

  testWidgets('an int segment that does not parse is not found',
      (tester) async {
    await boot(tester, '/shops/acme/items/x');
    expect(find.text('Nothing at /shops/acme/items/x'), findsOneWidget);
  });

  testWidgets('a user-written AsyncNotifierProvider, exposed on the route',
      (tester) async {
    await boot(tester, '/counter');
    await tester.pump();
    expect(find.text('Count 0'), findsOneWidget);
    await tester.tap(find.text('Count 0'));
    await tester.pump();
    expect(find.text('Count 1'), findsOneWidget);
  });

  testWidgets('Stream data', (tester) async {
    await boot(tester, '/ticks');
    await tester.pump();
    expect(find.text('Tick 42'), findsOneWidget);
  });
}
