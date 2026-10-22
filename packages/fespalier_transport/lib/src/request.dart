import 'dart:typed_data';

/// One request, as a transport sends it (since 0.21.0): the method, the URL, the headers, and the
/// body as the exact bytes that go on the wire, or as a stream.
///
/// It is the same value for `package:http`, for Dio and for a client of your own, which is what
/// lets a decorator (`SessionTransport`, `WriteGuardTransport`) sit between any of them and any
/// caller.
final class TransportRequest {
  /// A request. At most one of [body] and [bodyStream]; with neither, the request has no body.
  const TransportRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.bodyStream,
    this.contentLength,
    this.abortTrigger,
    this.attributes = const <String, Object?>{},
  }) : assert(
         body == null || bodyStream == null,
         'a request has a body or a body stream, not both',
       );

  /// The HTTP method, upper-case.
  final String method;

  /// The absolute URL.
  final Uri uri;

  /// The headers, with the names the caller wrote.
  final Map<String, String> headers;

  /// The exact bytes on the wire, when known up front: always for JSON, CBOR, a form and a
  /// finalized multipart body. Null when there is none, or when [bodyStream] is set.
  final Uint8List? body;

  /// A streamed body. It can be read once, so a request with one is sent once and never again.
  final Stream<List<int>>? bodyStream;

  /// The length of [bodyStream], when known.
  final int? contentLength;

  /// Completes to abort the send (`package:http`'s `abortTrigger`, Dio's `CancelToken`).
  final Future<void>? abortTrigger;

  /// For decorators; never sent. `fespalier.auth.replay: true` marks a send that followed a
  /// verdict, and an app can add its own (a key-role hint).
  final Map<String, Object?> attributes;

  /// Whether the request can be sent again: its body is bytes (or there is none).
  bool get replayable => bodyStream == null;

  /// Whether the request has a body (bytes or a stream).
  bool get hasBody => bodyStream != null || (body != null && body!.isNotEmpty);

  /// This request with [method], [uri], [headers] or [attributes] replaced.
  TransportRequest copyWith({
    String? method,
    Uri? uri,
    Map<String, String>? headers,
    Map<String, Object?>? attributes,
  }) => TransportRequest(
    method: method ?? this.method,
    uri: uri ?? this.uri,
    headers: headers ?? this.headers,
    body: body,
    bodyStream: bodyStream,
    contentLength: contentLength,
    abortTrigger: abortTrigger,
    attributes: attributes ?? this.attributes,
  );

  @override
  String toString() => 'TransportRequest($method $uri)';
}
