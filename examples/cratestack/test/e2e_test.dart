// The app's Dart signatures against the real Rust server (examples/cratestack/server), as a process:
// the cross-language check of the scheme. `DeviceSigner` signs with fake (deterministic) keys, and
// the server's own verifier (src/verify.rs, written from the profile and not from Dart's code) has to
// accept every request, refuse every tampered one, and agree with `webankRefusals` on what a refusal
// means.
//
//   cd examples/cratestack/server && cargo build --locked
//   cd .. && ORDERS_SERVER_BIN=server/target/debug/orders-demo-server flutter test test/e2e_test.dart
//
// Without ORDERS_SERVER_BIN the file skips, saying why; with FSP_REQUIRE_ORDERS_SERVER=1 (CI's
// `cratestack` job) a missing binary fails instead, so a run cannot pass by skipping. These are plain
// `test`s: they use real sockets, which a widget test's fake async would freeze.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cbor/simple.dart' as cbor;
import 'package:clock/clock.dart';
import 'package:cratestack_example/src/config.dart';
import 'package:cratestack_example/src/errors.dart';
import 'package:cratestack_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart' show FieldErrors, ProviderContainer;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart' show KeyRole;
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orders_client/orders_client.dart';

/// The CBOR body of an RPC call: what the generated client would send.
Uint8List encodeBody(Object? args) =>
    Uint8List.fromList(cbor.cbor.encode(args));

/// One send that reached the wire: what it carried, and the status it got.
typedef _Sent = ({
  TransportRequest request,
  int status,
  Map<String, String> headers,
});

/// The bottom of the app's chain, recording each send: what the server saw, under the session.
class _Recording implements HttpTransport {
  _Recording(this.inner);

  final HttpTransport inner;
  final List<_Sent> sent = [];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final response = await inner.send(request);
    sent.add((
      request: request,
      status: response.statusCode,
      headers: response.headers,
    ));
    return response;
  }
}

/// A running `orders-demo-server`, from the one JSON line it prints.
class _Server {
  _Server(this.process, this.config);

  final Process process;
  final OrdersConfig config;

