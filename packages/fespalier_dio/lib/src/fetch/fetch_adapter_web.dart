import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;

/// A Dio [HttpClientAdapter] over the browser's `fetch` that streams the response body (since
/// 0.25.0).
///
/// Dio's default web adapter uses `XMLHttpRequest` with an `arraybuffer` response, so a body
/// arrives in one piece when the server ends it: an event stream shows nothing until it closes.
/// This adapter reads `Response.body` chunk by chunk, so `ResponseType.stream` (what
/// `DioTransport` asks for) hands each chunk on as the browser receives it.
///
/// - Cancelling the request's `CancelToken`, closing Dio's response (`ResponseBody.close`),
///   cancelling the body's subscription and `close(force: true)` of a request that is running
///   abort the `fetch`, so the browser lets the connection go, even while nothing arrives. An
///   abort while the request body is still being read also stops reading it and cancels its
///   source.
/// - An abort is a [DioExceptionType.cancel]. A `fetch` that fails before the headers (the
///   network, CORS, a refused certificate) is a [DioExceptionType.connectionError] whose `error`
///   is the browser's; a request the browser refuses to build (a `GET` with a body, a URL with a
///   user name, a forbidden method, a header value it rejects) is a [DioExceptionType.unknown];
///   and a failure in the body, once the headers are in, is a [DioException] (a `connectionError`
///   too) in the body stream, which `DioTransport` hands on as it is, not a `TransportUnsent`.
/// - The request body is read into memory before it is sent: Firefox and Safari cannot stream a
///   request body.
/// - `connectTimeout` and `sendTimeout` are **not honoured**: honouring them takes a timer, and
///   `AbortSignal.timeout` cannot be cleared once the headers are in, so it would end a stream
///   that is still wanted. `receiveTimeout` is **Dio's own**, not the adapter's: Dio watches
///   the gap between chunks of every adapter's body (`ResponseBody.close` and an error of type
///   [DioExceptionType.receiveTimeout] in the body stream), so a quiet stream is dropped after
///   it. A Dio that streams leaves `BaseOptions.receiveTimeout` null (or zero), and a request
///   on a Dio that has one passes `Options(receiveTimeout: Duration.zero)`; `null` in `Options`
///   does not disable it, it falls back to the Dio's. Cancel through the `CancelToken` instead
///   of a timeout.
/// - Redirects are followed by the browser (`redirect: 'follow'`): `followRedirects: false` and
///   `maxRedirects` are not honoured, `isRedirect` is what `Response.redirected` says and
///   `redirects` is empty, because `fetch` does not list them.
/// - The response headers come with lower-case names, one value each (the browser joins repeated
///   headers with `, `, and keeps `set-cookie` to itself).
///
/// It starts no timer and no listener.
final class FetchHttpClientAdapter implements HttpClientAdapter {
  /// An adapter whose cross-origin requests carry cookies when [withCredentials] is true.
  FetchHttpClientAdapter({this.withCredentials = false});

  /// Whether a cross-origin request carries the browser's cookies and HTTP authentication
  /// (`credentials: 'include'`; `'same-origin'` otherwise). `Options.extra['withCredentials']`
  /// overrides it for one request, as with Dio's default web adapter.
  bool withCredentials;

  final Set<_Request> _open = <_Request>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = _Request(_open);
    // A side `then`: Dio completes it when the request's CancelToken is cancelled.
    if (cancelFuture != null) {
      unawaited(cancelFuture.then<void>((_) => request.abort()));
    }

    final Uint8List? body;
    try {
      body = await _readRequestBody(options, requestStream, request);
    } on Object {
      // A request body that failed or was cancelled: nothing was sent.
      request.finish();
      rethrow;
    }

