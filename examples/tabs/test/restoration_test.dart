import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';

/// Builds its router in `initState`, the way an app does: after
/// `restartAndRestore` there is a new one, and only the restored state can put
/// it back where it was.
class RestorableApp extends StatefulWidget {
  const RestorableApp({super.key});

  @override
  State<RestorableApp> createState() => _RestorableAppState();
}

class _RestorableAppState extends State<RestorableApp> {
  // The one line an app adds to get restoration: the scope id.
  late final GoRouter router = AppRoutes.router(restorationScopeId: 'router');

  @override
  Widget build(BuildContext context) => ProviderScope(
        // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
        // nesting both gives Material pages and error screens on either.
        child: MaterialApp(
          restorationScopeId: 'app',
          home: mui.MaterialApp.router(
            restorationScopeId: 'app',
            routerConfig: router,
            localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
          ),
        ),
      );
}

Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  ));
  await tester.pumpAndSettle();
}

int selected(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

String location(WidgetTester tester) => GoRouter.of(
      tester.element(find.byType(NavigationBar)),
    ).routeInformationProvider.value.uri.toString();

void main() {
  testWidgets('a route survives state restoration', (tester) async {
    await tester.pumpWidget(const RestorableApp());
    await tester.pumpAndSettle();

    await tapTab(tester, 'Profile');
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    expect(location(tester), '/profile/security');

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(location(tester), '/profile/security');
    expect(find.text('Security'), findsOneWidget);
    expect(selected(tester), 2);
  });

  testWidgets('a route on the root navigator survives it, with its tab below',
      (tester) async {
    await tester.pumpWidget(const RestorableApp());
    await tester.pumpAndSettle();

    await tapTab(tester, 'Profile');
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    // Full screen again, and back is the Profile tab.
    expect(find.text('Editing your profile'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(location(tester), '/profile');
    expect(selected(tester), 2);
  });

  testWidgets('a tab branch survives it: the tab and its own stack',
      (tester) async {
    await tester.pumpWidget(const RestorableApp());
    await tester.pumpAndSettle();

    // Two tabs with history of their own: Profile is on /profile/security, and
    // the current tab is Search.
    await tapTab(tester, 'Profile');
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Search');
    expect(location(tester), '/search');

    await tester.restartAndRestore();
    await tester.pumpAndSettle();
    expect(location(tester), '/search');
    expect(selected(tester), 1);

    // The Profile tab remembers where it was, too.
    await tapTab(tester, 'Profile');
    expect(location(tester), '/profile/security');
  });

  testWidgets('what a page keeps in a RestorableProperty comes back',
      (tester) async {
    await tester.pumpWidget(const RestorableApp());
    await tester.pumpAndSettle();
    await tapTab(tester, 'Search');
    await tester.tap(find.byTooltip('+'));
    await tester.tap(find.byTooltip('+'));
    await tester.pump();
    expect(find.text('Search count 2'), findsOneWidget);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();
    expect(location(tester), '/search');
    expect(find.text('Search count 2'), findsOneWidget);
  });
}
