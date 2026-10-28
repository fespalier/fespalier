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
///   cancelling the body's subscription and `close(force: true)` abort the `fetch`, so the browser
///   lets the connection go, even while nothing arrives.
/// - An abort is a [DioExceptionType.cancel]; any other failure, before the headers or in the
///   body, a [DioExceptionType.connectionError] whose `error` is the browser's.
/// - The request body is read into memory before it is sent: Firefox and Safari cannot stream a
///   request body.
/// - `connectTimeout`, `receiveTimeout` and `sendTimeout` are **not honoured**: honouring them
///   takes a timer, and `AbortSignal.timeout` cannot be cleared once the headers are in, so it
///   would end a stream that is still wanted. Cancel through the `CancelToken` instead.
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

    final web.RequestInit init;
    try {
      init = await _requestOf(options, requestStream, request);
    } on Object {
      // A request body that failed, or a header the browser refuses: nothing was sent.
      request.finish();
      rethrow;
    }

    final web.Response response;
    try {
      response = await web.window
          .fetch(options.uri.toString().toJS, init)
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

  /// The `fetch` options for [options], with the body read into memory.
  Future<web.RequestInit> _requestOf(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    _Request request,
  ) async {
    Uint8List? body;
    if (requestStream != null) {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        bytes.add(chunk);
      }
      body = bytes.takeBytes();
    }

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

  /// Aborts the requests still open when [force] is true; otherwise lets them finish, as Dio's
  /// default web adapter does.
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

  /// Aborts the request, unless it already ended.
  void abort() {
    if (aborted || _ended) return;
    aborted = true;
    finish();
    controller.abort();
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
