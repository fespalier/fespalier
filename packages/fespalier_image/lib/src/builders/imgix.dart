import '../builder.dart';
import '../request.dart';
import 'common.dart';

/// imgix's rendering API (since 0.9.0): `https://{domain}/{path}?{parameters}`, the parameters
/// sorted by name.
///
/// Unsigned unless a [signer] adds `s`.
final class ImgixUrlBuilder extends ImageUrlBuilder {
  /// The source [domain], `demo.imgix.net`.
  const ImgixUrlBuilder({required this.domain, this.signer, this.https = true});

  /// A host name, without a scheme or a path.
  final String domain;

  /// Gets `/{path}?{query}` (the parameters sorted, without `s`) and returns the `s` value. Null:
  /// unsigned.
  final ImageSigner? signer;

  /// `https` (the default) or `http`.
  final bool https;

  @override
  String get name => 'imgix';

  @override
  String url(ImageRequest request) {
    if (domain.isEmpty || domain.contains('/') || domain.contains(':')) {
      throw ImageUrlError(
        'ImgixUrlBuilder: domain "$domain" must be a host name, like '
        '"demo.imgix.net", without a scheme or a path',
      );
    }
    final source = request.source;
    final path = hasScheme(source)
        ? '/${Uri.encodeComponent(source)}'
        : '/${(source.startsWith('/') ? source.substring(1) : source).split('/').map(Uri.encodeComponent).join('/')}';
    final height = request.height;
    final parameters = <String, String>{
      if (request.format == ImageFormat.auto)
        'auto': 'format'
      else
        'fm': request.format.extension,
      'fit': height != null && request.resize == ImageResize.fill
          ? 'crop'
          : 'max',
      if (height != null) 'h': '$height',
      if (request.quality != null) 'q': '${request.quality}',
      'w': '${request.width}',
    };
    // An extra replaces a built-in parameter of its name.
    for (final option in request.extra) {
      final at = option.indexOf('=');
      if (at < 0) {
        throw ImageUrlError(
          'ImgixUrlBuilder: extra option "$option" is not key=value, like '
          '"sat=-100"',
        );
      }
      parameters[option.substring(0, at)] = option.substring(at + 1);
    }
    final names = parameters.keys.toList()..sort();
    final query = names
        .map(
          (n) =>
              '${Uri.encodeQueryComponent(n)}='
              '${Uri.encodeQueryComponent(parameters[n]!)}',
        )
        .join('&');
    final signature = signer?.call('$path?$query');
    final s = signature == null ? '' : '&s=$signature';
    return '${https ? 'https' : 'http'}://$domain$path?$query$s';
  }

  @override
  bool operator ==(Object other) =>
      other is ImgixUrlBuilder &&
      other.domain == domain &&
      other.signer == signer &&
      other.https == https;

  @override
  int get hashCode => Object.hash(domain, signer, https);

  @override
  String toString() => 'ImgixUrlBuilder($domain)';
}
