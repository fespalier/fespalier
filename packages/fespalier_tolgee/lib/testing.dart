/// What tests use from fespalier_tolgee (since 0.10.0).
library;

import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:fespalier_tolgee/in_context.dart' show TranslationEditor;
import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:http/http.dart' as http;

export 'package:fespalier/fespalier.dart' show MemoryDataStorage;
export 'package:fespalier_tolgee/in_context.dart' show TranslationEditor;

/// A TranslationSource for tests: catalogs in memory per locale. It completes with an already
/// completed `Future`: no delay, no timer.
final class FakeTranslations implements TranslationSource {
  /// An empty source; fill it with [set].
  FakeTranslations() : strict = false;

  /// Like [FakeTranslations.new], but a key no catalog has is reported through
  /// `FlutterError.reportError` (library `fespalier_tolgee`), so a `testWidgets` fails on a typo
  /// (use it with [fakeTranslations]).
  FakeTranslations.strict() : strict = true;

  /// Whether a missing key fails the test.
  final bool strict;

  final _messages = <String, Map<String, String>>{};
  final _fetches = <String, int>{};
  var _offline = false;
  var _notModified = false;

  /// Sets the messages the source has for [locale].
  void set(String locale, Map<String, String> messages) {
    _messages[locale] = {...messages};
  }

  /// From now on, `fetch` throws an `http.ClientException`.
  void offline() => _offline = true;

  /// From now on, `fetch` answers like a 304: null.
  void notModified() => _notModified = true;

  /// Undoes [offline] and [notModified].
  void online() {
    _offline = false;
    _notModified = false;
  }

  /// How many times [locale] was fetched.
  int fetchCount(String locale) => _fetches[locale] ?? 0;

  @override
  Future<RemoteCatalog?> fetch(String locale, {String? etag}) {
    _fetches[locale] = fetchCount(locale) + 1;
    if (_offline) {
      return Future.error(http.ClientException('FakeTranslations is offline'));
    }
    final messages = _messages[locale];
    if (_notModified || messages == null) return Future.value();
    return Future.value(
      RemoteCatalog(Catalog(locale, messages), etag: 'fake-${messages.length}'),
    );
  }
}

/// The overrides for `pumpRouter` or `test/routes/setup.dart`: [bundled] translations (locale to
/// key to message), [base] locale, and [remote] if the test has one. [strict] (or a
/// [FakeTranslations.strict] remote) fails the test on a key no catalog has.
List<Override> fakeTranslations({
  required Map<String, Map<String, String>> bundled,
  String base = 'en',
  FakeTranslations? remote,
  bool strict = false,
  Duration cacheMaxAge = const Duration(days: 30),
}) => [
  translationsConfig.overrideWithValue(
    Translations(
      bundled: BundledTranslations.fromMaps(bundled),
      baseLocale: base,
      remote: remote,
      cacheMaxAge: cacheMaxAge,
      onMissing: strict || (remote?.strict ?? false)
          ? (locale, key) => FlutterError.reportError(
              FlutterErrorDetails(
                exception: StateError(
                  'No translation for "$key" in $locale or its fallbacks',
                ),
                library: 'fespalier_tolgee',
              ),
            )
          : null,
    ),
  ),
];

/// A TranslationEditor that records what it was asked to save.
final class RecordingEditor implements TranslationEditor {
  /// Every save, in order: key, locale, text.
  final saved = <({String key, String locale, String text})>[];

  @override
  Future<void> save(String key, String locale, String text) async {
    saved.add((key: key, locale: locale, text: text));
  }
}
