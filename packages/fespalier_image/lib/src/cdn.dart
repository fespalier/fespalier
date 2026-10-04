import 'package:fespalier/fespalier.dart' show Provider;
import 'package:flutter/widgets.dart';

import 'buckets.dart';
import 'builder.dart';
import 'builders/direct.dart';
import 'request.dart';

/// Makes the image provider of a URL (since 0.9.0).
typedef ImageProviderFactory = ImageProvider<Object> Function(String url);

/// Builds what a failed image shows; [retry] loads it again (since 0.9.0).
typedef ResponsiveImageErrorBuilder =
    Widget Function(BuildContext context, Object error, VoidCallback retry);

/// The app's image CDN and its defaults (since 0.9.0). `const ImageCdn()` is no CDN: sources are
/// URLs, fetched as they are.
///
/// ```dart
/// imageCdnProvider.overrideWithValue(
///   const ImageCdn(
///     builder: ImgproxyUrlBuilder.emgr(baseUrl: 'https://img.example.com'),
///   ),
/// )
/// ```
@immutable
final class ImageCdn {
  /// A CDN that [builder] makes the URLs of.
  const ImageCdn({
    this.builder = const DirectUrlBuilder(),
    this.buckets = ImageBuckets.standard,
    this.format = ImageFormat.webp,
    this.quality,
    this.maxPixelRatio = 3,
    this.providerFactory,
    this.webHtmlElementStrategy = WebHtmlElementStrategy.never,
    this.placeholder,
    this.errorBuilder,
    this.fadeIn = Duration.zero,
  });

  /// Makes each URL.
  final ImageUrlBuilder builder;

  /// The widths asked for.
  final ImageBuckets buckets;

  /// The encoding asked for.
  final ImageFormat format;

  /// The quality asked for; null leaves it to the CDN.
  final int? quality;

  /// Device pixel ratios above it ask for this one's width (bytes and memory on 3.5× phones).
  final double maxPixelRatio;

  /// The provider of a URL; null: `NetworkImage(url, webHtmlElementStrategy:
  /// webHtmlElementStrategy)`. Plug a disk cache in here (`CachedNetworkImageProvider.new`).
  final ImageProviderFactory? providerFactory;

  /// On the web, whether a failed fetch falls back to an `<img>` element (README, "Images on the
  /// web").
  final WebHtmlElementStrategy webHtmlElementStrategy;

  /// What shows while an image loads; null: a box in the theme's `surfaceContainerHighest`.
  final WidgetBuilder? placeholder;

  /// What a failed image shows; null: that box with a broken-image icon.
  final ResponsiveImageErrorBuilder? errorBuilder;

  /// How long a loaded image fades in; zero (the default) shows it at once.
  final Duration fadeIn;

  /// A copy with the given fields replaced.
  ImageCdn copyWith({
    ImageUrlBuilder? builder,
    ImageBuckets? buckets,
    ImageFormat? format,
    int? quality,
    double? maxPixelRatio,
    ImageProviderFactory? providerFactory,
    WebHtmlElementStrategy? webHtmlElementStrategy,
    WidgetBuilder? placeholder,
    ResponsiveImageErrorBuilder? errorBuilder,
    Duration? fadeIn,
  }) => ImageCdn(
    builder: builder ?? this.builder,
    buckets: buckets ?? this.buckets,
    format: format ?? this.format,
    quality: quality ?? this.quality,
    maxPixelRatio: maxPixelRatio ?? this.maxPixelRatio,
    providerFactory: providerFactory ?? this.providerFactory,
    webHtmlElementStrategy:
        webHtmlElementStrategy ?? this.webHtmlElementStrategy,
    placeholder: placeholder ?? this.placeholder,
    errorBuilder: errorBuilder ?? this.errorBuilder,
    fadeIn: fadeIn ?? this.fadeIn,
  );

  /// What a `ResponsiveImage` [logicalWidth] wide asks for (pure: for tests, and what `precache`
  /// uses). Null when there is nothing to fetch (a width that is not positive). Throws an
  /// [ImageUrlError] when misconfigured.
  ///
  /// The width is [logicalWidth] × [devicePixelRatio] (at most [maxPixelRatio]) rounded up to a
  /// bucket, or to a width the source has ([ImageUrlBuilder.widthsOf]). With an [aspectRatio] the
  /// request has a height of that shape, and the CDN crops to it ([resize]).
  ResolvedImage? resolve(
    String source, {
    required double logicalWidth,
    required double devicePixelRatio,
    double? aspectRatio,
    ImageResize resize = ImageResize.fill,
    int? quality,
    ImageFormat? format,
    List<String> extra = const <String>[],
    ImageUrlBuilder? builder,
    ImageBuckets? buckets,
  }) {
    final b = builder ?? this.builder;
    final needed = ImageBuckets.physical(
      logicalWidth,
      devicePixelRatio,
      maxPixelRatio: maxPixelRatio,
    );
    if (needed == 0) return null;
    final widths = b.widthsOf(source);
    final width =
        (widths != null ? ImageBuckets(widths) : (buckets ?? this.buckets))
            .pick(needed);
    int? height;
    if (aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0) {
      final h = (width / aspectRatio).round();
      height = h < 1 ? 1 : h;
    }
    final request = ImageRequest(
      source,
      width: width,
      height: height,
      resize: resize,
      quality: quality ?? this.quality,
      format: format ?? this.format,
      extra: extra,
    );
    return ResolvedImage(request, b.url(request), b);
  }

  /// The image provider of [image]: [providerFactory]'s or a `NetworkImage`, in a `ResizeImage`
  /// of the request's width (`ResizeImagePolicy.fit`, no upscaling) when the builder doesn't
  /// resize.
  ImageProvider<Object> providerFor(ResolvedImage image) {
    final factory = providerFactory;
    final provider = factory != null
        ? factory(image.url)
        : NetworkImage(
            image.url,
            webHtmlElementStrategy: webHtmlElementStrategy,
          );
    if (image.builder.resizes) return provider;
    return ResizeImage(
      provider,
      width: image.request.width,
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImageCdn &&
      other.builder == builder &&
      other.buckets == buckets &&
      other.format == format &&
      other.quality == quality &&
      other.maxPixelRatio == maxPixelRatio &&
      other.providerFactory == providerFactory &&
      other.webHtmlElementStrategy == webHtmlElementStrategy &&
      other.placeholder == placeholder &&
      other.errorBuilder == errorBuilder &&
      other.fadeIn == fadeIn;

  @override
  int get hashCode => Object.hash(
    builder,
    buckets,
    format,
    quality,
    maxPixelRatio,
    providerFactory,
    webHtmlElementStrategy,
    placeholder,
    errorBuilder,
    fadeIn,
  );
}

/// One image at one size: the request and its URL (since 0.9.0).
@immutable
final class ResolvedImage {
  /// [request] made into [url] by [builder].
  const ResolvedImage(this.request, this.url, this.builder);

  /// What was asked for.
  final ImageRequest request;

  /// Its URL.
  final String url;

  /// What made it.
  final ImageUrlBuilder builder;
}

/// The app's image CDN (since 0.9.0): no CDN until `startup()` overrides it,
/// `imageCdnProvider.overrideWithValue(const ImageCdn(builder: ...))`.
///
/// Scoped (`dependencies: const []`), so a subtree can override it in a nested `ProviderScope`; a
/// provider that reads it must list it in its own `dependencies`.
final Provider<ImageCdn> imageCdnProvider = Provider<ImageCdn>(
  (ref) => const ImageCdn(),
  dependencies: const [],
  name: 'imageCdnProvider',
);
