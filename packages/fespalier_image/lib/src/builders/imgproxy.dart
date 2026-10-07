import 'dart:convert';

import '../builder.dart';
import '../request.dart';
import 'common.dart';

/// How [ImgproxyUrlBuilder] writes the source (since 0.9.0).
enum ImgproxySourceEncoding {
  /// URL-safe base64 without padding, then `.{extension}`. The default; the same on imgproxy and
  /// EmgR.
  base64,

  /// `plain/` and the percent-encoded URL, then `@{extension}` (imgproxy) or `.{extension}`
  /// (EmgR).
  plain,
}

/// imgproxy's URL grammar (since 0.9.0), and EmgR's with [ImgproxyUrlBuilder.emgr].
///
/// `{baseUrl}/{signature}/{options}/{source}`. Unsigned by default (see [signer]): a server that
/// accepts that must also limit what it fetches and the options it takes (docs/responsive-images.md,
/// "Signed image URLs").
final class ImgproxyUrlBuilder extends ImageUrlBuilder {
  /// imgproxy at [baseUrl]: unsigned URLs say `insecure`.
  const ImgproxyUrlBuilder({
    required this.baseUrl,
    this.sourceBase = '',
    this.signer,
    this.encoding = ImgproxySourceEncoding.base64,
    this.processing = ImgproxyUrlBuilder.resizeOptions,
  }) : unsignedSignature = 'insecure',
       _emgr = false;

  /// EmgR (vaam-apps/image-resizer) at [baseUrl]: unsigned URLs say `unsigned`, a plain source
  /// takes its extension after a dot, and [ImageFormat.auto] is the `.auto` extension.
  const ImgproxyUrlBuilder.emgr({
    required this.baseUrl,
    this.sourceBase = '',
    this.signer,
    this.encoding = ImgproxySourceEncoding.base64,
    this.processing = ImgproxyUrlBuilder.resizeOptions,
  }) : unsignedSignature = 'unsigned',
       _emgr = true;

  /// The server, `https://img.example.com` (a trailing `/` is ignored).
  final String baseUrl;

  /// Put before a source that has no scheme: `https://images.example.com/` makes
  /// `products/3.jpg` that URL.
  final String sourceBase;

  /// Gets the path after the signature (`/rs:fill:640:640/aHR0….webp`, leading `/` included) and
  /// returns the signature segment. Null: [unsignedSignature].
  final ImageSigner? signer;

  /// How the source is written.
  final ImgproxySourceEncoding encoding;

  /// The processing options of a request, in order; [resizeOptions] by default. Presets only:
  /// `processing: (r) => ['pr:w${r.width}']`.
  final List<String> Function(ImageRequest request) processing;

  /// What an unsigned URL has where the signature goes: `insecure` (imgproxy) or `unsigned`
  /// (EmgR).
  final String unsignedSignature;

  final bool _emgr;

  /// `rs:fill:W:H` (`rs:fit:W:H` for [ImageResize.fit]; `rs:fit:W:0` without a height), then
  /// `q:Q` when the request has a quality, then the request's extra.
  static List<String> resizeOptions(ImageRequest request) {
    final height = request.height;
    final mode = height != null && request.resize == ImageResize.fill
        ? 'fill'
        : 'fit';
    return <String>[
      'rs:$mode:${request.width}:${height ?? 0}',
      if (request.quality != null) 'q:${request.quality}',
      ...request.extra,
    ];
  }

  @override
  String get name => _emgr ? 'emgr' : 'imgproxy';

  @override
  String url(ImageRequest request) {
    final base = checkBaseUrl('ImgproxyUrlBuilder', baseUrl);
    final raw = hasScheme(request.source)
        ? request.source
        : '$sourceBase${request.source}';
    final auto = request.format == ImageFormat.auto;
    final extension = request.format.extension;
    final String source;
    switch (encoding) {
      case ImgproxySourceEncoding.base64:
        final encoded = base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
        source = '$encoded${auto && !_emgr ? '' : '.$extension'}';
      case ImgproxySourceEncoding.plain:
        final encoded = Uri.encodeComponent(raw);
        final suffix = _emgr
            ? '.$extension'
            : auto
            ? ''
            : '@$extension';
        source = 'plain/$encoded$suffix';
    }
    final options = processing(request);
    final path = options.isEmpty ? '/$source' : '/${options.join('/')}/$source';
    final signature = signer?.call(path) ?? unsignedSignature;
    return '$base/$signature$path';
  }

  @override
  bool operator ==(Object other) =>
      other is ImgproxyUrlBuilder &&
      other._emgr == _emgr &&
      other.baseUrl == baseUrl &&
      other.sourceBase == sourceBase &&
      other.signer == signer &&
      other.encoding == encoding &&
      other.processing == processing;

  @override
  int get hashCode =>
      Object.hash(_emgr, baseUrl, sourceBase, signer, encoding, processing);

  @override
  String toString() => 'ImgproxyUrlBuilder($name, $baseUrl)';
}
