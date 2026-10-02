// `TypedLocation.pushReplacement`: the top page leaves and a new one is pushed.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ItemLoc extends TypedLocation {
  const ItemLoc(this.id);
  final int id;
  @override
  String get location => '/items/$id';
  @override
  String locationFor(String? locale) =>
      locale == 'fr' ? '/articles/$id' : location;
}

GoRouter makeRouter() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('Home')),
    GoRoute(
      path: '/items/:id',
      builder: (_, s) => Text('Item ${s.pathParameters['id']}'),
    ),
    GoRoute(
      path: '/articles/:id',
      builder: (_, s) => Text('Article ${s.pathParameters['id']}'),
    ),
    GoRoute(path: '/extra', builder: (_, s) => Text('extra=${s.extra}')),
  ],
);

BuildContext top(WidgetTester tester) => tester.element(find.byType(Text).last);

void main() {
  group('pushReplacement', () {
    testWidgets('swaps the pushed page and keeps the stack below it', (
      tester,
    ) async {
      final router = makeRouter();
      await pumpRouter(tester, router);
      unawaited(const ItemLoc(1).push<void>(top(tester)));
      await tester.pumpAndSettle();
      expect(find.text('Item 1'), findsOneWidget);

      unawaited(const ItemLoc(2).pushReplacement<void>(top(tester)));
      await tester.pumpAndSettle();
      expect(find.text('Item 2'), findsOneWidget);
      expect(find.text('Item 1'), findsNothing);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('the replaced page completes with what the new one pops with', (
      tester,
    ) async {
      final router = makeRouter();
      await pumpRouter(tester, router);
      unawaited(const ItemLoc(1).push<String>(top(tester)));
      await tester.pumpAndSettle();

      final second = const ItemLoc(2).pushReplacement<int>(top(tester));
      await tester.pumpAndSettle();
      router.pop(7);
      await tester.pumpAndSettle();

      expect(await second, 7);
    });

    testWidgets('takes the locale', (tester) async {
      final router = makeRouter();
      await pumpRouter(tester, router);
      unawaited(const ItemLoc(1).push<void>(top(tester)));
      await tester.pumpAndSettle();

      unawaited(
        const ItemLoc(3).pushReplacement<void>(top(tester), locale: 'fr'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Article 3'), findsOneWidget);
    });
  });
}
