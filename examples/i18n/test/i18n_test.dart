// Translated routes with fespalier_tolgee, with no network: the catalogs are the app's own
// assets/i18n/*.arb files (what startup() reads), and the over-the-air source is a
// FakeTranslations. pumpRouter gets the app's own App (app: ...), because its default app has no
// TranslationScope and context.tr would throw.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:fespalier_tolgee/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i18n/app.g.dart';
import 'package:i18n/app/app.dart';
import 'package:i18n/app/startup.dart';

/// Opens the app at [location] with the real bundled catalogs. A new router per test: a router
/// remembers where it went, and the scope's config is made once per router.
Future<ProviderContainer> open(
  WidgetTester tester,
  String location, {
  FakeTranslations? remote,
}) async {
  final config = Translations(
    bundled: (await tester.runAsync(
      () => BundledTranslations.load(locales: const ['en', 'fr']),
    ))!,
    baseLocale: 'en',
    remote: remote,
  );
  return pumpRouter(
    tester,
    AppRoutes.router(initialLocation: location),
    app: (router) => App(router: router),
    overrides: [translationsConfig.overrideWithValue(config)],
  );
}

void main() {
  testWidgets('startup() reads the bundled catalogs from the assets', (
    tester,
  ) async {
    final overrides = (await tester.runAsync(startup))!;
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    final config = container.read(translationsConfig);
    expect(config.supportedLocales, ['en', 'fr']);
    expect(config.remote, isNull); // no network, no key
    expect(container.read(translator('fr')).tr('home.title'), 'Bonjour');
  });

  testWidgets('the first frame is already translated', (tester) async {
    await open(tester, '/en');
    expect(find.text('Hello'), findsOneWidget);
    expect(
      find.text('This text comes from assets/i18n/en.arb.'),
      findsOneWidget,
    );
  });

  testWidgets('a deep link in French opens in French', (tester) async {
    await open(tester, '/fr');
    expect(find.text('Bonjour'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);
    // The Material strings follow the route too.
    expect(
      Localizations.localeOf(tester.element(find.byType(Scaffold))),
      const Locale('fr'),
    );
  });

  testWidgets('a localized path opens in French: /fr/produits', (tester) async {
    await open(tester, '/fr/produits');
    expect(find.text('Produits'), findsOneWidget);
    expect(find.text('1 article en stock'), findsOneWidget);
  });

  testWidgets('the English spelling still answers under /fr', (tester) async {
    await open(tester, '/fr/products');
    expect(find.text('Produits'), findsOneWidget);
  });

  testWidgets('switching the language changes the URL and the text', (
    tester,
  ) async {
    await open(tester, '/en/products');
    expect(find.text('Products'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('switch-fr')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/fr/produits');
    expect(find.text('Produits'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('switch-en')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/en/products');
    expect(find.text('Products'), findsOneWidget);
  });

  testWidgets('the current language\'s button is disabled', (tester) async {
    await open(tester, '/fr');
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('switch-fr')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('an ICU plural picks the form of the count', (tester) async {
    await open(tester, '/en/products');
    expect(find.text('1 item in stock'), findsOneWidget);
    await tester.tap(find.text('Add one'));
    await tester.pump();
    expect(find.text('2 items in stock'), findsOneWidget);
    await tester.tap(find.text('Remove one'));
    await tester.tap(find.text('Remove one'));
    await tester.pump();
    expect(find.text('Sold out'), findsOneWidget);
  });

  testWidgets('French plurals: 0 is its own form', (tester) async {
    await open(tester, '/fr/produits');
    await tester.tap(find.text('En ajouter un'));
    await tester.pump();
    expect(find.text('2 articles en stock'), findsOneWidget);
    await tester.tap(find.text('En retirer un'));
    await tester.tap(find.text('En retirer un'));
    await tester.pump();
    expect(find.text('Épuisé'), findsOneWidget);
  });

  testWidgets('a key the French file lacks falls back to the English text', (
    tester,
  ) async {
    final container = await open(tester, '/fr');
    expect(find.text('Only the English file has this text.'), findsOneWidget);
    expect(
      container.read(translator('fr')).originOf('home.footer'),
      TranslationOrigin.fallbackLocale,
    );
  });

  testWidgets('a text fetched over the air replaces the bundled one', (
    tester,
  ) async {
    final remote = FakeTranslations.strict()
      ..set('fr', {'home.title': 'Salut', 'home.footer': 'Pied de page'});
    await open(tester, '/fr', remote: remote);
    await tester.pump(); // a fetch lands on the next pump
    expect(find.text('Salut'), findsOneWidget);
    expect(remote.fetchCount('fr'), 1);
  });

  testWidgets('offline, the bundled texts stay', (tester) async {
    final remote = FakeTranslations()..offline();
    await open(tester, '/fr', remote: remote);
    await tester.pump();
    expect(find.text('Bonjour'), findsOneWidget);
  });

  testWidgets('an unknown language is not found', (tester) async {
    await open(tester, '/xx/products');
    expect(find.text('Nothing at /xx/products'), findsOneWidget);
  });

  testWidgets('/ goes to a language the app has', (tester) async {
    await open(tester, '/');
    expect(currentLocation(tester), anyOf('/en', '/fr'));
  });

  testWidgets('without the app\'s own App there is no scope', (tester) async {
    final overrides = fakeTranslations(
      bundled: {
        'en': {'home.title': 'Hello'},
      },
    );
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/en'),
      overrides: overrides,
    );
    final error = tester.takeException();
    expect(error.toString(), contains('No TranslationScope found'));
  });

  group('a missing key, with fakeTranslations', () {
    testWidgets('lenient: the key is shown as it is', (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/en'),
        app: (router) => App(router: router),
        overrides: fakeTranslations(
          bundled: {
            'en': {'home.title': 'Hello'},
          },
        ),
      );
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('home.intro'), findsOneWidget);
    });

    testWidgets('strict: a missing key fails the test', (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/en'),
        app: (router) => App(router: router),
        overrides: fakeTranslations(
          bundled: {
            'en': {
              'app.title': 'T',
              'home.title': 'Hello',
              'home.intro': 'Intro',
              'home.products': 'Products',
              // home.footer is missing
            },
          },
          remote: FakeTranslations.strict(),
        ),
      );
      final error = tester.takeException();
      expect(
        error.toString(),
        contains('No translation for "home.footer" in en'),
      );
    });
  });
}
