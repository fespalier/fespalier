import 'dart:convert';

import 'package:fespalier/fespalier.dart' show Provider;
import 'package:fespalier_transport/fespalier_transport.dart'
    show HttpTransport, TransportRequest, TransportStatusError;
import 'package:flutter/foundation.dart';

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
  TolgeeEditor._(this._apiUrl, this._apiKey, this._transport);

  /// The editor from the environment (`TOLGEE_API_URL`, default `https://app.tolgee.io`), saving
  /// through [transport], or null when [kTolgeeInContext] is false or no key was defined.
  static TolgeeEditor? fromEnvironment({required HttpTransport transport}) {
    if (!kTolgeeInContext || _key.isEmpty) return null;
    return TolgeeEditor._(Uri.parse(_url), _key, transport);
  }

  /// For this package's tests only.
  @visibleForTesting
  TolgeeEditor.withKey(
    Uri apiUrl,
    String apiKey, {
    required HttpTransport transport,
  }) : this._(apiUrl, apiKey, transport);

  final Uri _apiUrl;
  final String _apiKey;
  final HttpTransport _transport;

  @override
  Future<void> save(String key, String locale, String text) async {
    final base = _apiUrl.pathSegments.where((s) => s.isNotEmpty);
    final response = await _transport.send(
      TransportRequest(
        method: 'PUT',
        uri: _apiUrl.replace(
          pathSegments: [...base, 'v2', 'projects', 'translations'],
        ),
        headers: {'X-API-Key': _apiKey, 'Content-Type': 'application/json'},
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'key': key,
              'translations': {locale: text},
            }),
          ),
        ),
      ),
    );
    // Read whatever the status: an unread body would hold the connection.
    await response.bytes();
    if (response.statusCode < 200 || response.statusCode > 299) {
      // The status is the whole story: neither the key nor what Tolgee said is kept.
      throw TransportStatusError(
        statusCode: response.statusCode,
        headers: response.headers,
        body: Uint8List(0),
        reasonPhrase: response.reasonPhrase,
      );
    }
  }
}

/// The transport the in-context editor saves through (since 0.21.0; it was an `http.Client` the
/// editor made itself). It has **no default** and is read only by an in-context build that has a
/// key (a release build never reads it): override it with the app's transport in the debug
/// configuration that turns in-context editing on.
final tolgeeEditorTransport = Provider<HttpTransport>(
  (ref) => throw StateError(
    'tolgeeEditorTransport has no default: override it in the ProviderScope with the app\'s '
    'HttpTransport in the build that turns in-context editing on.',
  ),
  name: 'tolgeeEditorTransport',
);

/// The editor the scope's panel uses: `TolgeeEditor.fromEnvironment(transport:)` over
/// [tolgeeEditorTransport] by default (null outside in-context builds, and without a key).
final translationEditor = Provider<TranslationEditor?>(
  (ref) => !kTolgeeInContext || _key.isEmpty
      ? null
      : TolgeeEditor.fromEnvironment(
          transport: ref.watch(tolgeeEditorTransport),
        ),
  name: 'translationEditor',
);
