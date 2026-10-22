import 'dart:async';

import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;

import 'tls_failure.dart';

/// An [HttpTransport] over an `http.Client` (since 0.21.0): the way a `package:fespalier_auth`
/// session, a [WriteGuardTransport] or any other decorator sends through `package:http`.
///
/// ```dart
/// final transport = SessionTransport(
///   WriteGuardTransport(HttpClientTransport(http.Client())),
///   authorizer,
/// );
/// ```
///
/// A request becomes an `http.AbortableRequest` (an `http.AbortableStreamedRequest` for a streamed
/// body, with its `contentLength` when known) carrying the request's `abortTrigger`. The response
/// streams: its body is the `StreamedResponse`'s own stream, and an error in the middle of it is
/// the client's own (`http.ClientException`), not a `TransportFailure`. `attributes` are for
/// decorators and are ignored here.
///
/// What the client throws before the response's headers are in becomes a [TransportFailure], with
/// the original error as its `cause`:
///
/// * `http.RequestAbortedException`: [TransportAborted].
/// * a `TimeoutException`: [TransportTimedOut].
/// * a failure that provably left nothing on the wire: [TransportUnsent]. That is a connection
///   refused, a host that could not be found and a network that is unreachable, recognised by
///   the text of the error (`Connection refused`, `Failed host lookup`, `Network is unreachable`,
///   `No route to host`, `HTTP connection timed out`) or by the OS error code in it
///   (`errno = 61`, `111`, `51`, `101`, `65`, `113`, `10061`, `10051`, `10065`). The text is
///   used, not `dart:io`'s types, because this package also builds for the web.
/// * a refused TLS certificate: [TransportUntrusted]. That is a `HandshakeException`, a
///   `TlsException` or a `CertificateException` (`dart:io`, through a conditional import). On the
///   web the browser gives no error that tells a refused certificate from any other failed
///   request, so nothing is mapped there.
/// * any other `http.ClientException`, and any `SocketException` or `HttpException` thrown
///   without one around it: [TransportBroken]. A refusal to say that
///   nothing was sent is the safe answer: only a read is sent again after it.
///
/// Anything else (a `StateError` from a bug, an `ArgumentError`) propagates. Closing the client
/// is its maker's job: this transport never closes it.
final class HttpClientTransport implements HttpTransport {
  /// A transport that sends through [client].
  const HttpClientTransport(this.client);

  /// The client every request is sent with.
  final http.Client client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final http.StreamedResponse response;
    try {
      response = await client.send(_outgoing(request));
    } on http.RequestAbortedException catch (error) {
      throw TransportAborted(error, request.uri);
    } on TimeoutException catch (error) {
      throw TransportTimedOut(error, request.uri);
    } on http.ClientException catch (error) {
      throw classify(error, request.uri);
    } on Exception catch (error) {
      if (_isNetworkError(error)) throw classify(error, request.uri);
      rethrow;
    }
    return TransportResponse(
      statusCode: response.statusCode,
      headers: <String, String>{
        for (final entry in response.headers.entries)
          entry.key.toLowerCase(): entry.value,
      },
      body: response.stream,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The [TransportFailure] that [error] is, for the request to [uri]: [TransportUnsent] when the
  /// text of the error says the connection was refused, the host was not found or the network was
  /// unreachable, [TransportUntrusted] when the certificate was refused, [TransportBroken]
  /// otherwise. See the class documentation for the rules.
  static TransportFailure classify(Object error, [Uri? uri]) {
    if (isRefusedCertificate(error)) return TransportUntrusted(error, uri);
    final text = error.toString().toLowerCase();
    for (final phrase in _unsentPhrases) {
      if (text.contains(phrase)) return TransportUnsent(error, uri);
    }
    final code = _errno.firstMatch(text);
    if (code != null && _unsentErrnos.contains(int.parse(code.group(1)!))) {
      return TransportUnsent(error, uri);
    }
    return TransportBroken(error, uri);
  }

  static const List<String> _unsentPhrases = <String>[
    'connection refused',
    'failed host lookup',
    'no address associated with hostname',
    'nodename nor servname provided',
    'name or service not known',
    'temporary failure in name resolution',
    'network is unreachable',
    'no route to host',
    'host is unreachable',
    // dart:io's HttpClient.connectionTimeout: the connection was never made.
    'http connection timed out',
  ];

  /// ECONNREFUSED (macOS 61, Linux 111, Windows 10061 and 1225), ENETUNREACH (51, 101, 10051),
  /// EHOSTUNREACH (65, 113, 10065).
  static const Set<int> _unsentErrnos = <int>{
    61,
    111,
    10061,
    1225,
    51,
    101,
    10051,
    65,
    113,
    10065,
  };

  static final RegExp _errno = RegExp(r'errno = (\d+)');

  /// Errors `dart:io` throws that a client may let through unwrapped, found by name so that this
  /// package builds for the web.
  static bool _isNetworkError(Object error) {
    if (isRefusedCertificate(error)) return true;
    final name = error.runtimeType.toString();
    return name.contains('SocketException') ||
        name.contains('HandshakeException') ||
        name.contains('HttpException') ||
        name.contains('TlsException');
  }

  static http.BaseRequest _outgoing(TransportRequest request) {
    final stream = request.bodyStream;
    if (stream == null) {
      final outgoing = http.AbortableRequest(
        request.method,
        request.uri,
        abortTrigger: request.abortTrigger,
      )..headers.addAll(request.headers);
      final body = request.body;
      if (body != null) outgoing.bodyBytes = body;
      return outgoing;
    }
    final outgoing = http.AbortableStreamedRequest(
      request.method,
      request.uri,
      abortTrigger: request.abortTrigger,
    )..headers.addAll(request.headers);
    final length = request.contentLength;
    if (length != null) outgoing.contentLength = length;
    // The pipe ends with the body; a body that errors fails the request, and the error is the
    // client's to report.
    unawaited(
      stream.pipe(outgoing.sink).then<void>((_) {}, onError: (Object _) {}),
    );
    return outgoing;
  }
}
