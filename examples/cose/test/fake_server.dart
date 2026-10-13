import 'dart:async';
import 'dart:typed_data';

import 'package:cose_example/src/contracts.g.dart';
import 'package:cose_example/src/cose/cose.dart';
import 'package:cose_example/src/cose_transport.dart';
import 'package:cose_example/src/payload.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the fake server saw of one signed request.
typedef SeenRequest = ({
  String op,
  Uint8List payload,
  Uint8List cti,
  int iat,
  String? idempotencyKey,
  String? selector,
});

/// A server in the test's own process that speaks the example's wire format with
/// [CoseOpener] and [CoseSealer], the same code the app uses: enough to test the transport's
/// behaviour (what it sends per attempt, how it reads each kind of answer) without the Rust
/// server, which `test/e2e_test.dart` runs for real. It is not a second implementation of the
/// server's checks: it opens what the registered key signed, refuses a replayed `cti`, and does
/// what each test tells it to.
final class FakeCoseServer {
  /// A server with its own response key.
  FakeCoseServer()
    : _signer = FakeDpopSigner(seed: 'cose example fake server') {
    _sealer = CoseSealer(_signer);
  }

  final FakeDpopSigner _signer;
  late final CoseSealer _sealer;
  final List<CoseVerifyKey> _devices = [];
  final Set<String> _ctis = {};

  /// The signed requests it opened, in order.
  final List<SeenRequest> seen = [];

  /// How many registrations it got.
  int registrations = 0;

  /// The notes it keeps (all devices share them here).
  final List<Map<String, Object?>> notes = [];

  /// When set, a signed request is answered with this instead of being processed.
  FutureOr<http.Response?> Function(http.Request request)? override;

  /// Seals answers with this key instead of its own (a server nobody pinned).
  CoseSealer? impostor;

  /// Seals every answer for another request's digest (an answer replayed from elsewhere).
  bool answerForAnotherRequest = false;

  /// Throws instead of answering the next [dropAnswers] requests, after processing them: the
  /// request landed, the answer did not.
  int dropAnswers = 0;

  /// A restart: every registered device is forgotten.
  void forget() => _devices.clear();

  /// The key the app pins.
  Future<CoseConfig> config() async {
    final key = await _sealer.identity();
    return CoseConfig(
      baseUrl: Uri.parse('http://server.test'),
      audience: coseAudience,
      serverKey: key,
    );
  }

  /// The HTTP client to give the transport.
  late final MockClient client = MockClient(_handle);

  static final Map<String, String> _cbor = {'content-type': 'application/cbor'};

  http.Response _plain(int status, Object? body) =>
      http.Response.bytes(encodePayload(body), status, headers: _cbor);

  http.Response _refusal(int status) => _plain(status, {
    'code': 'unauthenticated',
    'message': 'request could not be authenticated',
  });

  Future<http.Response> _handle(http.Request request) async {
    final op = request.url.path.replaceFirst('/rpc/', '');
    final contract = coseOps[op];
    if (contract == null) {
      return _plain(404, {'code': 'NOT_FOUND', 'message': ''});
    }
    if (!contract.signed) {
      final type = request.headers['content-type'] ?? '';
      if (type.startsWith('application/cose')) return _refusal(415);
      final args =
          (decodePayload(request.bodyBytes)! as Map<String, Object?>)['args']!
              as Map<String, Object?>;
      registrations++;
      final key = Esp256VerifyKey.jwk({
        'kty': 'EC',
        'crv': 'P-256',
        'x': args['x']! as String,
        'y': args['y']! as String,
      });
      _devices.add(key);
      return _plain(200, {
        'kid': _hex(key.kid),
        'thumbprint': thumbprintHex(key),
      });
    }
    if (await override?.call(request) case final answer?) return answer;
    if (!(request.headers['content-type'] ?? '').startsWith(
      'application/cose',
    )) {
      return _refusal(401);
    }
    final bind = CoseBinding(
      audience: coseAudience,
      method: 'POST',
      route: op,
      contractSha: _unhex(contract.digest),
      idempotencyKey: request.headers['idempotency-key'],
    );
    final CoseOpened opened;
    try {
      opened = CoseOpener(_devices).openRequest(request.bodyBytes, bind);
    } on CoseRejected {
      return _refusal(401);
    }
    if (!_ctis.add(_hex(opened.cti!))) return _refusal(401);
    seen.add((
      op: op,
      payload: opened.payload,
      cti: opened.cti!,
      iat: opened.iat!,
      idempotencyKey: request.headers['idempotency-key'],
      selector: request.headers[contractHeader.toLowerCase()],
    ));

    final args =
        (decodePayload(opened.payload)! as Map<String, Object?>)['args']!
            as Map<String, Object?>;
    final Object? output;
    switch (op) {
      case 'procedure.addNote':
        final note = {'id': notes.length + 1, 'text': args['text']};
        notes.add(note);
        output = note;
      default:
        output = {'notes': notes};
    }
    if (dropAnswers > 0) {
      dropAnswers--;
      throw http.ClientException('connection reset');
    }
    return await _seal(request, bind, 200, output);
  }

  /// A sealed answer of [status] to [request], as the server seals one.
  Future<http.Response> sealed(
    http.Request request,
    int status,
    Object? body,
  ) async {
    final op = request.url.path.replaceFirst('/rpc/', '');
    final bind = CoseBinding(
      audience: coseAudience,
      method: 'POST',
      route: op,
      contractSha: _unhex(coseOps[op]!.digest),
      idempotencyKey: request.headers['idempotency-key'],
    );
    return _seal(request, bind, status, body);
  }

  Future<http.Response> _seal(
    http.Request request,
    CoseBinding bind,
    int status,
    Object? body,
  ) async {
    final digest = answerForAnotherRequest
        ? Uint8List(32)
        : requestDigestOf(request.bodyBytes);
    final answered = bind.answeredBy(
      ResponseLink(requestDigest: digest, status: status),
    );
    final bytes = await (impostor ?? _sealer).sealResponse(
      encodePayload(body),
      answered,
    );
    return http.Response.bytes(
      bytes,
      status,
      headers: {'content-type': coseContentType},
    );
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
