import 'package:features/app.g.dart';
import 'package:features/app/layout.dart';
import 'package:features/sheet_page.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

/// `present.dart`: the app builds the route's `Page` (its own `SheetPage`), and
/// the route is on the root navigator, above the root layout.
void main() {
  late GoRouter router;

  Future<void> bootWith(WidgetTester tester, GoRouter r) async {
    router = r;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: mui.MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: const [
              DefaultMaterialLocalizations.delegate,
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> boot(WidgetTester tester, String location) =>
      bootWith(tester, AppRoutes.router(initialLocation: location));

  String location() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  Finder aboveLayout(String text) =>
      find.ancestor(of: find.text(text), matching: find.byType(RootLayout));

  testWidgets('a deep link builds the parent page under the sheet',
      (tester) async {
    await boot(tester, '/photos/share');
    expect(location(), '/photos/share');
    expect(find.text('Share photos'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    // The app's own sheet, with its own handle: nothing of fespalier's.
    expect(find.byKey(const ValueKey('app-sheet-handle')), findsOneWidget);
    expect(find.byType(ModalBarrier), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the app\'s Page is used as it is', (tester) async {
    await boot(tester, '/photos/share');
    final route = ModalRoute.of(tester.element(find.text('Share photos')))!;
    expect(route.settings, isA<SheetPage<void>>());
    expect(route, isA<PopupRoute<void>>());
    expect(route, isNot(isA<ModalBottomSheetRoute<void>>()));
  });

  testWidgets('it is on the root navigator: above the root layout',
      (tester) async {
    await boot(tester, '/photos/share');
    final sheet = tester.element(find.text('Share photos'));
    final photos = tester.element(find.text('Photos'));
    expect(Navigator.of(sheet), AppRoutes.rootNavigatorKey.currentState);
    expect(Navigator.of(photos), isNot(AppRoutes.rootNavigatorKey.currentState));
    expect(aboveLayout('Photos'), findsWidgets);
    expect(aboveLayout('Share photos'), findsNothing);
  });

  testWidgets('popping the sheet returns to the parent, its state intact',
      (tester) async {
    await boot(tester, '/photos');
    await tester.tap(find.text('Like'));
    await tester.pump();
    expect(find.text('Liked: yes'), findsOneWidget);

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(location(), '/photos/share');
    expect(find.text('Share photos'), findsOneWidget);
    expect(find.text('Liked: yes'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(location(), '/photos');
    expect(find.text('Share photos'), findsNothing);
    expect(find.text('Liked: yes'), findsOneWidget);

    // The barrier dismisses it too (the route says it may).
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(location(), '/photos');
    expect(find.text('Liked: yes'), findsOneWidget);
  });

  testWidgets('a child of the sheet renders above it, not under it',
      (tester) async {
    await boot(tester, '/photos');
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terms'));
    await tester.pumpAndSettle();
    expect(location(), '/photos/share/terms');
    expect(find.text('Terms of sharing'), findsOneWidget);
    // The page above hides the sheet, which is still below it.
    expect(find.text('Share photos'), findsNothing);
    expect(find.text('Share photos', skipOffstage: false), findsOneWidget);

    final terms = tester.element(find.text('Terms of sharing'));
    expect(Navigator.of(terms), AppRoutes.rootNavigatorKey.currentState);
    // Its own page keeps the nearest transition.dart: present.dart is not inherited.
    expect(ModalRoute.of(terms)!.settings, isA<MaterialPage<void>>());
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(location(), '/photos/share');
    expect(find.text('Share photos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deep link to the child builds the sheet and the page below',
      (tester) async {
    await boot(tester, '/photos/share/terms');
    expect(find.text('Terms of sharing'), findsOneWidget);
    expect(find.text('Share photos', skipOffstage: false), findsOneWidget);
    expect(find.text('Photos', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mounted in a host router with its navigator key',
      (tester) async {
    // `mount` stores where it is mounted; put it back for the tests after this one.
    addTearDown(() => AppRoutes.mount());
    final hostKey = GlobalKey<NavigatorState>();
    final host = GoRouter(
      navigatorKey: hostKey,
      initialLocation: '/app/photos/share',
      routes: AppRoutes.mount(at: '/app', navigatorKey: hostKey),
    );
    await bootWith(tester, host);
    expect(AppRoutes.rootNavigatorKey, hostKey);
    expect(find.text('Share photos'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(aboveLayout('Share photos'), findsNothing);
    expect(
      Navigator.of(tester.element(find.text('Share photos'))),
      hostKey.currentState,
    );
    expect(tester.takeException(), isNull);
  });

  test('the manifest says the sheet is custom, its child root', () {
    expect(AppManifest.byType[ShareSheetRoute]!.presentation,
        RoutePresentation.custom);
    expect(
        AppManifest.byType[TermsRoute]!.presentation, RoutePresentation.root);
    expect(
        AppManifest.byType[PhotosRoute]!.presentation, RoutePresentation.page);
    expect(const ShareSheetRoute().location, '/photos/share');
    expect(const TermsRoute().location, '/photos/share/terms');
  });
}
