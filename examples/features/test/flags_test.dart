// /labs behind a feature flag (fespalier_flags): the guard in lib/app/labs/guard.dart is the only
// place that knows about the flag, and the menu entry follows it because menus run guards.
import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_flags/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Boots the app at [location] with [flags] as the flag source; the menu is closed.
Future<ProviderContainer> boot(
  WidgetTester tester,
  String location,
  FakeFlags flags,
) async {
  final container = ProviderContainer(
    overrides: [flagSource.overrideWithValue(flags)],
    retry: (count, error) => null,
  );
  addTearDown(container.dispose);
  final router = AppRoutes.router(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> toggleMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pump();
}

Finder entry(String label) => find.widgetWithText(ListTile, label);

void main() {
  group('with the flag off', () {
    testWidgets('the menu has no Labs entry', (tester) async {
      await boot(tester, '/', FakeFlags());
      await toggleMenu(tester);
      expect(entry('Home'), findsOneWidget);
      expect(entry('Labs'), findsNothing);
      await tester.pumpAndSettle(); // Vault's guard is out
    });

    testWidgets('a deep link to /labs lands on /, in the first frame', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [flagSource.overrideWithValue(FakeFlags())],
        retry: (count, error) => null,
      );
      addTearDown(container.dispose);
      final router = AppRoutes.router(initialLocation: '/labs');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      // One frame, nothing settled: the guard answered synchronously.
      expect(currentLocation(tester), '/');
      expect(find.text('Labs'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets(
        'startup.dart without a define leaves it off: the default is the fallback',
        (
      tester,
    ) async {
      final container = ProviderContainer(retry: (count, error) => null);
      addTearDown(container.dispose);
      final router = AppRoutes.router(initialLocation: '/labs');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/');
    });
  });

  group('with the flag on', () {
    testWidgets('the entry is listed, and opens /labs', (tester) async {
      await boot(tester, '/', FakeFlags({'labs': true}));
      await toggleMenu(tester);
      expect(entry('Labs'), findsOneWidget);
      await tester.tap(entry('Labs'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/labs');
      expect(find.text('Labs'), findsWidgets);
    });

    testWidgets('a deep link opens the page', (tester) async {
      await boot(tester, '/labs', FakeFlags({'labs': true}));
      expect(currentLocation(tester), '/labs');
    });
  });

  group('the flag changes while the app runs', () {
    testWidgets(
        'turned on with the menu open: listed after one pump, the location unchanged',
        (
      tester,
    ) async {
      final flags = FakeFlags();
      await boot(tester, '/search', flags);
      await toggleMenu(tester);
      expect(entry('Labs'), findsNothing);
      flags.set('labs', true);
      await tester.pump();
      expect(entry('Labs'), findsOneWidget);
      expect(currentLocation(tester), '/search');
      flags.set('labs', false);
      await tester.pump();
      expect(entry('Labs'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('turned off on /labs: the app is on / after one pump', (
      tester,
    ) async {
      final flags = FakeFlags({'labs': true});
      await boot(tester, '/labs', flags);
      expect(currentLocation(tester), '/labs');
      flags.set('labs', false);
      await tester.pump();
      expect(currentLocation(tester), '/');
      await tester.pumpAndSettle(); // the page leaves with its transition
      expect(find.text('Labs'), findsNothing);
    });

    testWidgets('a flag a widget watches rebuilds it', (tester) async {
      final flags = FakeFlags();
      final container = ProviderContainer(
        overrides: [flagSource.overrideWithValue(flags)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, _) =>
                  Text(ref.watch(flag(const BoolFlag('labs'))) ? 'on' : 'off'),
            ),
          ),
        ),
      );
      expect(find.text('off'), findsOneWidget);
      flags.set('labs', true);
      await tester.pump();
      expect(find.text('on'), findsOneWidget);
    });
  });
}
