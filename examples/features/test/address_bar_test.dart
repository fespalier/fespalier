// The browser's address bar: what `replace` and `push` show there.
//
// `replace` over a page of the declarative stack is `go` that replaces the history entry,
// so the URL is the new location. A `push` shows its URL only when the pubspec says
// `push_updates_url: true` (this app does), which `AppRoutes.router()` hands to go_router.
import 'package:features/app.g.dart';
import 'package:features/app/search/page.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the app told the platform (the browser's history) about its location.
typedef HistoryUpdate = ({String uri, bool replace});

Future<(GoRouter, List<HistoryUpdate>)> boot(
  WidgetTester tester,
  String location,
) async {
  final history = <HistoryUpdate>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.navigation,
    (call) async {
      if (call.method == 'routeInformationUpdated') {
        final args = call.arguments as Map<Object?, Object?>;
        history.add((
          uri: args['uri']! as String,
          replace: args['replace']! as bool,
        ));
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, null),
  );
  final router = AppRoutes.router(initialLocation: location);
  await pumpRouter(tester, router);
  history.clear();
  return (router, history);
}

/// The address bar: what the router last handed to the platform.
String addressBar(GoRouter router) =>
    router.routeInformationProvider.value.uri.toString();

void main() {
  test('the generated router sets go_router\'s option from the pubspec', () {
    GoRouter.optionURLReflectsImperativeAPIs = false;
    AppRoutes.router().dispose();
    expect(GoRouter.optionURLReflectsImperativeAPIs, isTrue);
  });

  group('replace', () {
    testWidgets('shows the copy in the address bar, as a replaced entry', (
      tester,
    ) async {
      final (router, history) = await boot(tester, '/search?q=ap');
      final context = tester.element(find.byType(SearchPage));
      SearchRoute.of(context).copyWith(page: 2).replace(context);
      await tester.pumpAndSettle();

      expect(currentLocation(tester), '/search?q=ap&page=2');
      expect(addressBar(router), '/search?q=ap&page=2');
      expect(history, [(uri: '/search?q=ap&page=2', replace: true)]);
      expect(
        SearchRoute.of(tester.element(find.byType(SearchPage))).page,
        2,
      );
    });

    testWidgets('over a pushed page keeps the stack', (tester) async {
      final (router, _) = await boot(tester, '/');
      const SearchRoute(q: 'ap').push<void>(tester.element(find.text('Home')));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(SearchPage));
      const SearchRoute(q: 'pear').replace(context);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/search?q=pear');
      expect(find.text('Home', skipOffstage: false), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(currentLocation(tester), '/');
    });
  });

  group('push with push_updates_url', () {
    testWidgets('shows the pushed location in the address bar', (
      tester,
    ) async {
      final (router, history) = await boot(tester, '/');
      const SearchRoute(q: 'ap').push<void>(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(addressBar(router), '/search?q=ap');
      expect(history, [(uri: '/search?q=ap', replace: false)]);

      // A replace over it shows the new one.
      final context = tester.element(find.byType(SearchPage));
      SearchRoute.of(context).copyWith(page: 2).replace(context);
      await tester.pumpAndSettle();
      expect(addressBar(router), '/search?q=ap&page=2');

      router.pop();
      await tester.pumpAndSettle();
      expect(addressBar(router), '/');
    });
  });
}
