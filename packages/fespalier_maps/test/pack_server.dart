// A server for file pack tests: a body served in chunks, with the parts of HTTP a pack download
// leans on (Range, If-Range, ETag, Content-Range, 416) and the faults to play: a server that
// ignores Range, one that answers a fixed status, a stream that breaks, and a gate that holds the
// body between chunks so a test can pause, restart or remove in the middle.
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// [length] bytes that are not the same from one offset to the next, so an append at the wrong
/// offset changes the hash.
List<int> sampleBody(int length) => [
  for (var i = 0; i < length; i++) (i * 7 + i ~/ 256) % 251,
];

String sha256Of(List<int> bytes) => crypto.sha256.convert(bytes).toString();

class PackServer {
  PackServer(this.body, {this.chunk = 100, this.etag = '"v1"'});

  /// What the URL serves.
  List<int> body;

  /// Bytes per chunk of the stream.
  final int chunk;

  /// The `ETag` it sends; null sends none.
  String? etag;

  /// Whether `Range` is honoured. False answers 200 with the whole body.
  bool honourRange = true;

  /// When set, every request is answered with this status and an empty body.
  int? forceStatus;

  /// Headers of a [forceStatus] answer.
  Map<String, String> forceHeaders = const {};

  /// Called before each chunk of a response (index within that response), so a test can hold it.
  Future<void> Function(int index)? beforeChunk;

  /// When set, the first response's stream fails after this many bytes of its body, once.
  int? breakAfter;

  /// When set, a request throws this instead of answering (no connection).
  Object? connectError;

  /// The headers of each request, in order.
  final List<Map<String, String>> requests = [];

  late final MockClient client = MockClient.streaming((request, _) async {
    requests.add({...request.headers});
    final failure = connectError;
    if (failure != null) throw failure;
    final forced = forceStatus;
    if (forced != null) {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        forced,
        headers: forceHeaders,
      );
    }
    final headers = <String, String>{'etag': ?etag};
    var start = 0;
    var status = 200;
    final range = request.headers['range'];
    final ifRange = request.headers['if-range'];
    if (range != null && honourRange && (ifRange == null || ifRange == etag)) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length) {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          416,
          headers: {'content-range': 'bytes */${body.length}'},
        );
      }
      status = 206;
      headers['content-range'] =
          'bytes $start-${body.length - 1}/${body.length}';
    }
    final slice = body.sublist(start);
    final cut = breakAfter;
    breakAfter = null;
    return http.StreamedResponse(
      _emit(slice, cut),
      status,
      contentLength: slice.length,
      headers: headers,
    );
  });

  Stream<List<int>> _emit(List<int> slice, int? cutAfter) async* {
    var sent = 0;
    var index = 0;
    while (sent < slice.length) {
      await beforeChunk?.call(index++);
      if (cutAfter != null && sent >= cutAfter) {
        throw http.ClientException('connection closed');
      }
      final end = sent + chunk > slice.length ? slice.length : sent + chunk;
      yield slice.sublist(sent, end);
      sent = end;
    }
  }
}
