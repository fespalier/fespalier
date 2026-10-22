import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart'
    show HttpTransport, TransportRequest, TransportStatusError;

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
  /// `<base>/<namespace>/<locale>.<ext>`. [file] overrides the file name. The files are fetched
  /// through [transport] (since 0.21.0; it was an optional `client:`, an `http.Client`): the app's
  /// own, so its timeouts, proxy and telemetry apply. There is no default.
  TolgeeCdn(
    this.base, {
    required this.transport,
    this.format = TolgeeCdnFormat.json,
    this.namespace,
    this.file,
  });

  /// The Content Delivery URL.
  final Uri base;

  /// The published format.
  final TolgeeCdnFormat format;

  /// A namespace folder, if the project uses them.
  final String? namespace;

  /// The file name for a locale, instead of `<locale>.<ext>`.
  final String Function(String locale)? file;

  /// What the files are fetched through.
  final HttpTransport transport;

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
    final response = await transport.send(
      TransportRequest(
        method: 'GET',
        uri: urlFor(locale),
        headers: {'If-None-Match': ?etag},
      ),
    );
    // Read whatever the status: an unread body would hold the connection.
    final bytes = await response.bytes();
    if (response.statusCode == 304 || response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      // A refusal: its status is the whole story (what the CDN said is not kept).
      throw TransportStatusError(
        statusCode: response.statusCode,
        headers: response.headers,
        body: Uint8List(0),
        reasonPhrase: response.reasonPhrase,
      );
    }
    final text = utf8.decode(bytes);
    final catalog = format == TolgeeCdnFormat.arb
        ? Catalog.fromArb(locale, text)
        : Catalog.fromJson(locale, text);
    return RemoteCatalog(catalog, etag: response.headers['etag']);
  }
}
