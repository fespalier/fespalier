/// Test doubles for fespalier_image (since 0.9.0).
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'src/cdn.dart';

/// Image loads without a network, for widget tests (since 0.9.0): a `providerFactory` whose
/// providers record each URL and complete when the test says (or at once). Deterministic: no
/// timer, no real I/O.
///
/// ```dart
/// final fakes = FakeImages(image: image); // `await createTestImage()` in setUpAll
/// // ... overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(shopImages))]
/// expect(fakes.requested, [...]);
/// ```
final class FakeImages {
  /// With [image] (flutter_test's `createTestImage()`, made in `setUpAll`), every load completes
  /// at once, in the frame that asks for it. Without it, each load waits for [complete] or
  /// [fail].
  FakeImages({ui.Image? image}) : _image = image;

  final ui.Image? _image;

  /// The URL of every load, in order. A URL the image cache already holds is not loaded again.
  final List<String> requested = <String>[];

  final Map<String, Completer<ImageInfo>> _pending =
      <String, Completer<ImageInfo>>{};

  /// For [ImageCdn.providerFactory]. Its providers are equal for one URL of one [FakeImages], and
  /// never equal to another [FakeImages]' (no image cached by an earlier test is reused).
  ImageProvider<Object> provider(String url) => _FakeImageProvider(this, url);

  /// [cdn] (`const ImageCdn()` by default) loading through these fakes.
  ImageCdn cdn([ImageCdn cdn = const ImageCdn()]) =>
      cdn.copyWith(providerFactory: provider);

  /// Whether [url] was asked for and has neither completed nor failed.
  bool isPending(String url) => _pending.containsKey(url);

  /// Completes the pending load of [url] with [image]; the next `pump()` shows it.
  void complete(String url, ui.Image image) {
    final pending = _pending.remove(url);
    if (pending == null) {
      throw StateError('FakeImages: no pending load of "$url" to complete');
    }
    pending.complete(ImageInfo(image: image.clone()));
  }

  /// Fails the pending load of [url] with [error] (by default a `NetworkImageLoadException`,
  /// status 404).
  void fail(String url, [Object? error]) {
    final pending = _pending.remove(url);
    if (pending == null) {
      throw StateError('FakeImages: no pending load of "$url" to fail');
    }
    pending.completeError(
      error ?? NetworkImageLoadException(statusCode: 404, uri: Uri.parse(url)),
    );
  }

  Future<ImageInfo> _load(String url) {
    requested.add(url);
    final image = _image;
    if (image != null) {
      return SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone()));
    }
    final completer = Completer<ImageInfo>();
    _pending[url] = completer;
    return completer.future;
  }
}

/// A provider of [FakeImages]: equal for one URL of one [owner].
final class _FakeImageProvider extends ImageProvider<_FakeImageProvider> {
  const _FakeImageProvider(this.owner, this.url);

  final FakeImages owner;
  final String url;

  @override
  Future<_FakeImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FakeImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FakeImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(owner._load(url));

  @override
  bool operator ==(Object other) =>
      other is _FakeImageProvider &&
      identical(other.owner, owner) &&
      other.url == url;

  @override
  int get hashCode => Object.hash(identityHashCode(owner), url);

  @override
  String toString() => 'FakeImages($url)';
}
