import 'package:features/app.g.dart';
import 'package:features/app/(members)/inbox/page.dart';
import 'package:features/app/login/page.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Future<ProviderContainer> boot(WidgetTester tester, String location) async {
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
      // nesting both gives Material pages and error screens on either.
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: AppRoutes.router(initialLocation: location),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
}

void main() {
  group('a guard in a (group) without a page', () {
    testWidgets('sends a deep link to login and back again', (tester) async {
      await boot(tester, '/inbox?folder=sent');
      expect(find.byType(InboxPage), findsNothing);
      // `uri` is the whole location, query included.
      expect(find.text('Log in to see /inbox?folder=sent'), findsOneWidget);

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Inbox: sent'), findsOneWidget);
    });

    testWidgets('lets signed-in people straight through', (tester) async {
      final c = await boot(tester, '/');
      c.read(session.notifier).set(true);
      const InboxRoute().go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(find.text('Inbox: all'), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);
    });

    testWidgets('guards navigation inside the app, not only deep links', (
      tester,
    ) async {
      final c = await boot(tester, '/');
      c.read(session.notifier).set(true);
      const InboxRoute().go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      const InboxRoute(folder: 'x').go(tester.element(find.byType(Scaffold)));
      await tester.pumpAndSettle();
      expect(find.text('Log in to see /inbox?folder=x'), findsOneWidget);
    });

    testWidgets('unrelated routes are not guarded', (tester) async {
      await boot(tester, '/search');
      expect(find.byType(LoginPage), findsNothing);
      await boot(tester, '/login');
      expect(find.text('Log in'), findsOneWidget);
    });
  });

  group('inherited guards run outermost first', () {
    testWidgets('the group guard sends you to login before the folder guard', (
      tester,
    ) async {
      final c = await boot(tester, '/admin');
      // (members)/guard.dart wins over admin/guard.dart, which would say /inbox.
      expect(find.text('Log in to see /admin'), findsOneWidget);

      // Signed in, the folder's own guard is next: not an admin.
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Inbox: all'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget); // the button, not the page

      c.read(isAdmin.notifier).set(true);
      const AdminRoute().go(tester.element(find.text('Inbox: all')));
      await tester.pumpAndSettle();
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('Inbox: all'), findsNothing);
    });
  });

  group('return-to', () {
    testWidgets('ignores a from that leaves the app', (tester) async {
      await boot(tester, '/login?from=https://evil.example/');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
    });

    test('the guard builds the login location from the typed route', () {
      expect(
        const LoginRoute(from: '/inbox?folder=sent').location,
        '/login?from=%2Finbox%3Ffolder%3Dsent',
      );
    });
  });

  group('redirect.dart', () {
    testWidgets('redirects with the segments it asks for', (tester) async {
      await boot(tester, '/old-shops/acme');
      expect(find.text('Welcome to acme'), findsOneWidget);
      expect(find.text('Shop: acme'), findsOneWidget);
    });

    testWidgets('the target is redirected in turn (its guard runs)', (
      tester,
    ) async {
      await boot(tester, '/old-shops/closed');
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('carries query parameters', (tester) async {
      await boot(tester, '/old-search?q=ap');
      await tester.pump();
      expect(find.text('ap, page 1: apple, apricot'), findsOneWidget);
    });

    testWidgets('works from inside the app too', (tester) async {
      await boot(tester, '/');
      const OldShopsShopRoute(shop: 'acme')
          .go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to acme'), findsOneWidget);
    });

    test('keeps links to the old URL typed', () {
      expect(const OldShopsShopRoute(shop: 'a b').location, '/old-shops/a%20b');
      expect(const OldSearchRoute().location, '/old-search');
      expect(const OldSearchRoute(q: 'x').location, '/old-search?q=x');
    });
  });
}
