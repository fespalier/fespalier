// `Remount`: a page keeps its widget state when only its URL parameters change, because
// go_router keys it by its path template. A folder's route.dart (`const remount = ...`) says
// when it is a new page instead: `never` (the default) keeps it, `onSegments` starts again
// when a segment changes but not when the query does, `onLocation` on any change. The pages
// here count presses in a hook; the count is the state.
import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Future<GoRouter> boot(WidgetTester tester, String location) async {
  final router = AppRoutes.router(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
      // nesting both gives Material pages and error screens on either.
      child: MaterialApp(
        home: mui.MaterialApp.router(routerConfig: router),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> go(WidgetTester tester, GoRouter router, String location) async {
  router.go(location);
  await tester.pumpAndSettle();
}

/// Presses the button of the page `n` times.
Future<void> press(WidgetTester tester, [int n = 1]) async {
  for (var i = 0; i < n; i++) {
    await tester.tap(find.byType(TextButton));
    await tester.pump();
  }
}

void main() {
  group('never', () {
    testWidgets('keeps the state when a segment changes', (tester) async {
      final router = await boot(tester, '/remount/never/1');
      await press(tester, 2);
      expect(find.text('never 1, page 1, taps 2'), findsOneWidget);
      await go(tester, router, '/remount/never/2');
      expect(find.text('never 2, page 1, taps 2'), findsOneWidget);
    });

    testWidgets('keeps the state when the query changes', (tester) async {
      final router = await boot(tester, '/remount/never/1');
      await press(tester);
      await go(tester, router, '/remount/never/1?page=2');
      expect(find.text('never 1, page 2, taps 1'), findsOneWidget);
    });
  });

  group('onSegments', () {
    testWidgets('starts again when a segment changes', (tester) async {
      final router = await boot(tester, '/remount/segments/1');
      await press(tester, 2);
      expect(find.text('segments 1, page 1, taps 2'), findsOneWidget);
      await go(tester, router, '/remount/segments/2');
      expect(find.text('segments 2, page 1, taps 0'), findsOneWidget);
    });

    testWidgets('keeps the state when the query changes', (tester) async {
      final router = await boot(tester, '/remount/segments/1');
      await press(tester);
      await go(tester, router, '/remount/segments/1?page=2');
      expect(find.text('segments 1, page 2, taps 1'), findsOneWidget);
      await go(tester, router, '/remount/segments/1?page=3');
      expect(find.text('segments 1, page 3, taps 1'), findsOneWidget);
    });

    testWidgets('keeps the state with the typed route\'s copyWith', (
      tester,
    ) async {
      await boot(tester, '/remount/segments/1');
      await press(tester);
      RemountSegmentsRoute.of(
        tester.element(find.byType(TextButton)),
      ).copyWith(page: 2).go(tester.element(find.byType(TextButton)));
      await tester.pumpAndSettle();
      expect(find.text('segments 1, page 2, taps 1'), findsOneWidget);
    });
  });

  group('onLocation, from the route.dart of remount/', () {
    testWidgets('starts again when a segment changes', (tester) async {
      final router = await boot(tester, '/remount/location/1');
      await press(tester);
      await go(tester, router, '/remount/location/2');
      expect(find.text('location 2, page 1, taps 0'), findsOneWidget);
    });

    testWidgets('starts again when the query changes', (tester) async {
      final router = await boot(tester, '/remount/location/1');
      await press(tester);
      await go(tester, router, '/remount/location/1?page=2');
      expect(find.text('location 1, page 2, taps 0'), findsOneWidget);
    });

    testWidgets('keeps the state when nothing changed', (tester) async {
      final router = await boot(tester, '/remount/location/1?page=2');
      await press(tester);
      await go(tester, router, '/remount/location/1?page=2');
      expect(find.text('location 1, page 2, taps 1'), findsOneWidget);
    });
  });

  testWidgets('a page outside the folders is as it was', (tester) async {
    // /search has no `remount`: its query parameters are read by the same page.
    final router = await boot(tester, '/search?page=1');
    await go(tester, router, '/search?page=2');
    expect(find.textContaining('page 2'), findsOneWidget);
  });
}
