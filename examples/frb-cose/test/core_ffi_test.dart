// The real Rust core, in every `flutter test`: the hook builds it, the bindings load, the Dart signer is called from
// Rust, and the sealed request leaves with its headers. The server is a stub (support/fakes.dart), so this file checks
// the core's side of the wire only; the real server's checks are in the Rust tests and the end-to-end test.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/src/rust/api/core.dart';

import 'support/fakes.dart';
import 'support/host_core.dart';

// The NIST P-256 generator point: a point on the curve, which the core takes as the device's key and as the
// server's pinned key. No test here checks a signature, so any point on the curve will do.
final _gx = _hex(
  '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
);
final _gy = _hex(
  '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
);

const _registered = CoreEvent(kind: CoreEventKind.registered, op: '');

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

Future<NotesCore> _open(StubServer stub, CountingSigner signer) =>
    NotesCore.open(
      config: CoreConfig(
        baseUrl: stub.baseUrl,
        audience: 'fespalier-frb-cose',
        deviceX: _gx,
        deviceY: _gy,
        serverX: _gx,
        serverY: _gy,
      ),
      sign: signer.sign,
    );

Future<StubServer> _stub() {
  final identity = deviceIdentity(deviceX: _gx, deviceY: _gy);
  return StubServer.start(kid: identity.kid, thumbprint: identity.thumbprint);
}

void main() {
  setUpAll(initHostCore);

  test('the core computes the key id and the thumbprint of a device key', () {
    final identity = deviceIdentity(deviceX: _gx, deviceY: _gy);
    expect(identity.kid, matches(RegExp(r'^[0-9a-f]+$')));
    expect(identity.thumbprint, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test(
    'a call registers the key, sends the sealed request, and an unsigned 503 is Unsigned',
    () async {
      final stub = await _stub();
      addTearDown(stub.close);
      final signer = CountingSigner();
      final core = await _open(stub, signer);

      expect(core.status().registered, isFalse);
      final events = core.changes().take(2).toList();
      final error = await core
          .call(op: 'addNote', argsJson: '{"text":"hi"}', idempotencyKey: 'k#0')
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<CoreError>());
      final failure = error! as CoreError;
      expect(failure.kind, CoreErrorKind.unsigned);
      expect(failure.status, 503);
      expect(
        failure,
        isA<Exception>(),
        reason: 'a struct error is a Dart exception',
      );

      expect(
        signer.calls,
        1,
        reason:
            'the Dart callback ran once, from Rust, for the one sealed call',
      );
      expect(core.status().registered, isTrue);

      final register = stub.to(StubServer.registerPath).single;
      expect(
        register.contentType,
        isNot(contains('cose')),
        reason: 'registration is the plain op',
      );
      final sealed = stub.to('/rpc/procedure.addNote').single;
      expect(sealed.contentType, 'application/cose; cose-type="cose-sign1"');
      expect(
        sealed.contract,
        isNotNull,
        reason: 'Cratestack-Contract names the op contract',
      );
      expect(sealed.idempotencyKey, 'k#0');
      expect(sealed.bodyLength, greaterThan(0));

      expect(await events, [
        _registered,
        const CoreEvent(kind: CoreEventKind.called, op: 'addNote'),
      ]);
    },
  );

  test('the key is registered once, however many calls follow', () async {
    final stub = await _stub();
    addTearDown(stub.close);
    final core = await _open(stub, CountingSigner());

    for (final key in ['k#0', 'k#1']) {
      await core
          .call(op: 'addNote', argsJson: '{"text":"hi"}', idempotencyKey: key)
          .then<Object?>((_) => null, onError: (Object _) => null);
    }

    expect(stub.to(StubServer.registerPath), hasLength(1));
    expect(stub.to('/rpc/procedure.addNote'), hasLength(2));
  });

  test('a signer that does not sign sends no sealed request', () async {
    final stub = await _stub();
    addTearDown(stub.close);
    final signer = CountingSigner(signs: false);
    final core = await _open(stub, signer);

    final error = await core
        .call(op: 'addNote', argsJson: '{"text":"hi"}', idempotencyKey: 'k#0')
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect((error! as CoreError).kind, CoreErrorKind.seal);
    expect(signer.calls, 1);
    expect(
      stub.to('/rpc/procedure.addNote'),
      isEmpty,
      reason: 'nothing was sent',
    );
  });

  test('an unknown op is refused before anything is sent', () async {
    final stub = await _stub();
    addTearDown(stub.close);
    final signer = CountingSigner();
    final core = await _open(stub, signer);

    final error = await core
        .call(op: 'noSuchOp', argsJson: '{}', idempotencyKey: 'k#0')
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect((error! as CoreError).kind, CoreErrorKind.badInput);
    expect(stub.requests, isEmpty);
    expect(signer.calls, 0);
  });

  test(
    'a point that is not on the curve is refused when the core opens',
    () async {
      final stub = await _stub();
      addTearDown(stub.close);
      final error = await NotesCore.open(
        config: CoreConfig(
          baseUrl: stub.baseUrl,
          audience: 'fespalier-frb-cose',
          deviceX: _gx,
          deviceY: _gy,
          serverX: _gx,
          serverY: Uint8List(32),
        ),
        sign: CountingSigner().sign,
      ).then<Object?>((_) => null, onError: (Object e) => e);

      expect((error! as CoreError).kind, CoreErrorKind.badInput);
    },
  );
}
