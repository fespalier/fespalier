// What goes on the wire: a signature and an attestation on every API call, never an Authorization
// header, and nothing in the store that works without the key.
import 'package:device/api.dart';
import 'package:device/demo/demo_api.dart';
import 'package:device/device_setup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('every request verifies, and none carries an Authorization', (
    tester,
  ) async {
    final server = DemoApi();
    final store = MemoryTokenStore();
    final container = await enrol(
      tester,
      server,
      FakeDevice(),
      initialLocation: '/account',
      store: store,
    );
    // More calls: a read, a write that asks for the user-present key, and the page's own.
    final transport = container.read(authTransport);
    await callApi(transport, 'GET', '/me');
    await tester.tap(find.text('Send money'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm and send'));
    await tester.pumpAndSettle();
    expect(find.text('Transfer 1 sent to Ada'), findsOneWidget);

    expect(server.served, isNotEmpty);
    for (final request in server.served) {
      expect(
        request.headers,
        isNot(contains('authorization')),
        reason: '$request',
      );
    }
    // The ceremony's legs are unsigned by name; every API call is signed, and the server verified
    // it (the issuer's signature, cnf.jkt, the request's claims, a jti that was not used before).
    final signed = server.served.where((r) => r.signed).toList();
    expect(signed.map((r) => '$r'), ['GET /me', 'GET /me', 'POST /transfers']);
    for (final request in signed) {
      expect(request.attestation, isNotEmpty, reason: '$request');
      expect(request.refusedWith, isNull, reason: '$request');
      expect(request.deviceId, 'device-1', reason: '$request');
    }
    expect(server.served.where((r) => !r.signed).map((r) => '$r'), [
      'POST /device/enrolments',
      'POST /device/enrolments/enrolment-1/confirm',
    ]);
    // A signature is good once: a fresh jti for each of the three.
    expect(server.seenJtis, hasLength(3));
  });

  testWidgets('what is stored is a device id and attestations, not a token', (
    tester,
  ) async {
    final store = MemoryTokenStore();
    await enrol(tester, DemoApi(), FakeDevice(), store: store);
    final stored = store.value!;
    expect(stored, allOf(contains('deviceId'), contains('attestations')));
    expect(holdsAToken(stored), isFalse, reason: stored);
  });

  testWidgets('a signature fits one request, once', (tester) async {
    final server = DemoApi();
    final container = await enrol(tester, server, FakeDevice());
    final credential =
        container.read(authSession.notifier).session!.credential
            as DeviceCredential;
    final headers = await container
        .read(deviceBackend)
        .signer
        .signFor(credential, TransportRequest(method: 'GET', uri: api('/me')));
    Future<int> replay(String method, String path) async {
      final response = await server.transport.send(
        TransportRequest(method: method, uri: api(path), headers: headers),
      );
      return response.statusCode;
    }

    // Made for GET /me: refused as another method, as another route...
    expect(await replay('DELETE', '/devices/device-1'), 401);
    expect(server.served.last.refusedWith, 'mismatch');
    expect(await replay('GET', '/transfers'), 404);
    // ...good once for what it was made for, and not twice.
    expect(await replay('GET', '/me'), 200);
    expect(await replay('GET', '/me'), 401);
    expect(server.served.last.refusedWith, 'replay');
  });
}
