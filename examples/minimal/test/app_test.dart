import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minimal/app.g.dart';
import 'package:minimal/app/items/\$id/error.dart';
import 'package:minimal/app/items/\$id/loading.dart';
import 'package:minimal/app/items/\$id/page.dart';
import 'package:minimal/app/page.dart';

// pumpRouter boots the generated router in a ProviderScope and a MaterialApp,
// the way main.dart does. Make a new router for every test: a router
// remembers where it went.
Future<void> boot(WidgetTester tester, String location) =>
    pumpRouter(tester, AppRoutes.router(initialLocation: location));

void main() {
  testWidgets('navigates by tapping, inside the layout', (tester) async {
    await boot(tester, '/');
    expect(find.text('Hello from fespalier'), findsOneWidget);
    // layout.dart's AppBar is around the home page.
    expect(find.widgetWithText(AppBar, 'Minimal'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'About'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/about');
    expect(find.text('A page written as a function.'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Minimal'), findsOneWidget);
  });

  testWidgets('a deep link opens the page with its segment and query', (
    tester,
  ) async {
    await boot(tester, '/items/2?qty=3');
    expect(find.byType(ItemPage), findsOneWidget);
    expect(find.text('3 × Kettle (#2)'), findsOneWidget);
    // The layout is there too, even though we never visited `/`.
    expect(find.widgetWithText(AppBar, 'Minimal'), findsOneWidget);
  });

  testWidgets('the query parameter is optional', (tester) async {
    await boot(tester, '/items/1');
    expect(find.text('1 × Teapot (#1)'), findsOneWidget);
  });

  testWidgets('an unknown path shows not_found.dart', (tester) async {
    await boot(tester, '/nope');
    expect(find.text('Nothing at /nope'), findsOneWidget);
    // not_found.dart shows without the layout.
    expect(find.byType(AppBar), findsNothing);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
  });

  testWidgets('a segment that does not parse is not found too', (tester) async {
    // `$id` is an int (data.dart asks for `int id`), and `abc` isn't one.
    await boot(tester, '/items/abc');
    expect(find.text('Nothing at /items/abc'), findsOneWidget);
    expect(find.byType(ItemPage), findsNothing);
  });

  testWidgets('data.dart: loading.dart first, then the page', (tester) async {
    // settle: false, so we can look at the loading view before it is done.
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/items/1'),
      settle: false,
    );
    await tester.pump();
    expect(find.byType(ItemLoading), findsOneWidget);
    expect(find.byType(ItemPage), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ItemLoading), findsNothing);
    expect(find.text('1 × Teapot (#1)'), findsOneWidget);
  });

  testWidgets('data.dart throwing shows error.dart', (tester) async {
    await boot(tester, '/items/99');
    expect(find.byType(ItemError), findsOneWidget);
    expect(find.text("Couldn't load item #99: No item #99"), findsOneWidget);
  });

  testWidgets('a typed route goes somewhere with .go', (tester) async {
    await boot(tester, '/');

    // From any widget under the router, with a context in it.
    final context = tester.element(find.byType(HomePage));
    const ItemRoute(id: 3, qty: 2).go(context);
    await tester.pumpAndSettle();

    expect(currentLocation(tester), '/items/3?qty=2');
    expect(find.text('2 × Whisk (#3)'), findsOneWidget);
    // `.location` is what `.go` navigates to.
    expect(const ItemRoute(id: 3, qty: 2).location, '/items/3?qty=2');
    expect(const AboutRoute().location, '/about');
  });
}
