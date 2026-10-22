import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// A [Dio] as an [HttpTransport] (since 0.21.0): everything that sends through a transport (a
/// `SessionTransport`, a download, a client of your own) sends through the app's Dio, with its
/// interceptors (a retrier, `WriteGuard`), its adapter and its base options.
///
/// ```dart
/// final transport = SessionTransport(DioTransport(ref.watch(dio)), ref.watch(authorizer));
/// ```
///
/// Behaviour:
///
/// * The response body is streamed (`ResponseType.stream`) and every status is an answer, not an
///   exception (`validateStatus: (_) => true`). An interceptor that rejects on a status still can.
/// * A request made of bytes sends its body as bytes, so an interceptor that sends the same
///   request again sends the whole body a second time. A request with a `bodyStream` streams it,
///   which can be read once (its `contentLength`, when known, becomes the `content-length`
///   header).
/// * `TransportRequest.abortTrigger` cancels a `CancelToken` through a side `then` (no timer).
/// * `TransportRequest.attributes` are never sent: they are copied into `Options.extra` under
///   their keys, so a Dio interceptor can read them.
/// * A `DioException` becomes a `TransportFailure` (see below), except two cases that pass through
///   unchanged: a `TransportFailure` an interceptor or an adapter put in `DioException.error`, and
///   an `Exception` an interceptor rejected with (a session's `AuthRejected`), which is thrown
///   as that object, with its stack trace.
///
/// | `DioExceptionType`                                      | Thrown                |
/// | ------------------------------------------------------- | --------------------- |
/// | `cancel`                                                | `TransportAborted`    |
/// | `connectionError`, `connectionTimeout`                  | `TransportUnsent`     |
/// | `badCertificate`                                        | `TransportUntrusted`  |
/// | `sendTimeout`, `receiveTimeout`                         | `TransportTimedOut`   |
/// | `badResponse`, `unknown`                                | `TransportBroken`     |
///
/// The failure keeps Dio's error as its `cause` and never names the server in its text.
final class DioTransport implements HttpTransport {
  /// A transport that sends through [dio].
  const DioTransport(this.dio);

  /// The Dio every request goes through.
  final Dio dio;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final token = CancelToken();
    final trigger = request.abortTrigger;
    if (trigger != null) {
      // A side `then`: it starts no timer, and cancelling a finished request does nothing.
      unawaited(
        trigger.then<void>((_) {
          if (!token.isCancelled) token.cancel('aborted by abortTrigger');
        }),
      );
    }

    final headers = Map<String, Object?>.of(request.headers);
    final Object? data;
    final bytes = request.body;
    final stream = request.bodyStream;
    int? length;
    if (stream != null) {
      data = stream.map(_asBytes);
      length = request.contentLength;
    } else if (bytes != null && bytes.isNotEmpty) {
      data = bytes;
      length = bytes.length;
    } else {
      data = null;
    }
    if (length != null) {
      headers.removeWhere((k, _) => k.toLowerCase() == 'content-length');
      headers[Headers.contentLengthHeader] = '$length';
    }

    final Response<ResponseBody> response;
    try {
      response = await dio.requestUri<ResponseBody>(
        request.uri,
        data: data,
        cancelToken: token,
        options: Options(
          method: request.method,
          headers: headers,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          extra: Map<String, Object?>.of(request.attributes),
        ),
      );
    } on DioException catch (error, stackTrace) {
      _rethrowAsTransport(error, stackTrace, request.uri);
    }

    final answer = response.data;
    if (answer == null) {
      throw TransportBroken(
        StateError('the response has no body stream'),
        request.uri,
      );
    }
    final lowered = <String, String>{};
    for (final entry in response.headers.map.entries) {
      final name = entry.key.toLowerCase();
      final value = entry.value.join(', ');
      final seen = lowered[name];
      lowered[name] = seen == null ? value : '$seen, $value';
    }
    return TransportResponse(
      statusCode: response.statusCode ?? answer.statusCode,
      headers: lowered,
      body: answer.stream.cast<List<int>>(),
      reasonPhrase: response.statusMessage,
    );
  }

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

  /// Throws what [error] stands for: see the table on [DioTransport].
  static Never _rethrowAsTransport(
    DioException error,
    StackTrace stackTrace,
    Uri uri,
  ) {
    final inner = error.error;
    if (inner is TransportFailure) {
      Error.throwWithStackTrace(inner, error.stackTrace);
    }
    // An interceptor rejected with an error object of its own (`handler.reject(DioException(
    // error: AuthRejected(...)))`): it is that object the caller wants, not a Dio wrapper.
    if (error.type == DioExceptionType.unknown &&
        inner is Exception &&
        inner is! DioException) {
      Error.throwWithStackTrace(inner, error.stackTrace);
    }
    final TransportFailure failure = switch (error.type) {
      DioExceptionType.cancel => TransportAborted(error, uri),
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout => TransportUnsent(error, uri),
      DioExceptionType.badCertificate => TransportUntrusted(error, uri),
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => TransportTimedOut(error, uri),
      // `badResponse`, `unknown` and any type a newer Dio adds.
      _ => TransportBroken(error, uri),
    };
    Error.throwWithStackTrace(failure, error.stackTrace);
  }
}
