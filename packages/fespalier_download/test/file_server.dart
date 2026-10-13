// A server for file transfer tests: a body served in chunks, with the parts of HTTP a pack download
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

class FileServer {
  FileServer(this.body, {this.chunk = 100, this.etag = '"v1"'});

  /// What the URL serves.
  List<int> body;

  /// Bytes per chunk of the stream.
  final int chunk;

  /// The `ETag` it sends; null sends none.
  String? etag;

  /// Whether `Range` is honoured. False answers 200 with the whole body.
  bool honourRange = true;

  /// Whether a Range is honoured even when If-Range names another validator (a CDN that ignores it).
  bool ignoreIfRange = false;

  /// When set, every request is answered with this status.
  int? forceStatus;

  /// The body of a [forceStatus] answer (an error page); empty by default.
  List<int> forceBody = const [];

  /// How many response bodies were cancelled before their end.
  int cancelled = 0;

  /// Headers of a [forceStatus] answer.
  Map<String, String> forceHeaders = const {};

  /// Called before each chunk of a response (index within that response), so a test can hold it.
  Future<void> Function(int index)? beforeChunk;

  /// When set, the first response's stream fails after this many bytes of its body, once.
  int? breakAfter;

  /// When set, a request waits for this before it answers (a server that is slow to answer).
  Future<void>? hold;

  /// When set, a request throws this instead of answering (no connection).
  Object? connectError;

  /// The headers of each request, in order.
  final List<Map<String, String>> requests = [];

  late final MockClient client = MockClient.streaming((request, _) async {
    requests.add({...request.headers});
    final failure = connectError;
    if (failure != null) throw failure;
    final abort = request is http.Abortable ? request.abortTrigger : null;
    if (hold != null) await _unlessAborted(hold!, abort, request.url);
    final forced = forceStatus;
    if (forced != null) {
      return http.StreamedResponse(
        _emit(forceBody, null, null, request.url),
        forced,
        headers: forceHeaders,
      );
    }
    final headers = <String, String>{'etag': ?etag};
    var start = 0;
    var status = 200;
    final range = request.headers['range'];
    final ifRange = request.headers['if-range'];
    if (range != null &&
        honourRange &&
        (ifRange == null || ifRange == etag || ignoreIfRange)) {
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
      _emit(slice, cut, abort, request.url),
      status,
      contentLength: slice.length,
      headers: headers,
    );
  });

  /// MockClient does not abort: like the real clients, the stream fails with
  /// RequestAbortedException when the request's abortTrigger completes.
  static Future<void> _unlessAborted(
    Future<void> work,
    Future<void>? abort,
    Uri url,
  ) async {
    final aborted = abort?.then((_) => true);
    final finished = work.then((_) => false);
    if (await Future.any([finished, ?aborted])) {
      throw http.RequestAbortedException(url);
    }
  }

  Stream<List<int>> _emit(
    List<int> slice,
    int? cutAfter,
    Future<void>? abort,
    Uri url,
  ) async* {
    var sent = 0;
    var index = 0;
    try {
      while (sent < slice.length) {
        final gate = beforeChunk?.call(index++);
        if (gate != null) await _unlessAborted(gate, abort, url);
        if (cutAfter != null && sent >= cutAfter) {
          throw http.ClientException('connection closed');
        }
        final end = sent + chunk > slice.length ? slice.length : sent + chunk;
        yield slice.sublist(sent, end);
        sent = end;
      }
    } finally {
      if (sent < slice.length) cancelled++;
    }
  }
}
