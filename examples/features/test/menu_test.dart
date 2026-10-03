// Menus and breadcrumbs from the nav.dart files: `AppMenu.watch(ref)`, `watch(ref, under:)`
// and `breadcrumbs(ref)`, with guards that decide what is listed.
import 'package:features/app.g.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Boots the app at [location]; the menu is closed.
Future<ProviderContainer> boot(
  WidgetTester tester,
  String location, {
  Locale? locale,
  bool signedIn = false,
}) async {
  final container = ProviderContainer(retry: (count, error) => null);
  addTearDown(container.dispose);
  if (signedIn) container.read(session.notifier).set(true);
  final router = AppRoutes.router(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        // The language of the app, as a MaterialApp with the localizations of the app's
        // own would set it; label() reads it from the context.
        builder: (context, child) => locale == null
            ? child!
            : Localizations.override(
                context: context,
                locale: locale,
                child: child,
              ),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Opens (or closes) the menu with its button: one frame, nothing more.
Future<void> toggleMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pump();
}

Finder entry(String label) => find.widgetWithText(ListTile, label);

bool enabled(WidgetTester tester, String label) =>
    tester.widget<ListTile>(entry(label)).enabled;

String crumbs(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('breadcrumbs'))).data!;

void main() {
  group('the menu from the tree', () {
    testWidgets('lists the entries that need no segment, in order', (
      tester,
    ) async {
      await boot(tester, '/');
      expect(entry('Home'), findsNothing); // closed: nothing is built
      await toggleMenu(tester);
      // order: Home 0, Search 1, Inbox 2, Vault 5. Order and Team need their segments, and
      // (members)/guard.dart refuses Admin. Vault's guard is asynchronous: it is listed until it
      // answers.
      List<String?> tiles() => tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(tiles(), ['Home', 'Search', 'Inbox', 'Vault']);
      expect(tester.widget<ListTile>(entry('Home')).selected, isTrue);
      expect(tester.widget<ListTile>(entry('Search')).selected, isFalse);
      await tester.pumpAndSettle();
      expect(
          tiles(), ['Home', 'Search', 'Inbox']); // signed out: Vault is refused
    });

    testWidgets('selects the entry of the page, and goes to the others', (
      tester,
    ) async {
      await boot(tester, '/search');
      await toggleMenu(tester);
      expect(tester.widget<ListTile>(entry('Search')).selected, isTrue);
      expect(tester.widget<ListTile>(entry('Home')).selected, isFalse);
      await tester.tap(entry('Home'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/');
    });

    testWidgets('a heading and the entries below it need their segment', (
      tester,
    ) async {
      await boot(tester, '/teams/t1/members');
      await toggleMenu(tester);
      // The heading's label() makes it the team's; Members and Settings are nested in it.
      expect(entry('Team T1'), findsOneWidget);
      expect(tester.widget<ListTile>(entry('Team T1')).selected, isTrue);
      expect(entry('Team T1').hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(entry('Members')).selected, isTrue);
      expect(tester.widget<ListTile>(entry('Settings')).selected, isFalse);
      // Order's entry is `inMenu: false`: never listed.
      expect(entry('Order #7'), findsNothing);
      await tester.pumpAndSettle(); // Vault's guard is out
    });

    testWidgets('a menu of one folder: the team\'s, with its segment', (
      tester,
    ) async {
      await boot(tester, '/teams/t1/members');
      expect(find.widgetWithText(OutlinedButton, 'Members'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Settings'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/teams/t1/settings');
      expect(find.text('Settings of T1'), findsOneWidget);
    });
  });

  group('guards', () {
    testWidgets('a sync guard decides in the first frame: hidden, or off', (
      tester,
    ) async {
      await boot(tester, '/');
      await toggleMenu(tester);
      // One frame after the tap: the sync guards have answered (Admin is out, Inbox is
      // off), and the only entry pending is the one with an async guard.
      expect(entry('Admin'), findsNothing);
      expect(enabled(tester, 'Inbox'), isFalse);
      expect(find.text('checking…'), findsOneWidget);
      expect(
          find.descendant(of: entry('Vault'), matching: find.text('checking…')),
          findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('and follows what it watches, with no navigation', (
      tester,
    ) async {
      final c = await boot(tester, '/');
      await toggleMenu(tester);
      expect(enabled(tester, 'Inbox'), isFalse);
      c.read(session.notifier).set(true);
      await tester.pump();
      expect(enabled(tester, 'Inbox'), isTrue);
      expect(currentLocation(tester), '/');
      c.read(session.notifier).set(false);
      await tester.pump();
      expect(enabled(tester, 'Inbox'), isFalse);
      await tester.pumpAndSettle(); // the async guard asked meanwhile
    });

    testWidgets('a ProviderContainer guard is read once per menu', (
      tester,
    ) async {
      final c = await boot(tester, '/', signedIn: true);
      await toggleMenu(tester);
      expect(entry('Admin'), findsNothing);
      c.read(isAdmin.notifier).set(true);
      await tester.pump();
      // The older form of guard is read when the entry is asked, as a navigation does.
      expect(entry('Admin'), findsNothing);
      await toggleMenu(tester);
      await toggleMenu(tester);
      expect(entry('Admin'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('an async guard starts pending: listed, on, then answered', (
      tester,
    ) async {
      await boot(tester, '/', signedIn: true);
      await toggleMenu(tester);
      expect(entry('Vault'), findsOneWidget);
      expect(enabled(tester, 'Vault'), isTrue);
      expect(find.text('checking…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();
      expect(entry('Vault'), findsOneWidget);
      expect(find.text('checking…'), findsNothing);
    });

    testWidgets('an async refusal takes the entry out once it is in', (
      tester,
    ) async {
      await boot(tester, '/');
      await toggleMenu(tester);
      expect(entry('Vault'), findsOneWidget);
      expect(find.text('checking…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();
      expect(entry('Vault'), findsNothing);
    });
  });

  group('breadcrumbs', () {
    testWidgets('on a nested route: every folder with a nav.dart above', (
      tester,
    ) async {
      await boot(tester, '/orders/7/refund');
      expect(crumbs(tester), 'Home › Order #7 › Refund');
    });

    testWidgets('are not shown where only the app folder covers the page', (
      tester,
    ) async {
      await boot(tester, '/');
      expect(find.byKey(const Key('breadcrumbs')), findsNothing);
      await boot(tester, '/login');
      expect(find.byKey(const Key('breadcrumbs')), findsNothing);
    });

    testWidgets('follow the navigation', (tester) async {
      await boot(tester, '/orders/7');
      expect(crumbs(tester), 'Home › Order #7');
      await tester.tap(find.text('Request a refund'));
      await tester.pumpAndSettle();
      expect(crumbs(tester), 'Home › Order #7 › Refund');
    });
  });

  group('localized labels', () {
    testWidgets('label() gets the BuildContext: the app\'s language', (
      tester,
    ) async {
      await boot(tester, '/search');
      expect(crumbs(tester), 'Home › Search');
      await toggleMenu(tester);
      expect(entry('Search'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('French', (tester) async {
      await boot(tester, '/search', locale: const Locale('fr'));
      expect(crumbs(tester), 'Home › Recherche');
      await toggleMenu(tester);
      expect(entry('Recherche'), findsOneWidget);
      expect(entry('Search'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('Nav.label is what is left without a label()', (tester) async {
      await boot(tester, '/', locale: const Locale('fr'), signedIn: true);
      await toggleMenu(tester);
      expect(entry('Inbox'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
