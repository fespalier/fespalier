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
import 'package:http/testing.dart';

import 'fake_server.dart';

const RpcCall _add = RpcCall(Ops.addNote, {'text': 'hello'});
const RpcCall _list = RpcCall(Ops.listNotes, <String, Object?>{});

/// A transport against [server], with the device registered unless [register] is false.
Future<({CoseTransport transport, DeviceRegistrar registrar})> _app(
  FakeCoseServer server, {
  Future<void> Function()? beforeSigned,
  bool register = true,
  http.Client? client,
}) async {
  final signer = FakeDpopSigner();
  final sealer = CoseSealer(signer);
  late final CoseTransport transport;
  final registrar = DeviceRegistrar(
    signer: signer,
    identity: await sealer.identity(),
    send: (call) => transport.send(call),
  );
  transport = CoseTransport(
    config: await server.config(),
    sealer: sealer,
    client: client ?? server.client,
    beforeSigned: beforeSigned ?? (register ? registrar.ensure : null),
    onUnauthenticated: registrar.reset,
  );
  return (transport: transport, registrar: registrar);
}

/// Remembers the last request that went through.
final class _Capture extends http.BaseClient {
  _Capture(this._inner);
  final http.Client _inner;
  late http.Request last;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    last = request as http.Request;
    return _inner.send(request);
  }
}

