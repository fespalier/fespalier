import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Page {}

final routes = <RouteInfo<Object?>>[
  const RouteInfo<Object?>(type: _Page, path: '/:lang', folder: r'$lang'),
  const RouteInfo<Object?>(
    type: _Page,
    path: '/:lang/products',
    paths: {'fr': '/:lang/produits', 'de': '/:lang/produkte'},
    folder: r'$lang/products',
  ),
  const RouteInfo<Object?>(
    type: _Page,
    path: r'/:lang/products/:id',
    paths: {'fr': '/:lang/produits/:id', 'de': '/:lang/produkte/:id'},
    folder: r'$lang/products/$id',
  ),
  const RouteInfo<Object?>(
    type: _Page,
    path: '/guide',
    paths: {'de': '/führer', 'ru': '/руководство', 'fr': '/guide'},
    folder: 'guide',
  ),
  // Two locales share a spelling.
  const RouteInfo<Object?>(
    type: _Page,
    path: '/team',
    paths: {'es': '/equipo', 'pt': '/equipo'},
    folder: 'team',
  ),
];

void main() {
  test('localeSegment', () {
    expect(localeSegment()(Uri.parse('/fr/products')), 'fr');
    expect(localeSegment(at: 1)(Uri.parse('/shop/de/x')), 'de');
    expect(localeSegment()(Uri.parse('/')), isNull);
  });

  test(
    'localeSpelling: spelling gives the locale, canonical or shared gives null',
    () {
      final of = localeSpelling(routes);
      expect(of(Uri.parse('/fr/produits/2')), 'fr');
      expect(of(Uri.parse('/xx/produkte')), 'de');
      expect(of(Uri.parse('/führer')), 'de');
      expect(
        of(
          Uri.parse(
            '/%D1%80%D1%83%D0%BA%D0%BE%D0%B2%D0%BE%D0%B4%D1%81%D1%82%D0%B2%D0%BE',
          ),
        ),
        'ru',
      );
      expect(of(Uri.parse('/en/products/2')), isNull);
      expect(of(Uri.parse('/guide')), isNull);
      expect(of(Uri.parse('/equipo')), isNull);
    },
  );

  test('firstLocaleOf takes the first reader that answers', () {
    final of = firstLocaleOf([localeSegment(at: 3), localeSpelling(routes)]);
    expect(of(Uri.parse('/xx/produits')), 'fr');
    expect(of(Uri.parse('/a/b/c/de')), 'de');
    expect(of(Uri.parse('/nothing')), isNull);
  });

  test('relocate respells each level and keeps the query', () {
    expect(
      relocate(
        Uri.parse('/fr/produits/2?q=1'),
        to: 'de',
        routes: routes,
        segment: 0,
      ),
      '/de/produkte/2?q=1',
    );
    expect(
      relocate(
        Uri.parse('/en/products/2'),
        to: 'fr',
        routes: routes,
        segment: 0,
      ),
      '/fr/produits/2',
    );
    expect(
      relocate(Uri.parse('/fr'), to: 'en', routes: routes, segment: 0),
      '/en',
    );
  });

  test('relocate encodes non-ASCII spellings like locationFor', () {
    expect(
      relocate(Uri.parse('/guide'), to: 'de', routes: routes),
      '/f%C3%BChrer',
    );
    expect(
      relocate(Uri.parse('/f%C3%BChrer'), to: 'fr', routes: routes),
      '/guide',
    );
  });

  test('relocate leaves an unknown path alone but for the segment', () {
    expect(
      relocate(Uri.parse('/fr/other'), to: 'de', routes: routes, segment: 0),
      '/de/other',
    );
  });

  test('localeFromTag', () {
    expect(localeFromTag('pt-BR'), const Locale('pt', 'BR'));
    expect(localeFromTag('fr'), const Locale('fr'));
    expect(
      localeFromTag('zh_hant_tw'),
      const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
        countryCode: 'TW',
      ),
    );
  });
}
