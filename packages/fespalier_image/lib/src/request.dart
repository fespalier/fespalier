import 'package:flutter/foundation.dart';

/// The encoding asked for (since 0.9.0).
///
/// Flutter decodes webp, jpeg and png everywhere; avif only where the platform's decoder has it;
/// [auto] lets the CDN choose from the request's `Accept` header, which Flutter cannot steer
/// (`dart:io` sends none and a browser's XHR sends `*/*`), so it can answer an AVIF the platform
/// does not decode. Name a format.
enum ImageFormat {
  /// WebP (`webp`). The default.
  webp,

  /// JPEG (`jpg`; Thumbor's `format(jpeg)`).
  jpeg,

  /// PNG (`png`).
  png,

  /// AVIF (`avif`).
  avif,

  /// The CDN negotiates: EmgR `.auto`, imgproxy no extension, Cloudinary `f_auto`, imgix
  /// `auto=format`, Thumbor no `format()` filter.
  auto;

  /// The extension: `webp`, `jpg`, `png`, `avif` or `auto`.
  String get extension => switch (this) {
    webp => 'webp',
    jpeg => 'jpg',
    png => 'png',
    avif => 'avif',
    auto => 'auto',
  };
}

/// How a request with a height fits the source into width × height (since 0.9.0).
enum ImageResize {
  /// Cover the box and crop what overflows, centred (imgproxy `rs:fill`, Cloudinary `c_fill`,
  /// imgix `fit=crop`, Thumbor `WxH`). The default.
  fill,

  /// Fit inside the box, keeping the ratio (imgproxy `rs:fit`, Cloudinary `c_limit`, imgix
  /// `fit=max`, Thumbor `fit-in/WxH`).
  fit,
}

/// What a builder is asked for: one image at one size (since 0.9.0). Widths and heights are
/// physical pixels.
@immutable
final class ImageRequest {
  /// Asks for [source] at [width] (and [height]).
  const ImageRequest(
    this.source, {
    required this.width,
    this.height,
    this.resize = ImageResize.fill,
    this.quality,
    this.format = ImageFormat.webp,
    this.extra = const <String>[],
  });

  /// The app's name for the image: a path (`products/3.jpg`), a public id, a URL, or a srcset.
  final String source;

  /// Physical pixels, a bucket. At least 1.
  final int width;

  /// Physical pixels; null keeps the source's aspect ratio (a width-only resize).
  final int? height;

  /// Used only with a [height].
  final ImageResize resize;

  /// 1 to 100; null leaves it to the CDN (Cloudinary: `q_auto`).
  final int? quality;

  /// The encoding.
  final ImageFormat format;

  /// Provider-specific options, appended as each builder documents (an imgproxy segment `bl:2`,
  /// a Cloudinary component `e_grayscale`, an imgix `sat=-100`, a Thumbor filter
  /// `grayscale()`).
  final List<String> extra;

  /// Everything but the size and the shape: requests with an equal [pictureKey] show the same
  /// picture, in the same crop settings and encoding, at any width and height.
  Object get pictureKey =>
      (source, resize, quality, format, extra.join('\u0000'));

  /// Whether [other] is this picture at another size: the same [pictureKey] and, when there is a
  /// height, the same shape.
  ///
  /// A height is a width divided by a ratio and rounded to a pixel, so two sizes of one ratio
  /// differ by up to half a pixel on each side: the shapes are the same when their ratios are
  /// closer than that allows. A request without a height has no shape and is a variant of
  /// another without one only.
  bool isVariantOf(ImageRequest other) {
    if (pictureKey != other.pictureKey) return false;
    final h = height;
    final oh = other.height;
    if (h == null || oh == null) return h == null && oh == null;
    final tolerance = 0.5 / width + 0.5 / other.width + 1e-9;
    return (h / width - oh / other.width).abs() <= tolerance;
  }

  @override
  bool operator ==(Object other) =>
      other is ImageRequest &&
      other.source == source &&
      other.width == width &&
      other.height == height &&
      other.resize == resize &&
      other.quality == quality &&
      other.format == format &&
      listEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
    source,
    width,
    height,
    resize,
    quality,
    format,
    Object.hashAll(extra),
  );

  @override
  String toString() =>
      'ImageRequest($source, ${width}x${height ?? 0}, ${resize.name}, '
      'q=$quality, ${format.name})';
}
