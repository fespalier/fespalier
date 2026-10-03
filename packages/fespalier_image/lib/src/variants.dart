import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'builder.dart';
import 'cdn.dart';
import 'request.dart';

/// Whether [provider]'s image is in the image cache and ready to paint, read synchronously.
///
/// A provider whose key is not available synchronously (its `obtainKey` is not a
/// `SynchronousFuture`) never counts as loaded: nothing here waits.
bool isImageLoaded(ImageProvider<Object> provider) {
  final key = _syncKey(provider);
  if (key == null) return false;
  final status = PaintingBinding.instance.imageCache.statusForKey(key);
  return status.keepAlive || (status.live && !status.pending);
}

/// The cache status of [provider], read synchronously; null when its key is not available at
/// once.
ImageCacheStatus? imageStatusOf(ImageProvider<Object> provider) {
  final key = _syncKey(provider);
  if (key == null) return null;
  return PaintingBinding.instance.imageCache.statusForKey(key);
}

Object? _syncKey(ImageProvider<Object> provider) {
  final future = provider.obtainKey(ImageConfiguration.empty);
  if (future is! SynchronousFuture) return null;
  Object? key;
  unawaited(
    future.then<void>((Object? k) {
      key = k;
    }),
  );
  return key;
}

/// The providers the widgets and precaches of this isolate made, by source: so an image that is
/// loading can show the largest variant of the same picture that is already loaded, instead of a
/// placeholder.
///
/// Keyed by the builder, the CDN's provider factory and the source, so two CDNs (or the fakes of
/// two tests) never see each other's entries. A least-recently-used list of 256 sources, a few
/// widths each.
final class ImageVariants {
  ImageVariants._();

  static const int _maxSources = 256;
  static const int _maxPerSource = 24;

  static final LinkedHashMap<Object, List<_Variant>> _bySource =
      LinkedHashMap<Object, List<_Variant>>();

  static Object _key(
    ImageUrlBuilder builder,
    ImageProviderFactory? factory,
    String source,
  ) => (builder, factory, source);

  /// Records that [provider] loads [image] (made with [factory]).
  static void register(
    ResolvedImage image,
    ImageProviderFactory? factory,
    ImageProvider<Object> provider,
  ) {
    final key = _key(image.builder, factory, image.request.source);
    final variants = _bySource.remove(key) ?? <_Variant>[];
    variants
      ..removeWhere((v) => v.request == image.request)
      ..add(_Variant(image.request, provider));
    if (variants.length > _maxPerSource) variants.removeAt(0);
    _bySource[key] = variants;
    while (_bySource.length > _maxSources) {
      _bySource.remove(_bySource.keys.first);
    }
  }

  /// The widest loaded provider of the picture [like] is a variant of (any shape of the same
  /// source when [anyShape]), other than [except]; null when none is loaded.
  static ImageProvider<Object>? bestLoaded(
    ResolvedImage like,
    ImageProviderFactory? factory, {
    bool anyShape = false,
    ImageProvider<Object>? except,
  }) {
    final variants =
        _bySource[_key(like.builder, factory, like.request.source)];
    if (variants == null) return null;
    final candidates =
        variants
            .where(
              (v) =>
                  (anyShape || v.request.isVariantOf(like.request)) &&
                  v.provider != except,
            )
            .toList()
          ..sort((a, b) => b.request.width.compareTo(a.request.width));
    for (final v in candidates) {
      if (isImageLoaded(v.provider)) return v.provider;
    }
    return null;
  }

  /// Forgets everything (tests).
  @visibleForTesting
  static void clear() => _bySource.clear();
}

final class _Variant {
  const _Variant(this.request, this.provider);

  final ImageRequest request;
  final ImageProvider<Object> provider;
}
