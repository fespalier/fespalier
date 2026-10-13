import 'package:fespalier/fespalier.dart' show sameLocale;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'catalog.dart';

/// The translations shipped in the app (assets): what the first launch shows, offline included
/// (since 0.10.0).
@immutable
final class BundledTranslations {
  /// Catalogs already in memory (tests, or a const map of your own).
  const BundledTranslations(this._catalogs);

  /// From plain maps: `{'en': {'hello': 'Hello {name}'}}`.
  factory BundledTranslations.fromMaps(Map<String, Map<String, String>> maps) =>
      BundledTranslations({
        for (final MapEntry(:key, :value) in maps.entries)
          key: Catalog(key, value),
      });

  /// Reads one file per locale from [bundle] (default `rootBundle`): [path] with `{locale}`
  /// replaced. A path ending in `.arb` is read as ARB, anything else as Tolgee JSON. A missing
  /// file is an error, thrown, so `startup()` fails and `splash.dart` can offer a retry. A local
  /// read, never the network.
  static Future<BundledTranslations> load({
    required Iterable<String> locales,
    String path = 'assets/i18n/{locale}.arb',
    AssetBundle? bundle,
  }) async {
    final source = bundle ?? rootBundle;
    final catalogs = <String, Catalog>{};
    for (final locale in locales) {
      final file = path.replaceAll('{locale}', locale);
      final text = await source.loadString(file, cache: false);
      catalogs[locale] = file.endsWith('.arb')
          ? Catalog.fromArb(locale, text)
          : Catalog.fromJson(locale, text);
    }
    return BundledTranslations(catalogs);
  }

  final Map<String, Catalog> _catalogs;

  /// The bundled locale tags, in the order given: the app's supported locales.
  Iterable<String> get locales => _catalogs.keys;

  /// The catalog for exactly [locale] (case and `_` or `-` do not matter), or null.
  Catalog? operator [](String locale) {
    final exact = _catalogs[locale];
    if (exact != null) return exact;
    for (final MapEntry(:key, :value) in _catalogs.entries) {
      if (sameLocale(key, locale)) return value;
    }
    return null;
  }
}