    // Built here, in one synchronous step, so that a request the browser refuses to build is told
    // from a `fetch` that fails on the network.
    final web.Request built;
    try {
      built = web.Request(
        options.uri.toString().toJS,
        _requestInit(options, body, request),
      );
    } catch (error, stackTrace) {
      request.finish();
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: error,
        stackTrace: stackTrace,
        message: 'the browser refused to build the request.',
      );
    }

    final web.Response response;
    try {
      // The signal again in the init: WebKit leaves the connection open after an abort of a
      // signal that only the `Request` carries (the harness' cancel cases fail without it).
      response = await web.window
          .fetch(built, web.RequestInit(signal: request.controller.signal))
          .toDart;
    } catch (error, stackTrace) {
      request.finish();
      if (request.aborted || _isAbort(error)) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'aborted',
          stackTrace: stackTrace,
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'fetch failed.',
        error: error,
      );
    }

    final responseHeaders = <String, List<String>>{};
    // package:web's Headers has no forEach; every browser's has.
    (response.headers as _IterableHeaders).forEach(
      (String value, String name) {
        (responseHeaders[name.toLowerCase()] ??= <String>[]).add(value);
      }.toJS,
    );

    return ResponseBody(
      _bodyOf(response, options, request),
      response.status,
      statusMessage: response.statusText,
      isRedirect: response.redirected,
      headers: responseHeaders,
      onClose: request.abort,
    );
  }

  /// The request body of [options], read into memory; null when there is none.
  ///
  /// An abort of [request] stops the reading and cancels [requestStream]'s subscription, so an
  /// endless source is let go.
  Future<Uint8List?> _readRequestBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    _Request request,
  ) async {
    if (requestStream == null) return null;
    final bytes = BytesBuilder(copy: false);
    // A StreamIterator, not an `await for`: its `cancel` ends a `moveNext` that is waiting for a
    // chunk, so an abort lets go of a source that has gone quiet too.
    final chunks = StreamIterator<Uint8List>(requestStream);
    request.onAbort = () => unawaited(chunks.cancel());
    try {
      while (await chunks.moveNext()) {
        bytes.add(chunks.current);
      }
    } finally {
      request.onAbort = null;
      await chunks.cancel();
    }
    if (request.aborted) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'aborted',
      );
    }
    return bytes.takeBytes();
  }

  /// The `fetch` options for [options] and its [body].
  web.RequestInit _requestInit(
    RequestOptions options,
    Uint8List? body,
    _Request request,
  ) {
    final headers = web.Headers();
    options.headers.forEach((name, value) {
      if (value == null) return;
      // The browser sets these itself.
      final lower = name.toLowerCase();
      if (lower == 'content-length' || lower == 'host') return;
      headers.append(name, value is Iterable ? value.join(', ') : '$value');
    });
    final credentials = switch (options.extra['withCredentials']) {
      final bool own => own,
      _ => withCredentials,
    };
    final init = web.RequestInit(
      method: options.method,
      headers: headers,
      credentials: credentials ? 'include' : 'same-origin',
      signal: request.controller.signal,
      redirect: 'follow',
    );
    if (body != null && body.isNotEmpty) init.body = body.toJS;
    return init;
  }

  /// The body of [response], read by a pump that [request]'s subscriber starts, pauses and stops.
  ///
  /// Not an `async*` loop: its cleanup would wait for the next chunk, so an idle stream would stay
  /// open after its subscription was cancelled. Here a cancel aborts the `fetch` at once.
  Stream<Uint8List> _bodyOf(
    web.Response response,
    RequestOptions options,
    _Request request,
  ) {
    final source = response.body;
    if (source == null) {
      request.finish();
      return const Stream<Uint8List>.empty();
    }
    final reader = source.getReader() as web.ReadableStreamDefaultReader;
    late final StreamController<Uint8List> out;
    var reading = false;
    var paused = false;

    Future<void> pump() async {
      if (reading) return;
      reading = true;
      try {
        while (!paused && out.hasListener && !out.isClosed) {
          final chunk = await reader.read().toDart;
          if (chunk.done) {
            request.finish();
            await out.close();
            return;
          }
          final value = chunk.value;
          if (value != null) out.add((value as JSUint8Array).toDart);
        }
      } catch (error, stackTrace) {
        request.finish();
        if (out.isClosed) return;
        out.addError(
          request.aborted || _isAbort(error)
              ? DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'aborted',
                  stackTrace: stackTrace,
                )
              : DioException.connectionError(
                  requestOptions: options,
                  reason: 'the response body broke.',
                  error: error,
                ),
          stackTrace,
        );
        await out.close();
      } finally {
        reading = false;
      }
    }

    out = StreamController<Uint8List>(
      onListen: () => unawaited(pump()),
      onPause: () => paused = true,
      onResume: () {
        paused = false;
        unawaited(pump());
      },
      onCancel: request.abort,
    );
    return out.stream;
  }

  static bool _isAbort(Object error) {
    if (error case web.DOMException(name: 'AbortError')) return true;
    return false;
  }

  /// Aborts the requests still running when [force] is true; otherwise lets them finish, as Dio's
  /// default web adapter does.
  ///
  /// The set of open requests is forgotten either way, so a plain `close()` followed by
  /// `close(force: true)` aborts nothing (as `dio_web_adapter`'s own adapter does).
  @override
  void close({bool force = false}) {
    if (force) {
      for (final request in _open.toList()) {
        request.abort();
      }
    }
    _open.clear();
  }
}

/// One request's `AbortController`, in the adapter's open set until the request ends.
final class _Request {
  _Request(this._open) {
    _open.add(this);
  }

  final web.AbortController controller = web.AbortController();
  final Set<_Request> _open;
  bool _ended = false;

  /// Whether this adapter aborted the request: an error that follows is a cancel.
  bool aborted = false;

  /// Runs when the request is aborted, while its request body is still being read.
  void Function()? onAbort;

  /// Aborts the request, unless it already ended.
  void abort() {
    if (aborted || _ended) return;
    aborted = true;
    finish();
    controller.abort();
    onAbort?.call();
  }

  /// The request ended (its body is read, or it failed): nothing is left to abort.
  void finish() {
    _ended = true;
    _open.remove(this);
  }
}

/// `Headers.forEach`, which `package:web` does not bind.
@JS()
extension type _IterableHeaders._(JSObject _) implements JSObject {
  external void forEach(JSFunction callback);
}

/// The fetch adapter: what a web build gets (since 0.25.0).
HttpClientAdapter webStreamingAdapter({bool withCredentials = false}) =>
    FetchHttpClientAdapter(withCredentials: withCredentials);