void main() {
  test(
    'registers the key, then a signed write and a signed read are sealed both ways',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server);

      final note = await app.transport.send(_add, idempotencyKey: 'a#0');
      expect(note, {'id': 1, 'text': 'hello'});
      final list = await app.transport.send(_list);
      expect(notesFromWire(list), [const Note(id: 1, text: 'hello')]);
      expect(server.registrations, 1);
      expect(app.registrar.isRegistered, isTrue);
      // The contract selector the generated table names is sent with each call.
      expect(server.seen.map((s) => s.selector), [
        coseOps[Ops.addNote]!.selector,
        coseOps[Ops.listNotes]!.selector,
      ]);
    },
  );

  test(
    'every attempt is a new message over the same payload under the same key',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server);

      await app.transport.send(_add, idempotencyKey: 'intent#0');
      await app.transport.send(_add, idempotencyKey: 'intent#0');
      final [first, second] = server.seen;
      expect(first.payload, second.payload, reason: 'the same bytes inside');
      expect(
        first.cti,
        isNot(second.cti),
        reason: 'a fresh cti, or the replay check would refuse it',
      );
      expect(first.idempotencyKey, 'intent#0');
      expect(second.idempotencyKey, 'intent#0');
      expect(decodePayload(first.payload), {
        'args': {'text': 'hello'},
      });
    },
  );

  test(
    'the idempotency key is signed: the same bytes under another key are refused',
    () async {
      final server = FakeCoseServer();
      final capture = _Capture(server.client);
      final app = await _app(server, client: capture);
      await app.transport.send(_add, idempotencyKey: 'k#0');
      final sent = capture.last;
      final again = await server.client.post(
        sent.url,
        headers: {...sent.headers, 'idempotency-key': 'k#1'},
        body: sent.bodyBytes,
      );
      // Not even a replay: the signature does not cover the other key.
      expect(again.statusCode, 401);
      expect(server.seen, hasLength(1));
    },
  );

  test(
    'an unregistered key is an unsigned 401: Unauthenticated, so an intent keeps its key',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server, register: false);
      await expectLater(
        app.transport.send(_add, idempotencyKey: 'a#0'),
        throwsA(isA<CrateStackUnauthenticated>()),
      );
      expect(server.seen, isEmpty);
    },
  );

  test(
    'a sealed answer that does not open is Offline, never Unavailable (no next key)',
    () async {
      final server = FakeCoseServer()
        ..impostor = CoseSealer(FakeDpopSigner(seed: 'someone else'));
      final app = await _app(server);
      await expectLater(
        app.transport.send(_add, idempotencyKey: 'a#0'),
        throwsA(isA<CrateStackOffline>()),
      );
      // It reached the server, which kept the write: the same key must be used again.
      expect(server.notes, hasLength(1));
    },
  );

  test('an answer sealed for another request does not open', () async {
    final server = FakeCoseServer()..answerForAnotherRequest = true;
    final app = await _app(server);
    await expectLater(
      app.transport.send(_list),
      throwsA(isA<CrateStackOffline>()),
    );
  });

  test(
    'a lost answer is Offline, and the retry is accepted as a new message',
    () async {
      final server = FakeCoseServer()..dropAnswers = 1;
      final app = await _app(server);
      await expectLater(
        app.transport.send(_add, idempotencyKey: 'a#0'),
        throwsA(isA<CrateStackOffline>()),
      );
      // The retry opens (a fresh cti). This fake server has no idempotency store, so the note is
      // written twice: the real server's idempotency layer (e2e_test.dart) is what prevents that.
      await app.transport.send(_add, idempotencyKey: 'a#0');
      expect(server.seen.map((s) => s.idempotencyKey), ['a#0', 'a#0']);
    },
  );

  test(
    'a registration the server refuses never reaches a signed call as a decision',
    () async {
      for (final status in [400, 422, 429, 500, 503]) {
        final server = FakeCoseServer();
        final refusing = MockClient(
          (_) async => http.Response.bytes(
            encodePayload({'code': 'forged', 'message': 'no'}),
            status,
            headers: {'content-type': 'application/cbor'},
          ),
        );
        final app = await _app(server, client: refusing);
        // Offline, so the intent keeps its key: not Refused (dropped), not Unavailable (next key).
        await expectLater(
          app.transport.send(_add, idempotencyKey: 'a#0'),
          throwsA(isA<CrateStackOffline>()),
          reason: 'registration answered $status',
        );
      }
    },
  );

  test(
    'a sealed 409 is InFlight with Retry-After and a Conflict without',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server);
      for (final retryAfter in [true, false]) {
        server.override = (request) async {
          final sealed = await server.sealed(request, 409, {
            'code': 'conflict',
            'message': 'busy',
          });
          return http.Response.bytes(
            sealed.bodyBytes,
            409,
            headers: {...sealed.headers, if (retryAfter) 'retry-after': '1'},
          );
        };
        await expectLater(
          app.transport.send(_add, idempotencyKey: 'a#0'),
          throwsA(
            retryAfter ? isA<CrateStackInFlight>() : isA<CrateStackConflict>(),
          ),
        );
      }
    },
  );

  test(
    'a sealed 503 (a full idempotency store) is Unavailable, never a refusal',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server);
      server.override = (request) => server.sealed(request, 503, {
        'code': 'unavailable',
        'message': 'too many idempotency keys held',
      });
      await expectLater(
        app.transport.send(_add, idempotencyKey: 'a#0'),
        throwsA(isA<CrateStackUnavailable>()),
      );
    },
  );

  test('a server that forgot the device is healed by the next call', () async {
    final server = FakeCoseServer();
    final app = await _app(server);
    await app.transport.send(_list);
    server.forget();
    await expectLater(
      app.transport.send(_list),
      throwsA(isA<CrateStackUnauthenticated>()),
    );
    // The 401 made the app forget it was registered: the retry registers again, then reads.
    await app.transport.send(_list);
    expect(server.registrations, 2);
  });

  test('an unsealed 200 to a signed call is not an answer', () async {
    final server = FakeCoseServer();
    final app = await _app(server);
    server.override = (_) => http.Response.bytes(
      encodePayload({'notes': <Object?>[]}),
      200,
      headers: {'content-type': 'application/cbor'},
    );
    await expectLater(
      app.transport.send(_list),
      throwsA(isA<CrateStackOffline>()),
    );
  });

  test('a captive portal is Offline', () async {
    final server = FakeCoseServer();
    final app = await _app(server);
    server.override = (_) => http.Response(
      '<html>sign in to the wifi</html>',
      200,
      headers: {'content-type': 'text/html'},
    );
    await expectLater(
      app.transport.send(_list),
      throwsA(isA<CrateStackOffline>()),
    );
  });

  test('each refusal is classified by its status', () async {
    final server = FakeCoseServer();
    final app = await _app(server);
    Future<void> answers(int status, Matcher matcher) async {
      server.override = (_) => http.Response.bytes(
        encodePayload({'code': 'X', 'message': 'no'}),
        status,
        headers: {'content-type': 'application/cbor'},
      );
      await expectLater(app.transport.send(_list), throwsA(matcher));
    }

    // The layer's refusals from before the handler: believed by status, the body ignored.
    for (final status in [400, 413, 415, 426]) {
      await answers(
        status,
        isA<CrateStackRefused>()
            .having((e) => e.status, 'status', status)
            .having((e) => e.code, 'code', 'HTTP_$status'),
      );
    }
    await answers(401, isA<CrateStackUnauthenticated>());
    // Anything else unsigned is not the server's word: the intent keeps its key. A 500 after the
    // handler ran (the layer could not seal), a 409, a 422 with a forged code, a gateway's 503.
    for (final status in [409, 422, 500, 503]) {
      await answers(status, isA<CrateStackOffline>());
    }
  });

  test(
    'a sealed refusal of a registered device is a refusal, not a 401',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server);
      server.override = (request) => server.sealed(request, 422, {
        'code': 'VALIDATION_ERROR',
        'message': 'text is required',
      });
      await expectLater(
        app.transport.send(_add, idempotencyKey: 'a#0'),
        throwsA(
          isA<CrateStackRefused>()
              .having((e) => e.status, 'status', 422)
              .having((e) => e.code, 'code', 'VALIDATION_ERROR'),
        ),
      );
    },
  );

  test('registration is plain CBOR, once, and a failure is retried', () async {
    final server = FakeCoseServer();
    var failures = 1;
    final signer = FakeDpopSigner();
    final sealer = CoseSealer(signer);
    late final CoseTransport transport;
    final registrar = DeviceRegistrar(
      signer: signer,
      identity: await sealer.identity(),
      send: (call) async {
        if (failures-- > 0) throw const CrateStackOffline('down');
        return transport.send(call);
      },
    );
    transport = CoseTransport(
      config: await server.config(),
      sealer: sealer,
      client: server.client,
    );
    await expectLater(registrar.ensure(), throwsA(isA<CrateStackOffline>()));
    expect(registrar.isRegistered, isFalse);
    await Future.wait([registrar.ensure(), registrar.ensure()]);
    await registrar.ensure();
    expect(server.registrations, 1);
  });

  test(
    'a registration the server answers for another key is refused',
    () async {
      final signer = FakeDpopSigner();
      final sealer = CoseSealer(signer);
      final registrar = DeviceRegistrar(
        signer: signer,
        identity: await sealer.identity(),
        send: (call) async => {'kid': '00', 'thumbprint': 'ff'},
      );
      await expectLater(registrar.ensure(), throwsA(isA<CrateStackOffline>()));
    },
  );

  test('beforeSigned runs before each signed call and can stop it', () async {
    final server = FakeCoseServer();
    var runs = 0;
    final app = await _app(
      server,
      beforeSigned: () async {
        runs++;
        if (runs == 1) throw const CrateStackOffline('not yet');
      },
    );
    await app.registrar.ensure();
    await expectLater(
      app.transport.send(_list),
      throwsA(isA<CrateStackOffline>()),
    );
    expect(server.seen, isEmpty);
    await app.transport.send(_list);
    expect(runs, 2);
  });

  test(
    'an op outside the contract, and a REST call, are refused before anything is sealed',
    () async {
      final server = FakeCoseServer();
      final app = await _app(server);
      expect(
        () => app.transport.send(const RpcCall('procedure.nope', {})),
        throwsArgumentError,
      );
      expect(
        () => app.transport.send(const RestCall('GET', '/notes')),
        throwsUnsupportedError,
      );
    },
  );

  group('the payload codec', () {
    test('round-trips what the server reads and writes', () {
      final value = {
        'args': {
          'text': 'héllo',
          'n': -5,
          'big': 70000,
          'flag': true,
          'none': null,
        },
        'list': [1, 'two', 3.5],
      };
      expect(decodePayload(encodePayload(value)), value);
    });

    test('is deterministic, and shortest-form', () {
      expect(
        encodePayload({'a': 1}),
        Uint8List.fromList([0xa1, 0x61, 0x61, 0x01]),
      );
      expect(encodePayload(const <String, Object?>{}), [0xa0]);
    });

    test('reads indefinite lengths and half floats a server may send', () {
      expect(decodePayload([0x9f, 0x01, 0x02, 0xff]), [1, 2]);
      expect(decodePayload([0xf9, 0x3c, 0x00]), 1.0);
      expect(
        () => decodePayload([0xa1, 0x01, 0x02]),
        throwsA(isA<PayloadFormatException>()),
      );
      expect(
        () => decodePayload([0x82, 0x01]),
        throwsA(isA<PayloadFormatException>()),
      );
    });
  });
}
