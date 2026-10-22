import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fespalier_frb/testing.dart';
import 'package:frb_cose_example/src/core.dart';

/// What the stub server was sent, for the assertions.
final class SeenRequest {
  const SeenRequest({
    required this.path,
    required this.contentType,
    required this.contract,
    required this.idempotencyKey,
    required this.bodyLength,
  });

  final String path;
  final String? contentType;
  final String? contract;
  final String? idempotencyKey;
  final int bodyLength;
}

/// A plain HTTP server that stands in for the cose server. It answers `registerDevice` with the `DeviceView` of the
/// key it is given, and every other call with an unsigned 503 (no COSE envelope). It records what it was sent.
final class StubServer {
  StubServer._(this._server, this._kid, this._thumbprint);

  static const registerPath = '/rpc/procedure.registerDevice';

  final HttpServer _server;
  final String _kid;
  final String _thumbprint;
  final List<SeenRequest> requests = [];

  /// Starts on a free loopback port. `kid` and `thumbprint` are the device key's, as the core computes them.
  static Future<StubServer> start({
    required String kid,
    required String thumbprint,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = StubServer._(server, kid, thumbprint);
    server.listen(stub._handle);
    return stub;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  /// The requests to one path.
  List<SeenRequest> to(String path) =>
      requests.where((request) => request.path == path).toList();

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await request.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final path = request.uri.path;
    requests.add(
      SeenRequest(
        path: path,
        contentType: request.headers.value('content-type'),
        contract: request.headers.value('cratestack-contract'),
        idempotencyKey: request.headers.value('idempotency-key'),
        bodyLength: body.length,
      ),
    );
    final response = request.response;
    if (path == registerPath) {
      response.statusCode = 200;
      response.headers.contentType = ContentType('application', 'cbor');
      response.add(deviceView(_kid, _thumbprint));
    } else {
      response.statusCode = 503;
      response.headers.contentType = ContentType.text;
      response.write('unavailable');
    }
    await response.close();
  }
}

/// The CBOR of `DeviceView { kid, thumbprint }`: a map of two text keys to two text values.
Uint8List deviceView(String kid, String thumbprint) {
  final out = BytesBuilder();
  _head(out, 5, 2); // a map of two pairs
  _text(out, 'kid');
  _text(out, kid);
  _text(out, 'thumbprint');
  _text(out, thumbprint);
  return out.takeBytes();
}

void _text(BytesBuilder out, String text) {
  final bytes = utf8.encode(text);
  _head(out, 3, bytes.length);
  out.add(bytes);
}

/// A CBOR head: the major type and the length (or the count) in the shortest form.
void _head(BytesBuilder out, int majorType, int value) {
  final major = majorType << 5;
  if (value < 24) {
    out.addByte(major | value);
  } else if (value < 0x100) {
    out
      ..addByte(major | 24)
      ..addByte(value);
  } else {
    out
      ..addByte(major | 25)
      ..addByte(value >> 8)
      ..addByte(value & 0xff);
  }
}

/// The device's signer for a test: it counts the calls and answers a fixed 64-byte signature, or null.
///
/// The core does not check the signature (the server does, and the Rust tests run that server), so a fixed answer
/// reaches the wire as a well-formed COSE message.
final class CountingSigner {
  CountingSigner({this.signs = true});

  final bool signs;
  int calls = 0;

  FutureOr<Uint8List?> sign(Uint8List toBeSigned) {
    calls++;
    if (!signs) return null;
    return Uint8List.fromList(List<int>.filled(64, 1));
  }
}

/// The core of a test of the page or of the transport: it answers from a script, records every call, and keeps the
/// journal and the change stream the core keeps (a call emits `Called`, whatever its answer), so the `/core` page
/// reads it as it reads the real core.
final class FakeNotesCore implements NotesCore {
  /// A fake core. [available] false is a build without one.
  FakeNotesCore({this.available = true, this.kid = 'fake-kid'});

  @override
  final bool available;

  /// The key id the core reports.
  final String kid;

  /// Whether the core reports the key registered. A test sets it, as the real core would after a registration.
  bool registered = false;

  /// Every call, in order: the op, its arguments as JSON and its idempotency key (empty for a read).
  final List<({String op, String argsJson, String idempotencyKey})> calls = [];

  /// What the next calls do, in order: a [CoreAnswer] to return or a [CoreError] to throw. Once it is empty, a call
  /// answers `200` with an empty object.
  final List<Object> next = [];

  final List<JournalEntry> _journal = [];
  final FakeChangeSource<CoreEvent> _events = FakeChangeSource<CoreEvent>();

  @override
  Future<CoreAnswer> call({
    required String op,
    required String argsJson,
    required String idempotencyKey,
  }) async {
    calls.add((op: op, argsJson: argsJson, idempotencyKey: idempotencyKey));
    final scripted = next.isEmpty ? null : next.removeAt(0);
    if (scripted is CoreError) {
      _record(op, idempotencyKey, JournalOutcome.unreachable, null);
      throw scripted;
    }
    final answer = scripted is CoreAnswer
        ? scripted
        : const CoreAnswer(status: 200, bodyJson: '{}');
    _record(op, idempotencyKey, JournalOutcome.answered, answer.status);
    return answer;
  }

  void _record(String op, String key, JournalOutcome outcome, int? status) {
    _journal.add(
      JournalEntry(
        op: op,
        idempotencyKey: key,
        outcome: outcome,
        status: status,
        sent: true,
      ),
    );
    _events.emit(CoreEvent(kind: CoreEventKind.called, op: op));
  }

  /// Delivers [event] on the change stream, as the core does for a registration or a forgotten key.
  void emit(CoreEvent event) => _events.emit(event);

  @override
  Stream<CoreEvent> changes() => _events.stream;

  @override
  List<JournalEntry> journal() => List.unmodifiable(_journal);

  @override
  CoreStatus status() => CoreStatus(registered: registered, kid: kid);
}
