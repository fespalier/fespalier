import 'package:flutter/foundation.dart';

import 'catalog.dart';

/// Where fresh translations come from (Tolgee's CDN, your own server, a fake). Asked at most once
/// per locale per ProviderContainer, plus on resume or reconnect when `Translations` says so.
/// Never on a timer (since 0.10.0).
abstract interface class TranslationSource {
  /// The messages for [locale] now at the source; null when they have not changed since [etag]
  /// (a 304) or the source has none for [locale] (a 404). A failure throws; the app keeps what it has.
  Future<RemoteCatalog?> fetch(String locale, {String? etag});
}

/// A fetched catalog and the validator to send next time.
@immutable
final class RemoteCatalog {
  /// [catalog] as fetched; [etag] from the response, if any.
  const RemoteCatalog(this.catalog, {this.etag});

  /// The fetched messages.
  final Catalog catalog;

  /// The response's ETag, sent back as `If-None-Match`.
  final String? etag;
}
