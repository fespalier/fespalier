/// Fakes for tests of code that sends HTTP through `package:fespalier_http` (since 0.15.0):
/// [FakeHttpClient], an `http.Client` that answers from a handler and honours an abort.
/// `FakeHttpCredentials` moved to `package:fespalier_transport/testing.dart` in 0.21.0, with
/// `FakeTransport`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One request a [FakeHttpClient] was sent, with its body read.
final class SentRequest {
  /// Records a request.
  SentRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.abortable,
  });

  /// The HTTP method.
  final String method;

  /// The URL.
  final Uri url;

  /// The headers, as sent.
  final Map<String, String> headers;

  /// The body bytes; empty for a request without one.
  final Uint8List body;

  /// Whether the request carried an `abortTrigger`.
  final bool abortable;
}

/// An `http.Client` that answers every request from [handler], for tests.
///
/// It honours `Abortable.abortTrigger` the way `package:http`'s own clients do: a request whose
/// trigger completes before the handler answers fails with `RequestAbortedException`. It starts no
/// timer (`Future.any` over the trigger and the handler) and listens to nothing. Every request is
/// recorded in [requests], and [abortCount] counts the aborted ones.
final class FakeHttpClient extends http.BaseClient {
  /// A client that answers with [handler]. The handler gets the request and its body bytes; it may
  /// return a future that never completes to model a request in flight.
  FakeHttpClient(this.handler);

  /// Answers a request.
  final FutureOr<http.Response> Function(
    http.BaseRequest request,
    Uint8List body,
  )
  handler;

  final List<SentRequest> _requests = <SentRequest>[];
  int _aborts = 0;
  bool _closed = false;

  /// The requests sent so far, oldest first.
  List<SentRequest> get requests => List<SentRequest>.unmodifiable(_requests);

  /// How many requests were aborted by their `abortTrigger`.
  int get abortCount => _aborts;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final Object asObject = request;
    final trigger = asObject is http.Abortable ? asObject.abortTrigger : null;
    _requests.add(
      SentRequest(
        method: request.method,
        url: request.url,
        headers: Map<String, String>.of(request.headers),
        body: body,
        abortable: trigger != null,
      ),
    );
    final answer = Future<http.Response>.sync(() => handler(request, body));
    final http.Response response;
    if (trigger == null) {
      response = await answer;
    } else {
      // The trigger comes first: one that already fired wins over a handler that answers at once.
      response = await Future.any<http.Response>([
        trigger.then<http.Response>((_) {
          _aborts++;
          throw http.RequestAbortedException(request.url);
        }),
        answer,
      ]);
    }
    return http.StreamedResponse(
      http.ByteStream.fromBytes(response.bodyBytes),
      response.statusCode,
      contentLength: response.bodyBytes.length,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _closed = true;
}
