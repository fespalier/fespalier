import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:fespalier_tolgee/src/providers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  ProviderContainer make(Translations c, {List<Override> more = const []}) {
    final container = ProviderContainer(
      overrides: [translationsConfig.overrideWithValue(c), ...more],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('exact > language > base > key', () {
    final c = make(
      config(
        bundled: {
          'en': {'a': 'en a', 'b': 'en b', 'c': 'en c'},
          'fr': {'a': 'fr a', 'b': 'fr b'},
          'fr-CA': {'a': 'fr-CA a'},
        },
      ),
    );
    final t = c.read(translator('fr-CA'));
    expect(t.locale, 'fr-CA');
    expect(t.tr('a'), 'fr-CA a');
    expect(t.tr('b'), 'fr b');
    expect(t.tr('c'), 'en c');
    expect(t.tr('zzz'), 'zzz');
    expect(t.maybeTr('zzz'), isNull);
    expect(t.has('c'), isTrue);
    expect(t.originOf('a'), TranslationOrigin.bundled);
    expect(t.originOf('b'), TranslationOrigin.fallbackLocale);
    expect(t.originOf('zzz'), TranslationOrigin.missing);
  });

  test('fr-CA resolves to fr when only fr is bundled; pt_BR equals pt-BR', () {
    final c = make(
      config(
        bundled: {
          'en': {'a': 'en'},
          'fr': {'a': 'fr'},
          'pt-BR': {'a': 'pt'},
        },
      ),
    );
    expect(c.read(translator('fr-CA')).locale, 'fr');
    expect(c.read(translator('pt_BR')).locale, 'pt-BR');
    expect(c.read(translator('PT-br')).tr('a'), 'pt');
    expect(c.read(translator('xx')).locale, 'en');
  });

  test('the base locale must be bundled', () {
    final c = make(config(base: 'de'));
    expect(() => c.read(translator('en')), throwsA(anything));
  });

  test('remote and cached win over bundled; edited wins over both', () {
    final c = make(
      config(
        bundled: {
          'en': {'a': 'bundled'},
        },
      ),
    );
    c
        .read(remoteStore.notifier)
        .put(
          'en',
          HeldCatalog(
            const Catalog('en', {'a': 'remote'}),
            null,
            TranslationOrigin.remote,
          ),
        );
    expect(c.read(translator('en')).tr('a'), 'remote');
    expect(c.read(translator('en')).originOf('a'), TranslationOrigin.remote);
    c.read(translationEdits.notifier).set('en', 'a', 'edited');
    expect(c.read(translator('en')).tr('a'), 'edited');
    expect(c.read(translator('en')).originOf('a'), TranslationOrigin.edited);
  });

  test('no translations: every key is itself', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(translator('fr')).tr('some.key'), 'some.key');
  });

  test('Translations.resolve', () {
    final t = config(bundled: {'en': {}, 'fr': {}, 'pt-BR': {}});
    expect(t.resolve('fr-CA'), 'fr');
    expect(t.resolve('PT_br'), 'pt-BR');
    expect(t.resolve('pt'), isNull);
    expect(t.resolve(null), isNull);
    expect(t.resolve('de'), isNull);
  });
}
