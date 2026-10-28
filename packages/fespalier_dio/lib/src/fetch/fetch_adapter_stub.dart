import 'dart:typed_data';

import 'package:dio/dio.dart';

/// The browser's `fetch` adapter, which exists only in a web build (since 0.25.0): here, outside
/// a browser, [fetch] throws an [UnsupportedError]. Use [webStreamingAdapter] in code that also
/// runs on a device or the VM.
final class FetchHttpClientAdapter implements HttpClientAdapter {
  /// An adapter whose cross-origin requests would carry cookies when [withCredentials] is true.
  FetchHttpClientAdapter({this.withCredentials = false});

  /// Whether a cross-origin request carries the browser's cookies (web builds only).
  bool withCredentials;

  /// Throws: there is no `fetch` outside a browser.
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw UnsupportedError(
    'FetchHttpClientAdapter needs a browser: use webStreamingAdapter(), which is Dio\'s default '
    'adapter outside one.',
  );

  /// Nothing to close.
  @override
  void close({bool force = false}) {}
}

/// Dio's default adapter: what a build that is not for the web gets (since 0.25.0).
/// [withCredentials] applies to the web only.
HttpClientAdapter webStreamingAdapter({bool withCredentials = false}) =>
    HttpClientAdapter();
