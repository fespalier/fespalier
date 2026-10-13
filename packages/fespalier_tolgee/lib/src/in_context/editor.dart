import 'dart:convert';

import 'package:fespalier/fespalier.dart' show Provider;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Whether in-context editing is compiled in: never in a release or profile build, and only with
/// `--dart-define=fespalier_tolgee.in_context=true`. Release builds keep none of it (since 0.10.0).
const bool kTolgeeInContext =
    !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile') &&
    bool.fromEnvironment('fespalier_tolgee.in_context');

// The key is read here and nowhere else, behind kTolgeeInContext: in release the compiler folds it away.
const _key = kTolgeeInContext ? String.fromEnvironment('TOLGEE_API_KEY') : '';
const _url = String.fromEnvironment(
  'TOLGEE_API_URL',
  defaultValue: 'https://app.tolgee.io',
);

/// Saves an edited translation somewhere (Tolgee's API, a recording fake).
abstract interface class TranslationEditor {
  /// Sets [key] in [locale] to [text] at the platform.
  Future<void> save(String key, String locale, String text);
}

/// The Tolgee editor. Its key comes only from `--dart-define=TOLGEE_API_KEY` (use a gitignored
/// `--dart-define-from-file`), read behind [kTolgeeInContext]. It has no public constructor that
/// takes a key.
final class TolgeeEditor implements TranslationEditor {
  TolgeeEditor._(this._apiUrl, this._apiKey, http.Client? client)
    : _client = client ?? http.Client();

  /// The editor from the environment (`TOLGEE_API_URL`, default `https://app.tolgee.io`), or null
  /// when [kTolgeeInContext] is false or no key was defined.
  static TolgeeEditor? fromEnvironment({http.Client? client}) {
    if (!kTolgeeInContext || _key.isEmpty) return null;
    return TolgeeEditor._(Uri.parse(_url), _key, client);
  }

  /// For this package's tests only.
  @visibleForTesting
  TolgeeEditor.withKey(Uri apiUrl, String apiKey, {http.Client? client})
    : this._(apiUrl, apiKey, client);

  final Uri _apiUrl;
  final String _apiKey;
  final http.Client _client;

  @override
  Future<void> save(String key, String locale, String text) async {
    final base = _apiUrl.pathSegments.where((s) => s.isNotEmpty);
    final response = await _client.put(
      _apiUrl.replace(
        pathSegments: [...base, 'v2', 'projects', 'translations'],
      ),
      headers: {'X-API-Key': _apiKey, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'key': key,
        'translations': {locale: text},
      }),
    );
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw http.ClientException(
        'Tolgee answered ${response.statusCode} to a save of "$key"',
        response.request?.url,
      );
    }
  }
}

/// The editor the scope's panel uses: `TolgeeEditor.fromEnvironment()` by default (null outside
/// in-context builds).
final translationEditor = Provider<TranslationEditor?>(
  (ref) => TolgeeEditor.fromEnvironment(),
  name: 'translationEditor',
);
