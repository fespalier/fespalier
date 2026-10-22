import 'dart:async';
import 'dart:ui' as ui;

import 'package:fespalier_transport/fespalier_transport.dart'
    show HttpTransport, TransportRequest;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// An image fetched with a GET through an `HttpTransport` (since 0.21.0): what `ImageCdn` loads
/// with unless it has a `providerFactory`. It is `NetworkImage` with the HTTP client replaced by
/// the app's transport chain, so a request here is signed, traced and counted like the app's
/// others.
///
/// It is keyed like `NetworkImage`: by its [url] (resolved against `Uri.base`) and [scale], and
/// by the [transport] instance, so providers of one URL over one transport share a cache entry.
/// The key is available at once (a `SynchronousFuture`), so `ImageVariants` can tell a loaded
/// variant without waiting. The bytes are read whole, then decoded with the `decode` the image
/// cache hands in (so a `ResizeImage` around it decodes at the size it asks for). An answer other
/// than 200 fails with `NetworkImageLoadException` (the status, and the URL in its message),
/// which is what `fespalier.image` telemetry reads the HTTP status from. A failed load is evicted
/// from the cache, so a retry loads again. No progress is reported: `chunkEvents` stays silent.
///
/// **On the web** a transport fetch (`fetch`/`XMLHttpRequest` under `package:http`'s
/// `BrowserClient`, or Dio's adapter) needs the image host to answer with CORS headers, which
/// `NetworkImage`'s `<img>` element fallback did not. A CDN you do not control that sends none
/// needs `ImageCdn(providerFactory: (url) => NetworkImage(url, webHtmlElementStrategy:
/// WebHtmlElementStrategy.fallback))` instead, and gives up the transport chain for its images.
@immutable
class TransportImage extends ImageProvider<TransportImage> {
  /// The image at [url], fetched through [transport].
  const TransportImage(this.url, {required this.transport, this.scale = 1.0});

  /// Where the image is (absolute, or relative to `Uri.base`).
  final String url;

  /// What the GET is sent through.
  final HttpTransport transport;

  /// The scale of the image's pixels to logical pixels.
  final double scale;

  @override
  Future<TransportImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<TransportImage>(this);

  @override
  ImageStreamCompleter loadImage(
    TransportImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(key, decode),
    scale: key.scale,
    debugLabel: key.url,
    informationCollector: () => <DiagnosticsNode>[
      DiagnosticsProperty<ImageProvider>('Image provider', this),
      DiagnosticsProperty<TransportImage>('Image key', key),
    ],
  );

  Future<ui.Codec> _load(
    TransportImage key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final resolved = Uri.base.resolve(key.url);
      final response = await key.transport.send(
        TransportRequest(method: 'GET', uri: resolved),
      );
      // Read whatever the status: an unread body would hold the connection.
      final bytes = await response.bytes();
      if (response.statusCode != 200) {
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: resolved,
        );
      }
      if (bytes.isEmpty) {
        throw Exception('TransportImage is an empty file: $resolved');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer);
    } on Object {
      // A failed load must not stay in the cache: the retry has to ask again.
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TransportImage &&
      other.url == url &&
      other.scale == scale &&
      identical(other.transport, transport);

  @override
  int get hashCode => Object.hash(url, scale, identityHashCode(transport));

  @override
  String toString() =>
      '$runtimeType("$url", scale: ${scale.toStringAsFixed(1)})';
}
