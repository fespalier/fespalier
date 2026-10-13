import 'dart:convert';

import 'package:http/http.dart' as http;

import 'catalog.dart';
import 'source.dart';

/// The file format published to the CDN.
enum TolgeeCdnFormat {
  /// Tolgee JSON (ICU), nested or flat.
  json,

  /// Flutter `.arb`.
  arb,
}

/// Tolgee Content Delivery: public files, no API key (it has no parameter for one, by design).
/// Since 0.10.0.
final class TolgeeCdn implements TranslationSource {
  /// [base] is the Content Delivery URL Tolgee shows (`https://cdn.tolg.ee/<hash>/`); a file is
  /// `<base>/<namespace>/<locale>.<ext>`. [file] overrides the file name. [client] defaults to a
  /// new `http.Client`.
  TolgeeCdn(
    this.base, {
    this.format = TolgeeCdnFormat.json,
    this.namespace,
    this.file,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// The Content Delivery URL.
  final Uri base;

  /// The published format.
  final TolgeeCdnFormat format;

  /// A namespace folder, if the project uses them.
  final String? namespace;

  /// The file name for a locale, instead of `<locale>.<ext>`.
  final String Function(String locale)? file;

  final http.Client _client;

  /// The URL of [locale]'s file.
  Uri urlFor(String locale) {
    final name =
        file?.call(locale) ??
        '$locale.${format == TolgeeCdnFormat.arb ? 'arb' : 'json'}';
    final segments = [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      if (namespace != null && namespace!.isNotEmpty) namespace!,
      name,
    ];
    return base.replace(pathSegments: segments);
  }

  @override
  Future<RemoteCatalog?> fetch(String locale, {String? etag}) async {
    final response = await _client.get(
      urlFor(locale),
      headers: {'If-None-Match': ?etag},
    );
    if (response.statusCode == 304 || response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Tolgee CDN answered ${response.statusCode}',
        response.request?.url,
      );
    }
    final text = utf8.decode(response.bodyBytes);
    final catalog = format == TolgeeCdnFormat.arb
        ? Catalog.fromArb(locale, text)
        : Catalog.fromJson(locale, text);
    return RemoteCatalog(catalog, etag: response.headers['etag']);
  }
}
