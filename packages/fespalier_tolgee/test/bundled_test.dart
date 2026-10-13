import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('load reads one ARB file per locale from the default path', () async {
    final bundle = MapBundle({
      'assets/i18n/en.arb': '{"@@locale":"en","hi":"Hi"}',
      'assets/i18n/fr.arb': '{"hi":"Salut"}',
    });
    final b = await BundledTranslations.load(
      locales: ['en', 'fr'],
      bundle: bundle,
    );
    expect(b.locales, ['en', 'fr']);
    expect(b['fr']!.messages, {'hi': 'Salut'});
    expect(b['FR'], isNotNull);
    expect(b['de'], isNull);
    expect(bundle.reads, ['assets/i18n/en.arb', 'assets/i18n/fr.arb']);
  });

  test('a path that is not .arb is read as Tolgee JSON', () async {
    final b = await BundledTranslations.load(
      locales: ['en'],
      path: 'i18n/{locale}.json',
      bundle: MapBundle({'i18n/en.json': '{"a":{"b":"c"}}'}),
    );
    expect(b['en']!.messages, {'a.b': 'c'});
  });

  test('a missing locale file throws', () async {
    await expectLater(
      BundledTranslations.load(
        locales: ['en', 'de'],
        bundle: MapBundle({'assets/i18n/en.arb': '{}'}),
      ),
      throwsA(isA<FlutterError>()),
    );
  });

  test('fromMaps', () {
    final b = BundledTranslations.fromMaps({
      'en': {'a': 'A'},
    });
    expect(b['en']!.messages['a'], 'A');
  });
}