  static Future<_Server> start(
    String binary, {
    int? ttlSeconds,
    int port = 0,
    String? issuerScalarHex,
  }) async {
    final process = await Process.start(binary, [
      '--listen',
      '127.0.0.1:$port',
      if (ttlSeconds != null) ...['--attestation-ttl-secs', '$ttlSeconds'],
      if (issuerScalarHex != null) ...['--issuer-scalar-hex', issuerScalarHex],
    ]);
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
        OrdersConfig(
          server: Uri.parse('http://${hello['addr']}'),
          audience: hello['audience']! as String,
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

/// The app, on real sockets: the production chain, the session, the generated client.
class _App {
  _App(
    this.server,
    this.ambient,
    this.presence,
    this.container,
    this.client,
    this.wire,
  );

  final _Server server;
  final FakeKeypairSigner ambient;
  final FakeKeypairSigner? presence;
  final ProviderContainer container;
  final http.Client client;

  /// Every send that left the app, in order.
  final _Recording wire;

  /// The sends of [op].
  List<_Sent> sentTo(String op) => [
    for (final s in wire.sent)
      if (s.request.uri.path == '/rpc/procedure.$op') s,
  ];

  static Future<_App> start(
    _Server server, {
    String seed = 'e2e',
    Duration renewAhead = const Duration(hours: 12),
    bool userPresent = true,
  }) async {
    final ambient = FakeKeypairSigner(keyId: 'ambient', seed: '$seed ambient');
    final presence = userPresent
        ? FakeKeypairSigner(
            keyId: 'user_present',
            role: KeyRole.userPresent,
            seed: '$seed user present',
          )
        : null;
    final client = http.Client();
    final wire = _Recording(HttpClientTransport(client));
    final network = PortalTransport(WriteGuardTransport(wire));
    final container = ProviderContainer(
      overrides: [
        ...await restoreAuth(
          authSetup(
            network,
            server.config,
            keys: DeviceKeys(ambient: ambient, userPresent: presence),
            store: MemoryTokenStore(),
            renewAhead: renewAhead,
          ),
        ),
        ...ordersOverrides(server.config),
      ],
    );
    return _App(server, ambient, presence, container, client, wire);
  }

  ProceduresApi get api => container.read(ordersClientProceduresApiProvider);

  DeviceAuthBackend get backend => container.read(deviceBackend);

  AuthSession get session => container.read(authSession.notifier).session!;

  DeviceCredential get credential => session.credential as DeviceCredential;

  /// Enrolls by the two public legs, as the enrolment page does.
  Future<void> enrol({String phone = '+237 6 55 00 00 00'}) async {
    final challenge = await backend.beginEnrolment(fields: {'phone': phone});
    await container
        .read(authSession.notifier)
        .signIn(CompleteEnrolment(challenge, proof: '123456'));
  }

  /// `listOrders`, through the generated client and the session.
  Future<List<Order>> orders() async => (await api.listOrders(
    ListOrdersProcedureArgs(args: ListOrdersArgs()),
  )).orders.toList();

  /// A request signed by hand, to be sent as it is, as often as the test likes.
  Future<TransportRequest> signed(
    String op,
    Object? args, {
    KeyRole role = KeyRole.ambient,
  }) async {
    final body = encodeBody(args);
    final request = TransportRequest(
      method: 'POST',
      uri: server.config.server.resolve('/rpc/procedure.$op'),
      headers: const {
        'content-type': 'application/cbor',
        'accept': 'application/cbor',
      },
      body: body,
    );
    final headers = await backend.signer.signFor(
      credential,
      request,
      role: role,
    );
    return request.copyWith(headers: {...request.headers, ...headers});
  }

  /// Sends [request] over the plain chain: no session, so nothing signs it again.
  Future<(int, Map<String, Object?>)> send(TransportRequest request) async {
    final response = await HttpClientTransport(client).send(request);
    final bytes = await response.bytes();
    final type = response.headers['content-type'] ?? '';
    final body = type.contains('json')
        ? jsonDecode(utf8.decode(bytes))
        : cbor.cbor.decode(bytes);
    return (response.statusCode, Map<String, Object?>.from(body as Map));
  }

  Future<void> close() async {
    container.dispose();
    client.close();
  }
}

void main() {
  final binary = Platform.environment['ORDERS_SERVER_BIN'];
  final required = Platform.environment['FSP_REQUIRE_ORDERS_SERVER'] == '1';
  final missing = binary == null || binary.isEmpty;
  if (missing) {
    test(
      'the app against the real server',
      () {
        if (required) {
          fail(
            'FSP_REQUIRE_ORDERS_SERVER=1 but ORDERS_SERVER_BIN is not set: build '
            'examples/cratestack/server and point ORDERS_SERVER_BIN at orders-demo-server',
          );
        }
      },
      skip: required
          ? null
          : 'ORDERS_SERVER_BIN is not set (cd examples/cratestack/server && cargo build --locked, '
                'then ORDERS_SERVER_BIN=server/target/debug/orders-demo-server)',
    );
    return;
  }

  late _Server server;
  late _App app;
  setUp(() async {
    server = await _Server.start(binary);
    app = await _App.start(server);
  });
  tearDown(() async {
    await app.close();
    await server.stop();
  });

  test('enrols, and the server accepts every signature Dart makes', () async {
    await app.enrol();
    expect(app.container.read(authSession), isA<SignedIn>());
    expect(app.container.read(authUser)?.name, '+237655000000');
    final listed = await app.orders();
    expect(
      [for (final o in listed) '${o.quantity} x ${o.item}'],
      ['2 x Espresso beans', '6 x Oat milk'],
    );
    final account = await app.api.account(AccountArgs(args: NoArgs()));
    expect(account.signedWith, 'ambient');
    expect(account.phone, '+237655000000');
    expect(account.deviceId, app.credential.deviceId);
    // Many signatures, many random nonces: none is refused (a high-S signature included).
    for (var i = 0; i < 25; i++) {
      await app.orders();
    }
  });

  test(
    'a wrong phone or code is a validation answer, read as FieldErrors',
    () async {
      await expectLater(
        app.backend.beginEnrolment(fields: {'phone': 'hello'}),
        throwsA(
          isA<FieldErrors>().having((e) => e.fields.keys, 'fields', ['phone']),
        ),
      );
      final challenge = await app.backend.beginEnrolment(
        fields: {'phone': '+237 6 55 00 00 00'},
      );
      await expectLater(
        app.container
            .read(authSession.notifier)
            .signIn(CompleteEnrolment(challenge, proof: '000000')),
        throwsA(
          isA<FieldErrors>().having((e) => e.fields.keys, 'fields', ['otp']),
        ),
      );
      expect(app.container.read(authSession), isA<SignedOut>());
    },
  );

  test(
    'a write under an Idempotency-Key runs once, however often it is sent',
    () async {
      await app.enrol();
      const key = 'e2e-key-1';
      Future<Order> place(int quantity) => app.api.placeOrder(
        PlaceOrderProcedureArgs(
          args: PlaceOrderArgs(item: 'Tea', quantity: quantity),
        ),
        options: const CratestackRpcCallOptions(idempotencyKey: key),
      );
      final first = await place(3);
      final again = await place(3);
      expect(
        again,
        first,
        reason: 'the stored answer, replayed under a new signature',
      );
      expect((await app.orders()).length, 3);
      // The same key with another body is the caller's bug: 422, not a field error.
      await expectLater(
        place(4),
        throwsA(
          isA<CratestackRpcException>()
              .having((e) => e.status, 'status', 422)
              .having(
                (e) => e.message,
                'message',
                startsWith('idempotency_key_conflict'),
              ),
        ),
      );
    },
  );

  test('the server\'s validation answer is a field error', () async {
    await app.enrol();
    final bad = app.api.placeOrder(
      PlaceOrderProcedureArgs(args: PlaceOrderArgs(item: 'Tea', quantity: 100)),
    );
    await expectLater(
      bad,
      throwsA(
        isA<CratestackRpcException>()
            .having((e) => e.status, 'status', 422)
            .having((e) => e.code, 'code', 'invalid_argument'),
      ),
    );
    try {
      await bad;
    } on CratestackRpcException catch (error) {
      expect(ordersErrors.fieldErrorsOf(error)?.fields.keys, ['quantity']);
    }
  });

  group('step-up: payOrder declares @authn(amr: ["user"])', () {
    Future<Order> pay({String key = 'pay-1'}) => app.api.payOrder(
      PayOrderProcedureArgs(args: PayOrderArgs(id: 1)),
      options: CratestackRpcCallOptions(idempotencyKey: key),
    );

    String? attestationOf(_Sent sent) => {
      for (final e in sent.request.headers.entries)
        e.key.toLowerCase(): e.value,
    }['x-attestation'];

    test(
      'the ambient key gets the step-up refusal; one user-present signature and one retry complete it',
      () async {
        await app.enrol();
        final prompts = app.presence!.prompts;
        final paid = await pay();
        expect(paid.status, 'paid');
        expect(app.presence!.prompts, prompts + 1, reason: 'one prompt');
        expect(app.presence!.lastReason, 'Confirm it is you');
        final sends = app.sentTo('payOrder');
        expect([for (final s in sends) s.status], [401, 200]);
        // The real server's refusal, on an RPC unary response: the challenge is on it.
        final challenge = sends[0].headers['www-authenticate'] ?? '';
        expect(challenge, startsWith('Bearer '));
        expect(challenge, contains('error="insufficient_user_authentication"'));
        expect(
          attestationOf(sends[0]),
          app.credential.attestation(KeyRole.ambient)!.jws,
        );
        expect(
          attestationOf(sends[1]),
          app.credential.attestation(KeyRole.userPresent)!.jws,
        );
        expect(sends[1].request.body, sends[0].request.body);
        expect(
          sends[1].request.headers['Idempotency-Key'] ??
              sends[1].request.headers['idempotency-key'],
          'pay-1',
          reason: 'the same request, under the same key',
        );
        // The step-up refusal was not kept under the key: a retry of it replays the payment.
        final again = await pay();
        expect(again.status, 'paid');
        expect(app.sentTo('payOrder').last.status, 200);
        expect(app.container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'a refused prompt surfaces the 401, and the session is kept',
      () async {
        await app.enrol();
        app.presence!.refuseNextPrompt();
        await expectLater(
          pay(),
          throwsA(
            isA<CratestackRpcException>()
                .having((e) => e.status, 'status', 401)
                .having((e) => e.code, 'code', 'unauthenticated')
                .having((e) => e.stepUp?.amr, 'stepUp.amr', ['user'])
                .having((e) => e.stepUp?.unmet, 'stepUp.unmet', ['amr']),
          ),
        );
        expect(app.sentTo('payOrder'), hasLength(1));
        expect(app.container.read(authSession), isA<SignedIn>());
        final order = await app.api.getOrder(
          GetOrderProcedureArgs(args: GetOrderArgs(id: 1)),
        );
        expect(order.status, 'placed', reason: 'nothing was paid');
        // The user tries again, and confirms.
        expect((await pay(key: 'pay-2')).status, 'paid');
      },
    );

    test('background work never prompts: the refusal is the answer', () async {
      await app.enrol();
      final prompts = app.presence!.prompts;
      await expectLater(
        Authorizer.unattended(pay),
        throwsA(
          isA<CratestackRpcException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.stepUp, 'stepUp', isNotNull),
        ),
      );
      expect(app.presence!.prompts, prompts, reason: 'nobody was asked');
      expect(app.sentTo('payOrder'), hasLength(1));
      expect(app.container.read(authSession), isA<SignedIn>());
    });

    test(
      'a request already signed with the user-present key is accepted at once',
      () async {
        await app.enrol();
        final request = await app.signed('payOrder', {
          'args': {'id': 1},
        }, role: KeyRole.userPresent);
        final (status, body) = await app.send(request);
        expect(status, 200);
        expect(body['status'], 'paid');
        final account = await app.send(
          await app.signed('account', {
            'args': <String, Object?>{},
          }, role: KeyRole.userPresent),
        );
        expect(account.$2['signedWith'], 'userPresent');
      },
    );
  });

  test(
    'a replayed, tampered or foreign request is refused with the code the client reads',
    () async {
      await app.enrol();
      final request = await app.signed('listOrders', {
        'args': <String, Object?>{},
      });
      expect((await app.send(request)).$1, 200);
      final replay = await app.send(request);
      expect(replay.$1, 401);
      expect(replay.$2['error'], 'replay');

      // Signed for one body, sent with another.
      final signed = await app.signed('placeOrder', {
        'args': {'item': 'Tea', 'quantity': 1},
      });
      final tampered = TransportRequest(
        method: signed.method,
        uri: signed.uri,
        headers: signed.headers,
        body: encodeBody({
          'args': {'item': 'Tea', 'quantity': 99},
        }),
      );
      final mismatch = await app.send(tampered);
      expect(mismatch.$1, 401);
      expect(mismatch.$2['error'], 'mismatch');

      // Signed for one procedure, sent to another.
      final pay = await app.signed('getOrder', {
        'args': {'id': 1},
      });
      final elsewhere = await app.send(
        pay.copyWith(uri: pay.uri.replace(path: '/rpc/procedure.payOrder')),
      );
      expect(elsewhere.$2['error'], 'mismatch');

      // No credential at all, and an Authorization header is not one.
      final plain = TransportRequest(
        method: 'POST',
        uri: signed.uri.replace(path: '/rpc/procedure.listOrders'),
        headers: const {
          'content-type': 'application/cbor',
          'authorization': 'Bearer anything',
        },
        body: encodeBody({'args': <String, Object?>{}}),
      );
      final unsigned = await app.send(plain);
      expect(unsigned.$1, 401);
      expect(unsigned.$2['error'], 'missing_credential');
    },
  );

  test(
    'sign-out revokes the device: a request signed before it is then a 403 DEVICE_REVOKED',
    () async {
      await app.enrol();
      final before = await app.signed('listOrders', {
        'args': <String, Object?>{},
      });
      final prompts = app.presence!.prompts;

      await app.container.read(authSession.notifier).signOut();
      expect(
        app.presence!.prompts,
        prompts + 1,
        reason: 'revoking asks the user',
      );
      expect(
        app.container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(app.ambient.deletes, 1);

      final refused = await app.send(before);
      expect(refused.$1, 403);
      expect(refused.$2['error'], 'DEVICE_REVOKED');
    },
  );

  test(
    'sign-out without a user-present key is revoked by the ambient key',
    () async {
      await app.close();
      app = await _App.start(server, seed: 'web', userPresent: false);
      await app.enrol();
      final before = await app.signed('account', {'args': <String, Object?>{}});
      await app.container.read(authSession.notifier).signOut();
      expect((await app.send(before)).$2['error'], 'DEVICE_REVOKED');
    },
  );

  test('an attestation near its end is renewed before the call', () async {
    await server.stop();
    server = await _Server.start(binary, ttlSeconds: 8);
    await app.close();
    app = await _App.start(server, renewAhead: const Duration(seconds: 5));
    await app.enrol();
    final first = app.credential.attestation(KeyRole.ambient)!.jws;
    // An attestation is dated to the second and signed deterministically: one issued in the same
    // second would be the same text.
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    // The phone's clock reads four seconds on: the attestation has four of its eight seconds left,
    // inside the five of renewAhead. (The server allows a clock thirty seconds off.)
    final later = Clock(() => DateTime.now().add(const Duration(seconds: 4)));
    await withClock(later, () async {
      expect(await app.orders(), hasLength(2));
    });
    final renewed = app.credential.attestation(KeyRole.ambient)!.jws;
    expect(renewed, isNot(first));
    // And it is good: a call with no help from the clock.
    expect(await app.orders(), hasLength(2));
  });

  test(
    'a 401 attestation_expired from the real server renews and sends the call once more',
    () async {
      await server.stop();
      server = await _Server.start(binary, ttlSeconds: 3);
      await app.close();
      app = await _App.start(server, renewAhead: Duration.zero);
      await app.enrol();
      final first = app.credential.attestation(KeyRole.ambient)!.jws;

      // The phone's clock is five seconds behind the server's, so after four real seconds it still
      // holds the attestation good, and the server, whose three seconds are over, says it is not.
      await Future<void>.delayed(const Duration(seconds: 4));
      final behind = Clock(
        () => DateTime.now().subtract(const Duration(seconds: 5)),
      );
      await withClock(behind, () async {
        expect(await app.orders(), hasLength(2));
      });
      expect(app.credential.attestation(KeyRole.ambient)!.jws, isNot(first));
    },
  );

  test(
    'a server that restarted and forgot the device ends the session as revoked',
    () async {
      await server.stop();
      await app.close();
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      // The same issuer key, so the attestation still reads: only the device is gone.
      final issuer = '42' * 32;
      server = await _Server.start(binary, port: port, issuerScalarHex: issuer);
      app = await _App.start(server);
      await app.enrol();
      await server.stop();
      server = await _Server.start(binary, port: port, issuerScalarHex: issuer);

      // 401 device_not_active asks for a renewal, and the server answers 403 for a device it never
      // saw: the session is over.
      await expectLater(app.orders(), throwsA(anything));
      expect(
        app.container.read(authSession),
        const SignedOut(reason: SignOutReason.revoked),
      );
    },
  );
}
