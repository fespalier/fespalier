import 'package:flutter/foundation.dart';

import 'builder.dart';

/// The widths, in physical pixels, an image may be asked for (since 0.9.0).
///
/// A CDN caches by URL: a few widths keep the hit rate high, and make the URL a precache computes
/// equal to the one the page later asks for.
@immutable
final class ImageBuckets {
  /// [widths] must be positive and strictly increasing (checked when used: [pick] throws an
  /// [ImageUrlError]).
  const ImageBuckets(this.widths);

  /// Next.js 16's defaults (`imageSizes`, then `deviceSizes`), in physical pixels.
  static const ImageBuckets standard = ImageBuckets(<int>[
    32,
    48,
    64,
    96,
    128,
    256,
    384,
    640,
    750,
    828,
    1080,
    1200,
    1920,
    2048,
    3840,
  ]);

  /// The widths, increasing.
  final List<int> widths;

  /// The smallest width that is at least [needed]; the largest when none is.
  int pick(int needed) {
    if (widths.isEmpty || widths.first <= 0) throw _bad();
    for (var i = 1; i < widths.length; i++) {
      if (widths[i] <= widths[i - 1]) throw _bad();
    }
    for (final width in widths) {
      if (width >= needed) return width;
    }
    return widths.last;
  }

  ImageUrlError _bad() => ImageUrlError(
    'ImageBuckets: the widths must be positive and increasing, got $widths',
  );

  /// The physical pixels [logical] needs at [devicePixelRatio], capped at [maxPixelRatio], with
  /// half a pixel of tolerance: `(logical × min(devicePixelRatio, maxPixelRatio) − 0.5).ceil()`,
  /// at least 1. 0 when [logical] is not a positive finite number (nothing is fetched).
  static int physical(
    double logical,
    double devicePixelRatio, {
    double maxPixelRatio = 3,
  }) {
    if (!logical.isFinite || logical <= 0) return 0;
    final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    final capped = ratio < maxPixelRatio ? ratio : maxPixelRatio;
    final needed = (logical * capped - 0.5).ceil();
    return needed < 1 ? 1 : needed;
  }

  @override
  bool operator ==(Object other) =>
      other is ImageBuckets && listEquals(other.widths, widths);

  @override
  int get hashCode => Object.hashAll(widths);

  @override
  String toString() => 'ImageBuckets($widths)';
}
