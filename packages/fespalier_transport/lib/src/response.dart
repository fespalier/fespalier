import 'dart:async';
import 'dart:typed_data';

/// One response, as a transport answers it (since 0.21.0): the status, the headers with
/// lower-case names, and the body as a stream.
final class TransportResponse {
  /// A response whose [body] is read from a stream, once.
  const TransportResponse({
    required this.statusCode,
    required this.headers,
    required Stream<List<int>> body,
    this.reasonPhrase,
  }) : _stream = body,
       _bytes = null;

  /// A response that already holds its bytes.
  TransportResponse.fromBytes({
    required this.statusCode,
    required this.headers,
    required Uint8List bytes,
    this.reasonPhrase,
  }) : _stream = null,
       _bytes = bytes;

  /// The HTTP status code.
  final int statusCode;

  /// The headers, with lower-case names; repeated ones joined with `, `.
  final Map<String, String> headers;

  /// The reason phrase, when the transport has one.
  final String? reasonPhrase;

  final Stream<List<int>>? _stream;
  final Uint8List? _bytes;

  /// Whether the body is already read, so [bytes] can be called as often as needed and [body]
  /// is a new stream each time.
  bool get isBuffered => _bytes != null;

  /// The body. A response made from a stream gives that stream, which can be listened to once; a
  /// buffered one gives a new stream over its bytes each time.
  Stream<List<int>> get body {
    final bytes = _bytes;
    if (bytes != null) return Stream<List<int>>.value(bytes);
    return _stream!;
  }

  /// The whole body. A response made from a stream reads it, and can be read once; a buffered
  /// one answers again.
  Future<Uint8List> bytes() async {
    final bytes = _bytes;
    if (bytes != null) return bytes;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _stream!) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// [response] with its body read: for a decorator that looks at a 401's body and still hands
  /// the response on. A buffered response is returned as it is.
  static Future<TransportResponse> buffered(TransportResponse response) async {
    if (response.isBuffered) return response;
    return TransportResponse.fromBytes(
      statusCode: response.statusCode,
      headers: response.headers,
      bytes: await response.bytes(),
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  String toString() => 'TransportResponse($statusCode)';
}
