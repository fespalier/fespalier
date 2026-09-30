// Localized paths: `help/route.dart` says `const paths = {'fr': 'aide', 'de': 'hilfe'};`, so
// the folder also answers /aide and /hilfe. The typed route, the page and its data stay single.
import 'package:features/app.g.dart';
import 'package:features/models/category.dart';
import 'package:features/app/help/\$topic/page.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
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

/// Where the router is now. (`currentLocation` needs the router's own `MaterialApp`; this
/// app nests two, so it asks from inside.)
String where(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .routeInformationProvider
        .value
        .uri
        .toString();

void main() {
  group('a deep link', () {
    testWidgets('reaches the page through every spelling', (tester) async {
      for (final path in ['/help', '/aide', '/hilfe']) {
        await boot(tester, path);
        expect(find.text('Help index'), findsOneWidget, reason: path);
      }
    });

    testWidgets('keeps the location it was asked for', (tester) async {
      await pumpRouter(tester, AppRoutes.router(initialLocation: '/aide'));
      expect(where(tester), '/aide');
      expect(find.text('Help index'), findsOneWidget);
    });

    testWidgets('matches in any case, like the rest of this app', (
      tester,
    ) async {
      await boot(tester, '/AIDE');
      expect(find.text('Help index'), findsOneWidget);
      await boot(tester, '/Hilfe/Routing/Beispiele');
      expect(find.text('Examples of Routing'), findsOneWidget);
    });

    testWidgets('a trailing slash and a query change nothing', (tester) async {
      await boot(tester, '/aide/');
      expect(find.text('Help index'), findsOneWidget);
      await boot(tester, '/hilfe?x=1');
      expect(find.text('Help index'), findsOneWidget);
    });

    testWidgets('the segments below are the same params in every spelling', (
      tester,
    ) async {
      for (final path in ['/help/routing', '/aide/routing', '/hilfe/routing']) {
        await boot(tester, path);
        expect(find.text('Help topic routing'), findsOneWidget, reason: path);
      }
    });

    testWidgets('a static sibling wins over the dynamic segment', (
      tester,
    ) async {
      // fr has no spelling of its own for `contact/`: it keeps the canonical one.
      for (final path in [
        '/help/contact',
        '/aide/contact',
        '/hilfe/kontakt',
        // The levels spell independently, so any mix is the same route.
        '/hilfe/contact',
        '/aide/kontakt',
      ]) {
        await boot(tester, path);
        expect(find.text('Contact us'), findsOneWidget, reason: path);
        expect(find.textContaining('Help topic'), findsNothing, reason: path);
      }
    });

    testWidgets('a nested child resolves under every spelling', (tester) async {
      for (final path in [
        '/help/routing/examples',
        '/aide/routing/exemples',
        '/hilfe/routing/beispiele',
        '/aide/routing/examples',
        '/help/routing/beispiele',
      ]) {
        await boot(tester, path);
        expect(find.text('Examples of routing'), findsOneWidget, reason: path);
      }
    });

    testWidgets('the parent page is built under the child, as it is without '
        'localization', (tester) async {
      await boot(tester, '/aide/routing/exemples');
      // `help/$topic/page.dart` is the child's parent: go_router builds its stack.
      final router = GoRouter.of(
        tester.element(find.text('Examples of routing')),
      );
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Help topic routing'), findsOneWidget);
      expect(where(tester), '/aide/routing');
    });
  });

  group('a not_found.dart under a localized folder', () {
    testWidgets('covers every spelling of its prefix', (tester) async {
      for (final path in [
        '/help/a/b/c',
        '/aide/a/b/c',
        '/hilfe/a/b/c',
        '/Aide/a/b/c',
        '/hilfe/routing/zzz',
      ]) {
        await boot(tester, path);
        expect(find.text('No help at $path'), findsOneWidget, reason: path);
      }
    });

    testWidgets('and leaves the rest of the app to the root one', (
      tester,
    ) async {
      await boot(tester, '/nope/x');
      expect(find.text('Nothing at /nope/x'), findsOneWidget);
      await boot(tester, '/aider/x');
      expect(find.text('Nothing at /aider/x'), findsOneWidget);
    });

    testWidgets('AppRoutes.notFound picks it from a location', (tester) async {
      await boot(tester, '/');
      final found = AppRoutes.notFound(Uri.parse('/hilfe/zzz'));
      expect(found, isA<Widget>());
      await tester.pumpWidget(MaterialApp(home: found));
      expect(find.text('No help at /hilfe/zzz'), findsOneWidget);
    });
  });

  group('typed locations', () {
    test('.location is canonical, locationFor spells the locale', () {
      const help = HelpRoute();
      expect(help.location, '/help');
      expect(help.locationFor('fr'), '/aide');
      expect(help.locationFor('de'), '/hilfe');

      const topic = HelpTopicRoute(topic: 'routing');
      expect(topic.location, '/help/routing');
      expect(topic.locationFor('fr'), '/aide/routing');
      expect(topic.locationFor('de'), '/hilfe/routing');
      expect(
        const HelpTopicRoute(topic: 'a b').locationFor('de'),
        '/hilfe/a%20b',
      );
    });

    test('a locale nobody spells, or none, is the canonical location', () {
      const topic = HelpTopicRoute(topic: 'routing');
      expect(topic.locationFor(null), topic.location);
      expect(topic.locationFor('es'), topic.location);
      expect(topic.locationFor(''), topic.location);
    });

    test(
      'a region falls back to its language, and tags are not case-bound',
      () {
        const topic = HelpTopicRoute(topic: 'routing');
        expect(topic.locationFor('fr-CA'), '/aide/routing');
        expect(topic.locationFor('fr_CA'), '/aide/routing');
        expect(topic.locationFor('DE'), '/hilfe/routing');
      },
    );

    test('a level without a spelling for the locale keeps its own', () {
      // `help/` spells fr, `contact/` only de, `$topic/examples/` both.
      expect(const ContactRoute().location, '/help/contact');
      expect(const ContactRoute().locationFor('fr'), '/aide/contact');
      expect(const ContactRoute().locationFor('de'), '/hilfe/kontakt');
      const examples = HelpExamplesRoute(topic: 'routing');
      expect(examples.location, '/help/routing/examples');
      expect(examples.locationFor('fr'), '/aide/routing/exemples');
      expect(examples.locationFor('de'), '/hilfe/routing/beispiele');
    });

    test('a route with no localized segment answers with its location', () {
      const about = SearchRoute(q: 'ap');
      expect(about.locationFor('fr'), about.location);
      expect(const HomeRoute().locationFor('fr'), '/');
    });

    testWidgets('go, push and replace take the locale', (tester) async {
      await boot(tester, '/');
      final context = tester.element(find.text('Home'));
      const HelpTopicRoute(topic: 'x').go(context, locale: 'de');
      await tester.pumpAndSettle();
      expect(find.text('Help topic x'), findsOneWidget);
      expect(
        GoRouter.of(tester.element(find.text('Help topic x'))).state.uri.path,
        '/hilfe/x',
      );

      const ContactRoute().push<void>(
        tester.element(find.text('Help topic x')),
        locale: 'fr',
      );
      await tester.pumpAndSettle();
      expect(find.text('Contact us'), findsOneWidget);
      expect(
        GoRouter.of(tester.element(find.text('Contact us'))).state.uri.path,
        '/aide/contact',
      );

      const HelpRoute().replace(
        tester.element(find.text('Contact us')),
        locale: 'de',
      );
      await tester.pumpAndSettle();
      expect(find.text('Help index'), findsOneWidget);
      expect(
        GoRouter.of(tester.element(find.text('Help index'))).state.uri.path,
        '/hilfe',
      );
    });

    testWidgets('without a locale they go to the canonical location', (
      tester,
    ) async {
      await boot(tester, '/');
      const HelpRoute().go(tester.element(find.text('Home')));
      await tester.pumpAndSettle();
      expect(find.text('Help index'), findsOneWidget);
      expect(
        GoRouter.of(tester.element(find.text('Help index'))).state.uri.path,
        '/help',
      );
    });

    testWidgets('moving between spellings updates the page in place', (
      tester,
    ) async {
      // go_router keys a page by its route's path pattern, which is the same for every
      // spelling: the page is updated, not rebuilt from scratch.
      await boot(tester, '/help/routing');
      final before = tester.element(find.byType(HelpTopicPage));
      const HelpTopicRoute(topic: 'routing').go(before, locale: 'fr');
      await tester.pumpAndSettle();
      expect(where(tester), '/aide/routing');
      expect(tester.element(find.byType(HelpTopicPage)), same(before));
    });
  });

  group('letters beyond ASCII', () {
    // `guide/route.dart`: {'de': 'führer', 'ru': 'руководство'}. go_router matches the
    // percent-encoded path (`Uri.path`), which is how `Uri` writes `/führer` however it was
    // typed, so the routes carry the encoded spelling and a deep link works raw or encoded.
    testWidgets('a deep link works raw, encoded and in any hex case', (
      tester,
    ) async {
      for (final path in [
        '/führer',
        '/f%C3%BChrer',
        '/f%c3%bchrer',
        '/руководство',
        '/%D1%80%D1%83%D0%BA%D0%BE%D0%B2%D0%BE%D0%B4%D1%81%D1%82%D0%B2%D0%BE',
        '/guide',
      ]) {
        await boot(tester, path);
        expect(find.text('Guide'), findsOneWidget, reason: path);
      }
    });

    testWidgets('the router location is the encoded form', (tester) async {
      await boot(tester, '/führer');
      expect(where(tester), '/f%C3%BChrer');
    });

    test('locationFor writes the spelling percent-encoded', () {
      expect(const GuideRoute().location, '/guide');
      expect(const GuideRoute().locationFor('de'), '/f%C3%BChrer');
      expect(
        const GuideRoute().locationFor('ru'),
        '/%D1%80%D1%83%D0%BA%D0%BE%D0%B2%D0%BE%D0%B4%D1%81%D1%82%D0%B2%D0%BE',
      );
      // The location decodes to the word, and is the same URL as the raw one.
      expect(Uri.parse(const GuideRoute().locationFor('de')).pathSegments, [
        'führer',
      ]);
      expect(
        Uri.parse(const GuideRoute().locationFor('de')),
        Uri.parse('/führer'),
      );
    });

    testWidgets('go(locale:) navigates to the encoded location', (
      tester,
    ) async {
      await boot(tester, '/');
      const GuideRoute().go(tester.element(find.text('Home')), locale: 'de');
      await tester.pumpAndSettle();
      expect(find.text('Guide'), findsOneWidget);
      expect(where(tester), '/f%C3%BChrer');
    });

    test(
      'match reads the decoded segment, and the manifest lists it as written',
      () {
        for (final path in ['/f%C3%BChrer', '/führer']) {
          final m = AppRoutes.match(Uri.parse(path))!;
          expect(m.route, isA<GuideRoute>(), reason: path);
        }
        expect(AppManifest.byType[GuideRoute]!.paths, {
          'de': '/führer',
          'ru': '/руководство',
        });
        expect(AppManifest.byType[GuideRoute]!.pathFor('de'), '/führer');
        expect(AppRoutes.match(Uri.parse('/fuhrer/x/y')), isNull);
      },
    );
  });

  group('an enum segment below a localized folder', () {
    // `shop/route.dart`: {'fr': 'boutique', 'de': 'laden'}; `shop/$category` is a `Category`.
    testWidgets('is parsed at every spelling', (tester) async {
      for (final path in ['/shop/hats', '/boutique/hats', '/laden/hats']) {
        await boot(tester, path);
        expect(
          find.text('Shop hats: cap, beret'),
          findsOneWidget,
          reason: path,
        );
      }
      await boot(tester, '/boutique/hats?sort=name');
      expect(find.text('sorted by name'), findsOneWidget);
      // Case-insensitive here, spellings and the enum's name alike.
      await boot(tester, '/LADEN/HATS');
      expect(find.text('Shop hats: cap, beret'), findsOneWidget);
    });

    testWidgets('a name that is no value is not found, at any spelling', (
      tester,
    ) async {
      await boot(tester, '/boutique/socks');
      expect(find.text('Nothing at /boutique/socks'), findsOneWidget);
    });

    test('locationFor writes the enum by name, and match reads it back', () {
      const route = CategoryShopRoute(category: Category.hats);
      expect(route.location, '/shop/hats');
      expect(route.locationFor('fr'), '/boutique/hats');
      expect(route.locationFor('de'), '/laden/hats');
      final m = AppRoutes.match(Uri.parse('/laden/hats'))!;
      expect(m.params['category'], Category.hats);
      expect(m.route.location, '/shop/hats');
      expect(
        AppRoutes.dataAt(Uri.parse('/boutique/hats'))!.single,
        CategoryShopRoute.data(Category.hats),
      );
    });
  });

  group('the location helpers', () {
    test('match finds the route through every spelling', () {
      for (final path in [
        '/help/routing/examples',
        '/aide/routing/exemples',
        '/hilfe/routing/beispiele',
      ]) {
        final m = AppRoutes.match(Uri.parse(path))!;
        expect(m.info.path, '/help/:topic/examples', reason: path);
        expect(m.params, {'topic': 'routing'}, reason: path);
        expect(m.route, isA<HelpExamplesRoute>());
        // The typed route it builds is canonical.
        expect(m.route.location, '/help/routing/examples');
        expect(m.uri.path, path);
      }
      expect(
        AppRoutes.match(Uri.parse('/aide/routing/examples'))!.route,
        isA<HelpExamplesRoute>(),
      );
    });

    test('a static sibling is tried before the dynamic one', () {
      expect(
        AppRoutes.match(Uri.parse('/hilfe/kontakt'))!.route,
        isA<ContactRoute>(),
      );
      expect(
        AppRoutes.match(Uri.parse('/hilfe/other'))!.route,
        isA<HelpTopicRoute>(),
      );
    });

    test('match and dataAt are case-insensitive here, spellings included', () {
      expect(AppRoutes.match(Uri.parse('/AIDE'))!.route, isA<HelpRoute>());
      expect(AppRoutes.dataAt(Uri.parse('/Hilfe')), isEmpty);
    });

    test('a spelling nobody has matches nothing', () {
      expect(AppRoutes.match(Uri.parse('/ayuda/x')), isNull);
      expect(AppRoutes.match(Uri.parse('/aide/routing/ejemplos')), isNull);
      expect(AppRoutes.dataAt(Uri.parse('/aid/x/y')), isNull);
    });
  });

  group('the route manifest', () {
    test('lists the path in each locale', () {
      final info = AppManifest.byType[HelpTopicRoute]!;
      expect(info.path, '/help/:topic');
      expect(info.paths, {'fr': '/aide/:topic', 'de': '/hilfe/:topic'});
      expect(AppManifest.byType[HelpRoute]!.paths, {
        'fr': '/aide',
        'de': '/hilfe',
      });
      // A level with no spelling for a locale keeps its canonical one.
      expect(AppManifest.byType[ContactRoute]!.paths, {
        'fr': '/aide/contact',
        'de': '/hilfe/kontakt',
      });
      expect(AppManifest.byType[HelpExamplesRoute]!.paths, {
        'fr': '/aide/:topic/exemples',
        'de': '/hilfe/:topic/beispiele',
      });
    });

    test('a route that is not localized has none', () {
      expect(AppManifest.byType[HomeRoute]!.paths, isEmpty);
      expect(AppManifest.byType[SearchRoute]!.paths, isEmpty);
    });

    test('pathFor picks one, falling back to the canonical path', () {
      final info = AppManifest.byType[HelpExamplesRoute]!;
      expect(info.pathFor('de'), '/hilfe/:topic/beispiele');
      expect(info.pathFor('fr-CA'), '/aide/:topic/exemples');
      expect(info.pathFor('es'), info.path);
      expect(info.pathFor(null), info.path);
    });

    test('byPath is keyed by the canonical path alone', () {
      expect(AppManifest.byPath['/help/:topic'], isNotNull);
      expect(AppManifest.byPath['/aide/:topic'], isNull);
    });
  });
}
