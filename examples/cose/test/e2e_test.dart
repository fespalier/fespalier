// The app's CoseTransport against the real server (examples/cose/server), as a process.
//
//   cd examples/cose/server && cargo build --locked
//   cd .. && COSE_SERVER_BIN=server/target/debug/cose-demo-server flutter test test/e2e_test.dart
//
// Without COSE_SERVER_BIN the file skips, saying why; with FSP_REQUIRE_COSE_SERVER=1 (CI's `cose`
// job) a missing binary fails instead, so a run cannot pass by skipping. These are plain `test`s:
// they use real sockets, which a widget test's fake async would freeze.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cose_example/src/contracts.g.dart';
import 'package:cose_example/src/cose/cose.dart';
import 'package:cose_example/src/cose_transport.dart';
import 'package:cose_example/src/notes.dart';
import 'package:cose_example/src/payload.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const RpcCall _list = RpcCall(Ops.listNotes, <String, Object?>{});
RpcCall _add(String text) => RpcCall(Ops.addNote, {'text': text});

/// A running `cose-demo-server`, from the one JSON line it prints.
class _Server {
  _Server(this.process, this.config);

  final Process process;
  final CoseConfig config;

  static Future<_Server> start(String binary) async {
    final process = await Process.start(binary, ['--listen', '127.0.0.1:0']);
    unawaited(process.stderr.drain<void>());
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    try {
      final line = await lines.first.timeout(const Duration(seconds: 30));
      final hello = jsonDecode(line) as Map<String, Object?>;
      return _Server(
        process,
        CoseConfig.fromJwk(
          baseUrl: Uri.parse('http://${hello['addr']}'),
          audience: hello['audience']! as String,
          jwk: jsonEncode(hello['server_public_jwk']),
        ),
      );
    } on Object {
      process.kill();
      rethrow;
    }
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

/// A device: a key, the app's transport over it, and the raw requests a test sends by hand.
class _Device {
  _Device._(this.signer, this.sealer, this.identity, this.server, this.client);

  final FakeDpopSigner signer;
  final CoseSealer sealer;
  final Esp256VerifyKey identity;
  final _Server server;
  final http.Client client;

  static Future<_Device> make(
    _Server server, {
    String seed = 'device a',
  }) async {
    final signer = FakeDpopSigner(seed: seed);
    final sealer = CoseSealer(signer);
    return _Device._(
      signer,
      sealer,
      await sealer.identity(),
      server,
      http.Client(),
    );
  }

  /// The app's transport; registers the key before the first signed call, like the app.
  CoseTransport transport({bool register = true, CoseConfig? config}) {
    late final CoseTransport transport;
    final registrar = DeviceRegistrar(
      signer: signer,
      identity: identity,
      send: (call) => transport.send(call),
    );
    return transport = CoseTransport(
      config: config ?? server.config,
      sealer: sealer,
      client: client,
      beforeSigned: register ? registrar.ensure : null,
    );
  }

  /// Registers the key by hand (a plain call).
  Future<void> register() async {
    final jwk = await signer.publicJwk();
    await transport(
      register: false,
    ).send(RpcCall(Ops.registerDevice, {'x': jwk['x'], 'y': jwk['y']}));
  }

  CoseBinding binding(String op, {String? idempotencyKey}) => CoseBinding(
    audience: server.config.audience,
    method: 'POST',
    route: op,
    contractSha: Uint8List.fromList([
      for (var i = 0; i < 64; i += 2)
        int.parse(coseOps[op]!.digest.substring(i, i + 2), radix: 16),
    ]),
    idempotencyKey: idempotencyKey,
  );

  /// A message sealed for [op] over [args], to send by hand.
  Future<Uint8List> seal(
    String op,
    Object? args, {
    String? idempotencyKey,
    int? iat,
  }) => sealer.sealRequest(
    encodePayload({'args': args}),
    binding(op, idempotencyKey: idempotencyKey),
    iat: iat,
  );

  /// POST [body] to [op] as given, on a connection of its own.
  Future<http.Response> post(
    String op,
    List<int> body, {
    String contentType = '',
    Map<String, String> headers = const {},
  }) async {
    final client = http.Client();
    try {
      return await client.post(
        server.config.baseUrl.resolve('/rpc/$op'),
        headers: {
          'content-type': contentType.isEmpty ? coseContentType : contentType,
          'accept': coseContentType,
          ...headers,
        },
        body: body,
      );
    } finally {
      client.close();
    }
  }
}

bool _isCose(http.Response r) =>
    (r.headers['content-type'] ?? '').startsWith('application/cose');

void main() {
  final binary = Platform.environment['COSE_SERVER_BIN'];
  final required = Platform.environment['FSP_REQUIRE_COSE_SERVER'] == '1';
  final missing = binary == null || binary.isEmpty;
  if (missing) {
    test(
      'the app against the real server',
      () {
        if (required) {
          fail(
            'FSP_REQUIRE_COSE_SERVER=1 but COSE_SERVER_BIN is not set: build '
            'examples/cose/server and point COSE_SERVER_BIN at cose-demo-server',
          );
        }
      },
      skip: required
          ? null
          : 'COSE_SERVER_BIN is not set (cd examples/cose/server && cargo build --locked, '
                'then COSE_SERVER_BIN=server/target/debug/cose-demo-server)',
    );
    return;
  }

  late _Server server;
  late _Device device;
  setUp(() async {
    server = await _Server.start(binary);
    device = await _Device.make(server);
  });
  tearDown(() async {
    device.client.close();
    await server.stop();
  });

  test(
    'registers the key, writes under an idempotency key and reads, every answer sealed and verified',
    () async {
      final transport = device.transport();

      // The first signed call registers the key (plain CBOR), then goes out sealed.
      final written = await transport.send(
        _add('first'),
        idempotencyKey: 'k1#0',
      );
      expect(written, {'id': 1, 'text': 'first'});
      final list = await transport.send(_list);
      expect(notesFromWire(list), [const Note(id: 1, text: 'first')]);

      // The server knows the device by the key's thumbprint.
      final registered = await device
          .transport(register: false)
          .send(
            RpcCall(Ops.registerDevice, {
              'x': (await device.signer.publicJwk())['x'],
              'y': (await device.signer.publicJwk())['y'],
            }),
          );
      expect(registered, {
        'kid': kidHex(device.identity),
        'thumbprint': thumbprintHex(device.identity),
      });
    },
  );

  test(
    'a client that pinned another server key cannot open the answer: Offline, same key',
    () async {
      final other = await CoseSealer(
        FakeDpopSigner(seed: 'not the server'),
      ).identity();
      final wrong = CoseConfig(
        baseUrl: server.config.baseUrl,
        audience: server.config.audience,
        serverKey: other,
      );
      await device.register();
      await expectLater(
        device
            .transport(register: false, config: wrong)
            .send(_add('x'), idempotencyKey: 'k#0'),
        throwsA(isA<CrateStackOffline>()),
      );
      // The write landed all the same: an intent must send again under the same key, not the next.
      final list = await device.transport().send(_list);
      expect(notesFromWire(list), hasLength(1));
    },
  );

  test('one device never reads another one\'s notes', () async {
    await device.transport().send(_add('mine'));
    final other = await _Device.make(server, seed: 'device b');
    addTearDown(other.client.close);
    final list = await other.transport().send(_list);
    expect(notesFromWire(list), isEmpty);
  });

  test(
    'a write whose answer was lost, sent again under its key, is one note',
    () async {
      await device.register();
      // The first attempt reaches the server, and the phone never reads the answer.
      final lost = await device.seal(Ops.addNote, {
        'text': 'once',
      }, idempotencyKey: 'lost#0');
      await device.post(
        Ops.addNote,
        lost,
        headers: {'idempotency-key': 'lost#0'},
      );
      // The retry is the app's: a new message, the same payload and key.
      final transport = device.transport();
      final again = await transport.send(
        _add('once'),
        idempotencyKey: 'lost#0',
      );
      expect(again, {'id': 1, 'text': 'once'});
      expect(notesFromWire(await transport.send(_list)), [
        const Note(id: 1, text: 'once'),
      ]);
    },
  );

  test(
    'early refusals over one pooled client lose none (the server reads the body first)',
    () async {
      await device.register();
      final client = http.Client();
      addTearDown(client.close);
      final uri = server.config.baseUrl.resolve('/rpc/${Ops.listNotes}');
      final sealed = await device.seal(Ops.listNotes, <String, Object?>{});
      var lost = 0;
      // Three refusals the envelope layer makes from the headers alone, 100 times each, all on
      // the one connection pool the app's own transport has.
      for (var i = 0; i < 100; i++) {
        for (final (status, headers, body) in [
          (401, {'content-type': 'application/cbor'}, sealed),
          (
            426,
            {'content-type': coseContentType, contractHeader: 'AAAAAAAAAAA'},
            sealed,
          ),
          (
            415,
            {'content-type': coseContentType},
            await device.seal(Ops.registerDevice, {'x': 'a', 'y': 'b'}),
          ),
        ]) {
          final target = status == 415
              ? server.config.baseUrl.resolve('/rpc/${Ops.registerDevice}')
              : uri;
          try {
            final response = await client.post(
              target,
              headers: headers,
              body: body,
            );
            expect(response.statusCode, status);
          } on http.ClientException {
            lost++;
          }
        }
      }
      expect(lost, 0, reason: 'of 300 early refusals');
    },
  );

  group('refusals', () {
    test('a key nobody registered: 401, unsigned, Unauthenticated', () async {
      final sealed = await device.seal(Ops.listNotes, <String, Object?>{});
      final response = await device.post(Ops.listNotes, sealed);
      expect(response.statusCode, 401);
      expect(
        _isCose(response),
        isFalse,
        reason: 'the layer\'s refusal is not sealed',
      );
      expect(decodePayload(response.bodyBytes), {
        'code': 'unauthenticated',
        'message': 'request could not be authenticated',
      });

      await expectLater(
        device
            .transport(register: false)
            .send(_add('x'), idempotencyKey: 'k#0'),
        throwsA(isA<CrateStackUnauthenticated>()),
      );
    });

    test(
      'a refusal of a registered device is sealed too, and is not a 401',
      () async {
        await device.register();
        final sealed = await device.seal(Ops.addNote, <String, Object?>{});
        final response = await device.post(Ops.addNote, sealed);
        expect(response.statusCode, 400);
        expect(
          _isCose(response),
          isTrue,
          reason: 'the server seals every answer to a signed call',
        );

        await expectLater(
          device.transport().send(
            const RpcCall(Ops.addNote, <String, Object?>{}),
          ),
          throwsA(
            isA<CrateStackRefused>()
                .having((e) => e.status, 'status', 400)
                .having((e) => e.code, 'code', 'invalid_argument'),
          ),
        );
      },
    );

    test('a tampered payload: 401, Unauthenticated', () async {
      await device.register();
      final sealed = await device.seal(Ops.addNote, {'text': 'abcdef'});
      final payload = encodePayload({
        'args': {'text': 'abcdef'},
      });
      final at = _indexOf(sealed, payload);
      expect(at, greaterThan(0));
      final tampered = Uint8List.fromList(sealed)
        ..[at + payload.length - 1] ^= 0x01;
      final response = await device.post(Ops.addNote, tampered);
      expect(response.statusCode, 401);
      expect(_isCose(response), isFalse);

      // Not tampered, the same call is accepted: the 401 was the flipped bit.
      expect((await device.post(Ops.addNote, sealed)).statusCode, 200);
    });

    test('a changed protected header, or a changed signature: 401', () async {
      await device.register();
      final sealed = await device.seal(Ops.addNote, {'text': 'abcdef'});
      // d2 84 58 <len> <protected...>: byte 5 is inside the protected header; the last byte is
      // inside the signature.
      for (final at in [5, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed)..[at] ^= 0x01;
        final response = await device.post(Ops.addNote, tampered);
        expect(response.statusCode, 401, reason: 'byte $at');
        expect(_isCose(response), isFalse);
      }
      expect((await device.post(Ops.addNote, sealed)).statusCode, 200);
    });

    test('plain CBOR to a signed op: 401', () async {
      await device.register();
      final response = await device.post(
        Ops.listNotes,
        encodePayload({'args': <String, Object?>{}}),
        contentType: 'application/cbor',
      );
      expect(response.statusCode, 401);
      expect(_isCose(response), isFalse);
    });

    test('COSE to the plain registration: 415', () async {
      final sealed = await device.seal(Ops.registerDevice, {
        'x': 'a',
        'y': 'b',
      });
      final response = await device.post(Ops.registerDevice, sealed);
      expect(response.statusCode, 415);
      expect(_isCose(response), isFalse);

      // Through the app's transport, a refusal that is not a 401.
      await expectLater(
        device
            .transport(register: false)
            .send(
              const RpcCall(Ops.registerDevice, {
                'x': 'not a coordinate',
                'y': '',
              }),
            ),
        throwsA(
          isA<CrateStackRefused>().having((e) => e.status, 'status', 422),
        ),
      );
    });

    test(
      'the same bytes twice: the first is answered, the second is 401',
      () async {
        await device.register();
        final sealed = await device.seal(Ops.addNote, {
          'text': 'once',
        }, idempotencyKey: 'r#0');
        final first = await device.post(
          Ops.addNote,
          sealed,
          headers: {'idempotency-key': 'r#0'},
        );
        expect(first.statusCode, 200);
        expect(_isCose(first), isTrue);
        final second = await device.post(
          Ops.addNote,
          sealed,
          headers: {'idempotency-key': 'r#0'},
        );
        expect(second.statusCode, 401);
        expect(_isCose(second), isFalse);

        // A retry through the transport is a new message (a fresh cti), so it is accepted, and the
        // server runs the write once for the key (the first, raw attempt wrote the note).
        final transport = device.transport();
        await transport.send(_add('once'), idempotencyKey: 'r#0');
        await transport.send(_add('once'), idempotencyKey: 'r#0');
        expect(notesFromWire(await transport.send(_list)), hasLength(1));
      },
    );

    test('an iat outside the skew: 401', () async {
      await device.register();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final stale = await device.seal(
        Ops.listNotes,
        <String, Object?>{},
        iat: now - 3600,
      );
      expect((await device.post(Ops.listNotes, stale)).statusCode, 401);
    });

    test('an idempotency key the signature does not cover: 401', () async {
      await device.register();
      final sealed = await device.seal(Ops.addNote, {
        'text': 'x',
      }, idempotencyKey: 'a#0');
      final response = await device.post(
        Ops.addNote,
        sealed,
        headers: {'idempotency-key': 'b#0'},
      );
      expect(response.statusCode, 401);
    });

    test('a contract selector that names no accepted contract: 426', () async {
      await device.register();
      final sealed = await device.seal(Ops.listNotes, <String, Object?>{});
      final response = await device.post(
        Ops.listNotes,
        sealed,
        headers: {contractHeader: 'AAAAAAAAAAA'},
      );
      expect(response.statusCode, 426);
      expect(_isCose(response), isFalse);

      final outdated = _transportWith(device, {
        Ops.listNotes: const OpContract(
          digest:
              '00000000000000000000000000000000000000000000000000000000000000ff',
          selector: 'AAAAAAAAAAA',
          signed: true,
        ),
      });
      await expectLater(
        outdated.send(_list),
        throwsA(
          isA<CrateStackRefused>().having((e) => e.status, 'status', 426),
        ),
      );
    });
  });
}

/// A transport over [ops] on a connection of its own (see `_Device.post` for why).
CoseTransport _transportWith(_Device device, Map<String, OpContract> ops) {
  final client = http.Client();
  addTearDown(client.close);
  return CoseTransport(
    config: device.server.config,
    sealer: device.sealer,
    client: client,
    ops: ops,
  );
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length && hit; j++) {
      hit = haystack[i + j] == needle[j];
    }
    if (hit) return i;
  }
  return -1;
}
