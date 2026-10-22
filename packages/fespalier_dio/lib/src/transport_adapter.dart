import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// An [HttpTransport] as a Dio `HttpClientAdapter` (since 0.21.0): the app's own `Dio`, with its
/// interceptors, `dio_smart_retry` and `WriteGuard`, sends through a transport chain (a
/// `SessionTransport` over a `WriteGuardTransport` over a `DioTransport` or an
/// `HttpClientTransport`).
///
/// ```dart
/// final dio = Dio()..httpClientAdapter = TransportAdapter(ref.watch(sessionTransport));
/// ```
///
/// Every retry that Dio's retry interceptors perform calls [fetch] again, so a decorator below
/// (a session signing each send) sees every send, not only the first.
///
/// Behaviour:
///
/// * A body that Dio finalized (JSON, a form, a multipart `FormData`) is collected into bytes and
///   sent as `TransportRequest.body`, so the transport can sign and replay the exact bytes. A
///   `Stream` as `data` stays a `bodyStream` (its `content-length` header, when present, becomes
///   the `contentLength`) and is not replayable. With no body, the request has none.
/// * The `abortTrigger` is Dio's cancel future merged with the abort trigger of the current zone
///   (`TransportZone.current`, set by `ref.cancellable` in `fespalier_cratestack`), whichever
///   completes first; `RequestOptions.extra` is copied into the request's `attributes`.
/// * A `TransportFailure` becomes a `DioException` with the failure in `error`: `TransportAborted`
///   a cancel, `TransportUnsent` a `connectionError`, `TransportUntrusted` a `badCertificate`, `TransportTimedOut` a `receiveTimeout`,
///   `TransportBroken` and `TransportPortal` an `unknown`. `DioErrors.toTransport` turns the
///   `DioException` back into the failure for a reader that knows no Dio type. Any other error the transport throws is wrapped as an
///   `unknown` `DioException` whose `error` is that same object (a session's `AuthRejected`).
/// * The request carries a `TransportMemo`, created on the first fetch of its `RequestOptions` and
///   kept in `extra` (`TransportMemo.key`), so every send of one logical request that a Dio
///   retrier makes (it calls `fetch` again with the same options) shares it: a session below
///   refuses a retry whose user changed, and renews once per request, not once per send.
/// * [close] does nothing: the transport belongs to whoever made it.
final class TransportAdapter implements HttpClientAdapter {
  /// An adapter that sends through [transport].
  const TransportAdapter(this.transport);

  /// The transport every request goes to.
  final HttpTransport transport;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final headers = <String, String>{};
    String? lengthHeader;
    for (final entry in options.headers.entries) {
      final value = entry.value;
      if (value == null) continue;
      final text = value is Iterable ? value.join(', ') : '$value';
      headers[entry.key] = text;
      if (entry.key.toLowerCase() == 'content-length') lengthHeader = text;
    }

    Uint8List? body;
    Stream<List<int>>? bodyStream;
    int? contentLength;
    if (requestStream != null) {
      if (options.data is Stream) {
        bodyStream = requestStream;
        contentLength = lengthHeader == null
            ? null
            : int.tryParse(lengthHeader);
      } else {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in requestStream) {
          builder.add(chunk);
        }
        body = builder.takeBytes();
      }
    }

    // One memo per logical request: a retrier calls fetch again with these same options.
    if (options.extra[TransportMemo.key] is! TransportMemo) {
      options.extra[TransportMemo.key] = TransportMemo();
    }

    final request = TransportRequest(
      method: options.method,
      uri: options.uri,
      headers: headers,
      body: body,
      bodyStream: bodyStream,
      contentLength: contentLength,
      abortTrigger: TransportZone.merge(cancelFuture, TransportZone.current()),
      attributes: Map<String, Object?>.of(options.extra),
    );

    final TransportResponse response;
    try {
      response = await transport.send(request);
    } on TransportFailure catch (failure, stackTrace) {
      throw DioException(
        requestOptions: options,
        type: switch (failure) {
          TransportAborted() => DioExceptionType.cancel,
          TransportUnsent() => DioExceptionType.connectionError,
          TransportUntrusted() => DioExceptionType.badCertificate,
          TransportTimedOut() => DioExceptionType.receiveTimeout,
          TransportBroken() || TransportPortal() => DioExceptionType.unknown,
        },
        error: failure,
        stackTrace: stackTrace,
      );
    } on DioException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: error,
        stackTrace: stackTrace,
      );
    }

    return ResponseBody(
      response.body.map(_asBytes),
      response.statusCode,
      statusMessage: response.reasonPhrase,
      headers: <String, List<String>>{
        for (final entry in response.headers.entries)
          entry.key: <String>[entry.value],
      },
    );
  }

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

  /// The transport belongs to whoever made it: nothing to close.
  @override
  void close({bool force = false}) {}
}
