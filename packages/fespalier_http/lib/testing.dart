/// Fakes for tests of code that sends HTTP through `package:fespalier_http` (since 0.15.0):
/// [FakeHttpClient], an `http.Client` that answers from a handler and honours an abort, and
/// [FakeHttpCredentials], an [HttpCredentials] with a canned answer.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'fespalier_http.dart';

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

/// The attempt a [FakeHttpCredentials] made.
final class FakeHttpAuthorization implements HttpAuthorization {
  /// An attempt; [number] counts the sends of one request from 1.
  FakeHttpAuthorization._({
    required this.method,
    required this.uri,
    required this.headers,
    required this.number,
  });

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final Map<String, String> headers;

  /// Which send of the request this is, from 1.
  final int number;

  @override
  bool get isReplay => number > 1;
}

/// An [HttpCredentials] with a canned answer, for tests of a client or a transfer that takes one.
///
/// It covers the origins it was given, attaches [headers] (`Authorization: Bearer fake` by
/// default) and asks for a re-send of the responses whose status is in [retryOn], once per
/// request. [authorizeCalls] and [retryCalls] record what it was asked.
final class FakeHttpCredentials implements HttpCredentials {
  /// Credentials for [origins] (scheme, host and port).
  FakeHttpCredentials({
    required Iterable<Uri> origins,
    this.headers = const <String, String>{'Authorization': 'Bearer fake'},
    this.retryOn = const <int>{401},
  }) : origins = List<Uri>.unmodifiable(origins);

  /// The origins that get [headers].
  final List<Uri> origins;

  /// The headers attached to a covered request.
  final Map<String, String> headers;

  /// The response statuses that ask for one re-send.
  final Set<int> retryOn;

  /// The `method uri` of every [authorize] call, oldest first.
  final List<String> authorizeCalls = <String>[];

  /// The status code of every [retry] call, oldest first.
  final List<int> retryCalls = <int>[];

  @override
  bool covers(Uri uri) {
    if (uri.host.isEmpty) return false;
    for (final origin in origins) {
      if (origin.scheme == uri.scheme &&
          origin.host == uri.host &&
          origin.port == uri.port) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<HttpAuthorization> authorize(
    String method,
    Uri uri, {
    HttpAuthorization? previous,
  }) async {
    if (previous != null && previous is! FakeHttpAuthorization) {
      throw ArgumentError.value(
        previous,
        'previous',
        'not an attempt of this FakeHttpCredentials',
      );
    }
    authorizeCalls.add('$method $uri');
    final number = previous is FakeHttpAuthorization ? previous.number + 1 : 1;
    return FakeHttpAuthorization._(
      method: method,
      uri: uri,
      headers: covers(uri) ? headers : const <String, String>{},
      number: number,
    );
  }

  @override
  Future<bool> retry(
    HttpAuthorization attempt, {
    required int statusCode,
    required Map<String, String> headers,
  }) async {
    retryCalls.add(statusCode);
    if (attempt is! FakeHttpAuthorization) {
      throw ArgumentError.value(
        attempt,
        'attempt',
        'not an attempt of this FakeHttpCredentials',
      );
    }
    return attempt.headers.isNotEmpty &&
        attempt.number == 1 &&
        retryOn.contains(statusCode);
  }
}
