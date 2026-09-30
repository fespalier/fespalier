import 'package:features/app.g.dart';
import 'package:features/models/note.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Future<void> boot(WidgetTester tester, String location) async {
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
}

/// Catch-all segments (typed too), case-insensitive paths, trailing slashes and `extra`.
void main() {
  group('catch-all segments', () {
    testWidgets('\$\$rest takes one or more segments', (tester) async {
      await boot(tester, '/docs/guide');
      expect(find.text('Doc guide'), findsOneWidget);
      await boot(tester, '/docs/guide/setup/linux');
      expect(find.text('Doc guide > setup > linux'), findsOneWidget);
    });

    testWidgets('the folder\'s own page serves the path without it', (
      tester,
    ) async {
      await boot(tester, '/docs');
      expect(find.text('Docs index'), findsOneWidget);
    });

    testWidgets('static siblings win, but only for their own path', (
      tester,
    ) async {
      await boot(tester, '/docs/new');
      expect(find.text('New doc'), findsOneWidget);
      await boot(tester, '/docs/new/draft');
      expect(find.text('Doc new > draft'), findsOneWidget);
    });

    testWidgets('typed routes encode each part on its own', (tester) async {
      const route = DocsRoute(rest: ['a b', 'c/d', 'é']);
      expect(route.location, '/docs/a%20b/c%2Fd/%C3%A9');
      expect(const DocsRoute(rest: ['x']).location, '/docs/x');

      // And the location reads back into the same parts.
      await boot(tester, route.location);
      expect(find.text('Doc a b > c/d > é'), findsOneWidget);
    });

    testWidgets('a catch-all needs at least one part', (tester) async {
      expect(() => const DocsRoute(rest: []).location, throwsAssertionError);
    });

    testWidgets('an optional catch-all also matches without a part', (
      tester,
    ) async {
      await boot(tester, '/files');
      expect(find.text('Files root'), findsOneWidget);
      await boot(tester, '/files/a/b.txt');
      expect(find.text('File a/b.txt'), findsOneWidget);
      expect(const FilesRoute().location, '/files');
      expect(const FilesRoute(path: ['a', 'b']).location, '/files/a/b');
    });

    testWidgets('data.dart can be keyed by a catch-all', (tester) async {
      await boot(tester, '/wiki/animals/cats');
      expect(find.text('Article animals/cats (2 parts)'), findsOneWidget);
      expect(const WikiRoute(article: ['a', 'b c']).location, '/wiki/a/b%20c');
    });

    testWidgets('a deep link and navigation reach the same page', (
      tester,
    ) async {
      await boot(tester, '/');
      const DocsRoute(rest: ['guide', 'setup'])
          .go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(find.text('Doc guide > setup'), findsOneWidget);
    });
  });

  group('typed catch-alls', () {
    testWidgets('List<int> reads every part as an int', (tester) async {
      await boot(tester, '/compare/3/7/12');
      expect(find.text('Compare 3 vs 7 vs 12 (total 22)'), findsOneWidget);
      await boot(tester, '/compare/-4');
      expect(find.text('Compare -4 (total -4)'), findsOneWidget);
    });

    testWidgets('a part that is not an int is not found, like a segment', (
      tester,
    ) async {
      await boot(tester, '/compare/3/x/5');
      expect(find.text('Nothing at /compare/3/x/5'), findsOneWidget);
      await boot(tester, '/compare/1.5');
      expect(find.text('Nothing at /compare/1.5'), findsOneWidget);
    });

    testWidgets('the typed route takes the list and writes each part', (
      tester,
    ) async {
      const route = CompareRoute(ids: [3, 7, 12]);
      expect(route.location, '/compare/3/7/12');
      expect(() => const CompareRoute(ids: []).location, throwsAssertionError);

      await boot(tester, '/');
      route.go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(find.text('Compare 3 vs 7 vs 12 (total 22)'), findsOneWidget);
    });

    testWidgets('data.dart is keyed by the list and gets it back typed', (
      tester,
    ) async {
      // The provider's key is the path, and `data()` reads the ints out of it.
      await boot(tester, '/compare/10/20');
      final context = tester.element(find.textContaining('Compare'));
      final container = ProviderScope.containerOf(context);
      expect(
        container.read(CompareRoute.data(restKey(const [10, 20]))).value,
        30,
      );
    });

    testWidgets('the manifest knows the type', (tester) async {
      final info = AppManifest.byType[CompareRoute]!;
      expect(info.path, '/compare/*ids');
      expect(info.segments.single.type, 'List<int>');
      expect(info.segments.single.catchAll, isTrue);
    });
  });

  group('case and trailing slashes', () {
    testWidgets('paths match in any case (case_sensitive: false)', (
      tester,
    ) async {
      await boot(tester, '/DOCS/Guide/Setup');
      // Static parts match in any case; the catch-all keeps what was typed.
      expect(find.text('Doc Guide > Setup'), findsOneWidget);
      await boot(tester, '/Docs/NEW');
      expect(find.text('New doc'), findsOneWidget);
      await boot(tester, '/Login');
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('the location stays as it was requested', (tester) async {
      await boot(tester, '/DOCS/Guide/Setup?Tab=Info');
      final context = tester.element(find.text('Doc Guide > Setup'));
      // Matching is case-insensitive; nothing is lowercased or rewritten.
      expect(
        GoRouterState.of(context).uri.toString(),
        '/DOCS/Guide/Setup?Tab=Info',
      );
      expect(
        GoRouter.of(context).routeInformationProvider.value.uri.toString(),
        '/DOCS/Guide/Setup?Tab=Info',
      );
      // A typed route, on the other hand, writes the folders' spelling.
      expect(const DocsRoute(rest: ['Guide']).location, '/docs/Guide');
    });

    testWidgets('a route.dart makes one folder case-sensitive again', (
      tester,
    ) async {
      // files/route.dart says `const caseSensitive = true;`, whatever the pubspec says.
      await boot(tester, '/files/README.md');
      expect(find.text('File README.md'), findsOneWidget);
      await boot(tester, '/Files/README.md');
      expect(find.text('Nothing at /Files/README.md'), findsOneWidget);
      // (`/FILES` alone is caught by the root `$slug` page, which matches in any case.)
      await boot(tester, '/FILES');
      expect(find.text('Files root'), findsNothing);
      // The rest of the app still matches in any case.
      await boot(tester, '/DOCS/Guide');
      expect(find.text('Doc Guide'), findsOneWidget);
    });

    testWidgets('a trailing slash reaches the same page', (tester) async {
      await boot(tester, '/docs/');
      expect(find.text('Docs index'), findsOneWidget);
      await boot(tester, '/docs/guide/setup/');
      expect(find.text('Doc guide > setup'), findsOneWidget);
      await boot(tester, '/shops/acme/');
      expect(find.text('Welcome to acme'), findsOneWidget);
      await boot(tester, '/files/');
      expect(find.text('Files root'), findsOneWidget);
    });

    testWidgets('and in front of a query', (tester) async {
      await boot(tester, '/search/?q=ap');
      expect(find.textContaining('ap, page 1'), findsOneWidget);
    });
  });

  group('typed extra', () {
    testWidgets('go passes the object to the page', (tester) async {
      await boot(tester, '/');
      // `extra: ` is a `Note?`: another type doesn't compile.
      const NoteRoute(id: 3)
          .go(tester.element(find.text('Home')), extra: const Note('Hello'));
      await tester.pumpAndSettle();
      expect(find.text('Note 3: Hello'), findsOneWidget);
      expect(const NoteRoute(id: 3).location, '/notes/3');
    });

    testWidgets('push and replace pass it too', (tester) async {
      await boot(tester, '/');
      const NoteRoute(
        id: 4,
      ).push<void>(tester.element(find.text('Home')), extra: const Note('A'));
      await tester.pumpAndSettle();
      expect(find.text('Note 4: A'), findsOneWidget);
      const NoteRoute(
        id: 5,
      ).replace(tester.element(find.text('Note 4: A')), extra: const Note('B'));
      await tester.pumpAndSettle();
      expect(find.text('Note 5: B'), findsOneWidget);
    });

    testWidgets('a deep link has no extra: it is null', (tester) async {
      await boot(tester, '/notes/3');
      expect(find.text('Note 3: no extra'), findsOneWidget);
    });

    testWidgets('going without one leaves it null', (tester) async {
      await boot(tester, '/');
      const NoteRoute(id: 6).go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(find.text('Note 6: no extra'), findsOneWidget);
    });

    testWidgets('a layout gets the extra of the location it shows', (
      tester,
    ) async {
      await boot(tester, '/');
      const NoteRoute(id: 3)
          .go(tester.element(find.text('Home')), extra: const Note('Hello'));
      await tester.pumpAndSettle();
      expect(find.text('Notes frame: Hello'), findsOneWidget);
      expect(find.text('Note 3: Hello'), findsOneWidget);

      await boot(tester, '/notes/3');
      expect(find.text('Notes frame: no extra'), findsOneWidget);
    });

    testWidgets('and so does a guard: a draft goes home', (tester) async {
      await boot(tester, '/');
      const NoteRoute(id: 3)
          .go(tester.element(find.text('Home')), extra: const Note('draft'));
      await tester.pumpAndSettle();
      expect(find.text('Notes frame: draft'), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('an object of another type is an error in debug builds', (
      tester,
    ) async {
      await boot(tester, '/');
      // Only possible around the typed route, with a plain location.
      GoRouter.of(tester.element(find.text('Home')))
          .go('/notes/3', extra: 'not a note');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}
