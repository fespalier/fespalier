import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;

/// What [TransportClient] saw of each response, by identity: true when it answered a write.
final Expando<bool> _writeResponses = Expando<bool>(
  'fespalier_http transport responses',
);

/// The errors [TransportClient] threw for a write's send, by identity.
final Expando<bool> _writeErrors = Expando<bool>(
  'fespalier_http transport errors',
);

/// The memo of each `http.BaseRequest` [TransportClient] sent, by identity: the same request
/// sent again shares it.
final Expando<TransportMemo> _memos = Expando<TransportMemo>(
  'fespalier_http transport memos',
);

/// An `http.Client` that sends through an [HttpTransport] (since 0.21.0): the way code written
/// for `package:http` (`RetryClient`, `ref.abortable(client)`, a `data.dart`) uses a transport
/// chain, such as a session over a write guard over [HttpClientTransport].
///
/// ```dart
/// final client = RetryClient(
///   TransportClient(
///     SessionTransport(WriteGuardTransport(HttpClientTransport(http.Client())), authorizer),
///   ),
///   when: TransportClient.readsOnly(),
///   whenError: TransportClient.readErrorsOnly((error, stackTrace) => true),
/// );
/// ```
///
/// A request becomes a `TransportRequest`:
///
/// * an `http.Request`: its `bodyBytes`;
/// * an `http.MultipartRequest`: finalized once into bytes, with the `content-type` (and its
///   boundary) that finalizing sets, so a transport sees the exact bytes it will send and can
///   send them again;
/// * any other request (an `http.StreamedRequest`, which is what `RetryClient` sends): a body
///   stream with its `contentLength`, which a transport reads once.
///
/// Every `http.BaseRequest` has its own `TransportMemo` (what a session remembers of one logical
/// request across its sends: the user it was made for, a refusal, the renewals spent), kept for
/// as long as the request object lives: the same object sent again shares it. `package:http`
/// retriers (`RetryClient`) send a **copy** of the request each time, so each copy is a new
/// logical request, and a session below refuses nothing across them and may renew once for each
/// (Dio's retriers resend the very same options, which `TransportAdapter` does follow). Put the
/// retrier's attempt limit where the renewals should stop.
///
/// Its `abortTrigger` (an `http.Abortable`) is passed on. `followRedirects`, `maxRedirects` and
/// `persistentConnection` are the transport's own to decide, and are ignored.
///
/// The response is an `http.StreamedResponse` over the transport's body, with `request` set.
/// What the transport throws becomes what `package:http` code expects: [TransportAborted] an
/// `http.RequestAbortedException`; any other [TransportFailure] and any [CredentialsUnavailable]
/// an `http.ClientException` whose message never names the server (its `uri` is the request's).
/// Any other error, such as a session's `AuthRejected`, propagates unchanged.
///
/// [close] does nothing: the transport belongs to whoever made it.
final class TransportClient extends http.BaseClient {
  /// A client that sends through [transport].
  TransportClient(this.transport);

  /// The transport every request is sent through.
  final HttpTransport transport;

  /// [when], for reads only: for `RetryClient(when:)`. By default [retryOn503], `RetryClient`'s own
  /// rule.
  ///
  /// A response is a write's when it came through a [WriteGuardTransport] from a write. A
  /// response whose transport chain has no guard says nothing about its request, so it is not
  /// retried: it is the safe answer to "might this be a write?". Put a [WriteGuardTransport]
  /// next to the network.
  static bool Function(http.BaseResponse response) readsOnly([
    bool Function(http.BaseResponse response) when = retryOn503,
  ]) =>
      (response) => _writeResponses[response] == false && when(response);

  /// [whenError], except for an error a write's send threw through a [WriteGuardTransport]: for
  /// `RetryClient(whenError:)`.
  static bool Function(Object error, StackTrace stackTrace) readErrorsOnly(
    bool Function(Object error, StackTrace stackTrace) whenError,
  ) =>
      (error, stackTrace) =>
          _writeErrors[error] != true && whenError(error, stackTrace);

  /// `RetryClient`'s default: a 503.
  static bool retryOn503(http.BaseResponse response) =>
      response.statusCode == 503;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final memo = _memos[request] ??= TransportMemo();
    final outgoing = await _outgoing(request, memo);
    final TransportResponse response;
    try {
      response = await transport.send(outgoing);
    } on TransportAborted catch (failure) {
      throw _marked(http.RequestAbortedException(request.url), failure);
    } on TransportFailure catch (failure) {
      throw _marked(
        http.ClientException(failure.toString(), request.url),
        failure,
      );
    } on CredentialsUnavailable catch (unavailable) {
      throw http.ClientException(
        '${unavailable.runtimeType}: the credentials could not be reached',
        request.url,
      );
    }
    final streamed = http.StreamedResponse(
      response.body,
      response.statusCode,
      contentLength: int.tryParse(response.headers['content-length'] ?? ''),
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
    _writeResponses[streamed] = WriteGuardTransport.isWriteResponse(response);
    return streamed;
  }

  /// The transport belongs to whoever made it.
  @override
  void close() {}

  static http.ClientException _marked(
    http.ClientException error,
    TransportFailure failure,
  ) {
    if (WriteGuardTransport.isWriteError(failure)) _writeErrors[error] = true;
    return error;
  }

  static Future<TransportRequest> _outgoing(
    http.BaseRequest request,
    TransportMemo memo,
  ) async {
    // `Abortable` is a mixin of the three Abortable* classes: promote through Object.
    final Object asObject = request;
    final trigger = asObject is http.Abortable ? asObject.abortTrigger : null;
    switch (request) {
      case http.Request():
        return TransportRequest(
          method: request.method,
          uri: request.url,
          headers: Map<String, String>.of(request.headers),
          body: request.bodyBytes,
          abortTrigger: trigger,
          attributes: <String, Object?>{TransportMemo.key: memo},
        );
      case http.MultipartRequest():
        // Finalizing sets the content-type with the boundary: read the headers after it.
        final bytes = await request.finalize().toBytes();
        return TransportRequest(
          method: request.method,
          uri: request.url,
          headers: Map<String, String>.of(request.headers),
          body: Uint8List.fromList(bytes),
          abortTrigger: trigger,
          attributes: <String, Object?>{TransportMemo.key: memo},
        );
      default:
        final stream = request.finalize();
        return TransportRequest(
          method: request.method,
          uri: request.url,
          headers: Map<String, String>.of(request.headers),
          bodyStream: stream,
          contentLength: request.contentLength,
          abortTrigger: trigger,
          attributes: <String, Object?>{TransportMemo.key: memo},
        );
    }
  }
}
