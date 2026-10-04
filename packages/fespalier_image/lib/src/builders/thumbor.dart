import '../builder.dart';
import '../request.dart';
import 'common.dart';

/// Thumbor's URL grammar (since 0.9.0); imagor reads the same.
///
/// `{baseUrl}/{signature}/{path}`, where the path is the resize, the filters and the image as
/// Thumbor reads it (`images.example.com/photo.jpg`, written as given: encode a query string
/// yourself). Unsigned (`unsafe`) unless a [signer] says otherwise, and Thumbor refuses `unsafe`
/// URLs unless it is configured to accept them.
final class ThumborUrlBuilder extends ImageUrlBuilder {
  /// Thumbor at [baseUrl].
  const ThumborUrlBuilder({
    required this.baseUrl,
    this.signer,
    this.smart = false,
  });

  /// The server (a trailing `/` is ignored).
  final String baseUrl;

  /// Gets the path after the signature, **without** a leading `/`, and returns the signature
  /// segment. Null: `unsafe`.
  final ImageSigner? signer;

  /// Adds `smart/` (focal-point detection).
  final bool smart;

  @override
  String get name => 'thumbor';

  @override
  String url(ImageRequest request) {
    final base = checkBaseUrl('ThumborUrlBuilder', baseUrl);
    final height = request.height;
    final filters = <String>[
      if (request.quality != null) 'quality(${request.quality})',
      if (request.format != ImageFormat.auto)
        'format(${request.format == ImageFormat.jpeg ? 'jpeg' : request.format.extension})',
      ...request.extra,
    ];
    final path = <String>[
      if (height != null && request.resize == ImageResize.fit) 'fit-in',
      '${request.width}x${height ?? 0}',
      if (smart) 'smart',
      if (filters.isNotEmpty) 'filters:${filters.join(':')}',
      request.source,
    ].join('/');
    final signature = signer?.call(path) ?? 'unsafe';
    return '$base/$signature/$path';
  }

  @override
  bool operator ==(Object other) =>
      other is ThumborUrlBuilder &&
      other.baseUrl == baseUrl &&
      other.signer == signer &&
      other.smart == smart;

  @override
  int get hashCode => Object.hash(baseUrl, signer, smart);

  @override
  String toString() => 'ThumborUrlBuilder($baseUrl)';
}
