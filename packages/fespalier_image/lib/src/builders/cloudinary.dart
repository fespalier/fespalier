import 'dart:convert';

import '../builder.dart';
import '../request.dart';
import 'common.dart';

/// Where a Cloudinary image comes from (since 0.9.0).
enum CloudinaryDelivery {
  /// An uploaded asset: the source is its public id.
  upload,

  /// A remote image Cloudinary fetches: the source is its URL.
  fetch,
}

/// Cloudinary's delivery URL (since 0.9.0): `{baseUrl}/{cloudName}/image/{upload|fetch}/
/// {transformation}/{source}`.
///
/// No signer: a signed Cloudinary URL needs the account's API secret, which also authorises
/// uploads and deletes, so the backend sends the signed URLs (a srcset, `SrcsetUrlBuilder`).
final class CloudinaryUrlBuilder extends ImageUrlBuilder {
  /// The cloud [cloudName].
  const CloudinaryUrlBuilder({
    required this.cloudName,
    this.delivery = CloudinaryDelivery.upload,
    this.baseUrl = 'https://res.cloudinary.com',
    this.forceVersion = true,
  });

  /// The cloud's name, `demo`.
  final String cloudName;

  /// Upload or fetch.
  final CloudinaryDelivery delivery;

  /// The delivery host; a CNAME (`https://images.example.com`) works too.
  final String baseUrl;

  /// Adds `v1/` before a public id that has a `/` and no version, as Cloudinary's SDKs do.
  final bool forceVersion;

  @override
  String get name => 'cloudinary';

  @override
  String url(ImageRequest request) {
    final base = checkBaseUrl('CloudinaryUrlBuilder', baseUrl);
    if (cloudName.isEmpty ||
        cloudName.contains('/') ||
        cloudName.contains(':')) {
      throw ImageUrlError(
        'CloudinaryUrlBuilder: cloudName "$cloudName" must be a cloud name, '
        'like "demo", not a URL or a path',
      );
    }
    final height = request.height;
    final crop = height != null && request.resize == ImageResize.fill
        ? 'fill'
        : 'limit';
    // Qualifiers sorted by key, as Cloudinary's SDKs write them.
    final main = <String>[
      'c_$crop',
      'f_${request.format.extension}',
      if (height != null) 'h_$height',
      'q_${request.quality ?? 'auto'}',
      'w_${request.width}',
    ].join(',');
    final id = request.source;
    final source = switch (delivery) {
      CloudinaryDelivery.upload =>
        forceVersion && id.contains('/') && !_versioned.hasMatch(id)
            ? 'v1/$id'
            : id,
      CloudinaryDelivery.fetch => _escape(id),
    };
    final kind = delivery == CloudinaryDelivery.upload ? 'upload' : 'fetch';
    return '$base/$cloudName/image/$kind/$main/'
        '${request.extra.map((e) => '$e/').join()}$source';
  }

  static final RegExp _versioned = RegExp(r'^v\d+/');

  /// Percent-encodes every byte outside `A-Za-z0-9 - _ . ! ~ * ' ( ) ; : @ & = + $ , /`.
  static String _escape(String url) {
    final out = StringBuffer();
    for (final byte in utf8.encode(url)) {
      final c = String.fromCharCode(byte);
      if (byte < 0x80 && _unreserved.hasMatch(c)) {
        out.write(c);
      } else {
        out
          ..write('%')
          ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return out.toString();
  }

  static final RegExp _unreserved = RegExp(r"[A-Za-z0-9\-_.!~*'();:@&=+$,/]");

  @override
  bool operator ==(Object other) =>
      other is CloudinaryUrlBuilder &&
      other.cloudName == cloudName &&
      other.delivery == delivery &&
      other.baseUrl == baseUrl &&
      other.forceVersion == forceVersion;

  @override
  int get hashCode => Object.hash(cloudName, delivery, baseUrl, forceVersion);

  @override
  String toString() => 'CloudinaryUrlBuilder($cloudName, ${delivery.name})';
}
