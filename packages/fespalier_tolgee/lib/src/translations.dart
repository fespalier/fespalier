import 'package:fespalier/fespalier.dart' show sameLocale;
import 'package:flutter/foundation.dart';

import 'bundled.dart';
import 'source.dart';

/// The app's translation setup, given once in `startup.dart`'s `startup()` (since 0.10.0).
@immutable
final class Translations {
  /// [bundled] is the offline fallback; [baseLocale] the last link of every chain (it must be
  /// bundled); [remote] the over-the-air source (null: bundled only, no network).
  /// [refreshOnResume] and [refreshOnReconnect] ask [remote] again on fespalier's
  /// `appResumeSignal` / `reconnectSignal` (the second only after a failed fetch). [cacheMaxAge]
  /// is how long a cached remote catalog is used. [onMissing] hears each key `tr` could not find
  /// (tests use it to fail on a typo).
  const Translations({
    required this.bundled,
    required this.baseLocale,
    this.remote,
    this.refreshOnResume = false,
    this.refreshOnReconnect = true,
    this.cacheMaxAge = const Duration(days: 30),
    this.onMissing,
  });

  /// No translations: every key is itself. The default of `translationsConfig`.
  static const Translations none = Translations(
    bundled: BundledTranslations({}),
    baseLocale: '',
    refreshOnReconnect: false,
  );

  /// The offline fallback.
  final BundledTranslations bundled;

  /// The last link of every chain.
  final String baseLocale;

  /// Where fresh translations come from; null for none.
  final TranslationSource? remote;

  /// Ask [remote] again when the app resumes.
  final bool refreshOnResume;

  /// Ask [remote] again when the network is back, after a failed fetch.
  final bool refreshOnReconnect;

  /// How long a cached remote catalog is used.
  final Duration cacheMaxAge;

  /// Called with the locale and the key when `Translator.tr` finds nothing.
  final void Function(String locale, String key)? onMissing;

  /// [bundled]'s locales.
  Iterable<String> get supportedLocales => bundled.locales;

  /// [requested] resolved against [supportedLocales]: the exact tag, then its language
  /// (`fr-CA` to `fr`), else null. Tags compare like fespalier's `sameLocale` (case, and `_` is `-`).
  String? resolve(String? requested) {
    if (requested == null || requested.isEmpty) return null;
    final language = requested.split(RegExp('[-_]')).first;
    String? byLanguage;
    for (final tag in supportedLocales) {
      if (sameLocale(tag, requested)) return tag;
      if (byLanguage == null && sameLocale(tag, language)) byLanguage = tag;
    }
    return byLanguage;
  }
}
