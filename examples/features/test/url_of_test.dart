// `AppRoutes.urlOf` (since 0.16.0): the https URL of a typed route on the first of `links: domains`
// (pubspec.yaml: features.example.com), with the spelling of a locale and the mount prefix.
import 'package:features/app.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(AppRoutes.mount);

  group('urlOf', () {
    test('is the route on the first domain, in the canonical spelling', () {
      expect(
        AppRoutes.urlOf(const HelpTopicRoute(topic: 'routing')),
        Uri.parse('https://features.example.com/help/routing'),
      );
      expect(
        AppRoutes.urlOf(const HomeRoute()),
        Uri.parse('https://features.example.com/'),
      );
    });

    test('spells the localized segments as the locale has them', () {
      const topic = HelpTopicRoute(topic: 'routing');
      expect(
        AppRoutes.urlOf(topic, locale: 'fr'),
        Uri.parse('https://features.example.com/aide/routing'),
      );
      expect(
        AppRoutes.urlOf(topic, locale: 'de'),
        Uri.parse('https://features.example.com/hilfe/routing'),
      );
      // A region falls back to its language, an unknown locale to the canonical spelling.
      expect(
        AppRoutes.urlOf(topic, locale: 'fr-CA'),
        Uri.parse('https://features.example.com/aide/routing'),
      );
      expect(
        AppRoutes.urlOf(topic, locale: 'es'),
        Uri.parse('https://features.example.com/help/routing'),
      );
    });

    test('keeps the query and percent-encodes what the route does', () {
      expect(
        AppRoutes.urlOf(const GuideRoute(), locale: 'de').toString(),
        'https://features.example.com/f%C3%BChrer',
      );
      final withQuery = AppRoutes.urlOf(const HelpTopicRoute(topic: 'a b'));
      expect(withQuery.host, 'features.example.com');
      expect(withQuery.scheme, 'https');
      expect(withQuery.pathSegments, ['help', 'a b']);
    });

    test('includes the mount prefix, as location does', () {
      AppRoutes.mount(at: '/x');
      expect(
        AppRoutes.urlOf(const HelpTopicRoute(topic: 'routing')),
        Uri.parse('https://features.example.com/x/help/routing'),
      );
      expect(
        AppRoutes.urlOf(const HelpTopicRoute(topic: 'routing'), locale: 'fr'),
        Uri.parse('https://features.example.com/x/aide/routing'),
      );
    });

    test('is the location the router would match, on the domain', () {
      const route = HelpExamplesRoute(topic: 'routing');
      final url = AppRoutes.urlOf(route, locale: 'de');
      expect(url.path, route.locationFor('de'));
      final match = AppRoutes.matchUrl(Uri.parse(url.path))?.route;
      expect(match, isA<HelpExamplesRoute>());
      expect(match?.location, route.location);
    });
  });
}
