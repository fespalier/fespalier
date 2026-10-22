/// Fakes for tests of code that sends through `package:fespalier_transport` (since 0.21.0):
/// [FakeTransport], a transport that answers from a handler or a script and honours an abort, and
/// [FakeHttpCredentials], an `HttpCredentials` with a canned answer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'fespalier_transport.dart';

/// A response for a test: [status], a text [body] (UTF-8) and [headers] (lower-cased for you).
TransportResponse fakeResponse(
  int status, {
  String body = '',
  Map<String, String> headers = const <String, String>{},
}) => TransportResponse(
  statusCode: status,
  headers: <String, String>{
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  },
  body: Stream<List<int>>.value(utf8.encode(body)),
);

/// One request a [FakeTransport] was sent, with its body read.
final class SentRequest {
  /// Records a request.
  SentRequest(this.request, this.body);

  /// The request as it arrived.
  final TransportRequest request;

  /// The body bytes; empty for a request without one.
  final Uint8List body;

  /// The HTTP method.
  String get method => request.method;

  /// The URL.
  Uri get url => request.uri;

  /// The headers, as sent.
  Map<String, String> get headers => request.headers;

  /// The headers with lower-case names.
  Map<String, String> get lowerHeaders => <String, String>{
    for (final entry in request.headers.entries)
      entry.key.toLowerCase(): entry.value,
  };

  /// Whether the request carried an `abortTrigger`.
  bool get abortable => request.abortTrigger != null;

  /// The body as UTF-8 text.
  String get text => utf8.decode(body, allowMalformed: true);
}

/// A transport that answers every request from [handler], for tests.
///
/// It honours `TransportRequest.abortTrigger` the way a real one does: a request whose trigger
/// completes before the handler answers fails with `TransportAborted`. It starts no timer
/// (`Future.any` over the trigger and the handler) and listens to nothing. Every request is
/// recorded in [requests], and [abortCount] counts the aborted ones. The handler may throw a
/// `TransportFailure`, which is what a transport does when no response came back.
final class FakeTransport implements HttpTransport {
  /// A transport that answers with [handler]. The handler gets the request and its body bytes; it
  /// may return a future that never completes to model a request in flight.
  FakeTransport(this.handler);

  /// A transport that answers with [answers], one per request, in order: a `TransportResponse` or
  /// a `TransportFailure` to throw. A request past the end of the script fails the test with a
  /// `StateError`.
  FakeTransport.script(Iterable<Object> answers)
    : handler = _scripted(List<Object>.of(answers));

  /// Answers a request.
  final FutureOr<TransportResponse> Function(
    TransportRequest request,
    Uint8List body,
  )
  handler;

  final List<SentRequest> _requests = <SentRequest>[];
  int _aborts = 0;

  /// The requests sent so far, oldest first.
  List<SentRequest> get requests => List<SentRequest>.unmodifiable(_requests);

  /// How many requests were aborted by their `abortTrigger`.
  int get abortCount => _aborts;

  static FutureOr<TransportResponse> Function(TransportRequest, Uint8List)
  _scripted(List<Object> answers) {
    var next = 0;
    return (request, body) {
      if (next >= answers.length) {
        throw StateError(
          'FakeTransport: no answer scripted for request ${next + 1} '
          '(${request.method} ${request.uri})',
        );
      }
      final answer = answers[next++];
      if (answer is TransportFailure) throw answer;
      return answer as TransportResponse;
    };
  }

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final stream = request.bodyStream;
    final Uint8List body;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      body = builder.takeBytes();
    } else {
      body = request.body ?? Uint8List(0);
    }
    _requests.add(SentRequest(request, body));
    final answer = Future<TransportResponse>.sync(() => handler(request, body));
    final trigger = request.abortTrigger;
    if (trigger == null) return answer;
    // The trigger comes first: one that already fired wins over a handler that answers at once.
    return Future.any<TransportResponse>([
      trigger.then<TransportResponse>((_) {
        _aborts++;
        throw TransportAborted(null, request.uri);
      }),
      answer,
    ]);
  }
}

/// The attempt a [FakeHttpCredentials] made.
final class FakeHttpAuthorization implements HttpAuthorization {
  FakeHttpAuthorization._({
    required this.request,
    required this.headers,
    required this.number,
  });

  /// The request this send is for.
  final TransportRequest request;

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

  /// The requests every [authorize] call was given, oldest first.
  final List<TransportRequest> authorizeRequests = <TransportRequest>[];

  /// The status code of every [retry] call, oldest first.
  final List<int> retryCalls = <int>[];

  /// The body of every [retry] call that had one buffered (null otherwise), oldest first.
  final List<String?> retryBodies = <String?>[];

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
    TransportRequest request, {
    HttpAuthorization? previous,
  }) async {
    if (previous != null && previous is! FakeHttpAuthorization) {
      throw ArgumentError.value(
        previous,
        'previous',
        'not an attempt of this FakeHttpCredentials',
      );
    }
    authorizeCalls.add('${request.method} ${request.uri}');
    authorizeRequests.add(request);
    final number = previous is FakeHttpAuthorization ? previous.number + 1 : 1;
    return FakeHttpAuthorization._(
      request: request,
      headers: covers(request.uri) ? headers : const <String, String>{},
      number: number,
    );
  }

  @override
  Future<bool> retry(
    HttpAuthorization attempt,
    TransportResponse response,
  ) async {
    retryCalls.add(response.statusCode);
    retryBodies.add(
      response.isBuffered
          ? utf8.decode(await response.bytes(), allowMalformed: true)
          : null,
    );
    if (attempt is! FakeHttpAuthorization) {
      throw ArgumentError.value(
        attempt,
        'attempt',
        'not an attempt of this FakeHttpCredentials',
      );
    }
    return attempt.headers.isNotEmpty &&
        attempt.number == 1 &&
        retryOn.contains(response.statusCode);
  }
}
