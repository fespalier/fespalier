// Renewal replaces refresh: a silent proof of possession, lazy, single-flight and with no timer.
// The attestations live a day against the fake clock; the backend renews one within twelve hours
// of its end.
import 'package:device/api.dart';
import 'package:device/demo/demo_api.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('an attestation near its end is renewed once, by two requests', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice();
    final container = await enrol(tester, server, device);
    final first = await _attestationOf(container.read(authSession.notifier));
    final prompts = device.prompts;

    // Nothing renews it in the background.
    await tester.pump(const Duration(hours: 13));
    expect(server.renewals, 0);

    // Two requests together share one renewal, signed by the ambient key.
    final transport = container.read(authTransport);
    await Future.wait([
      callApi(transport, 'GET', '/me'),
      callApi(transport, 'GET', '/me'),
    ]);
    expect(server.renewals, 1);
    expect(device.prompts, prompts, reason: 'renewing never asks the user');
    final signed = server.served.where((r) => r.signed).toList();
    expect(signed, hasLength(2));
    expect(signed.map((r) => r.attestation).toSet(), hasLength(1));
    expect(signed.first.attestation, isNot(first), reason: 'the new one');
    expect(signed.every((r) => r.refusedWith == null), isTrue);

    // Fresh again: a later request renews nothing.
    await callApi(transport, 'GET', '/me');
    expect(server.renewals, 1);
  });

  testWidgets('an attestation that expired is renewed before the request', (
    tester,
  ) async {
    final server = DemoApi();
    final container = await enrol(tester, server, FakeDevice());
    await tester.pump(const Duration(hours: 25));
    await callApi(container.read(authTransport), 'GET', '/me');
    expect(server.renewals, 1);
    // The request that was sent was signed with the new attestation: the old one would have been
    // refused as attestation_expired.
    expect(server.served.where((r) => r.refusedWith != null), isEmpty);
  });

  testWidgets('a device the server forgot ends the session as revoked', (
    tester,
  ) async {
    final server = DemoApi();
    final container = await enrol(tester, server, FakeDevice());
    // The attestation has not expired for the app, but the server lost the device.
    server.forgetDevice('device-1');
    final transport = container.read(authTransport);
    await expectLater(callApi(transport, 'GET', '/me'), throwsA(anything));
    // 401 device_not_active asks for a renewal, and the server answers 403 (the device is dead):
    // the session is over, as revoked.
    expect(server.renewals, 0);
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.revoked),
    );
  });
}

Future<String> _attestationOf(AuthSessionNotifier notifier) async {
  // The ambient attestation the credential holds, as the JWS the next request sends.
  final session = notifier.session!;
  final json = session.credential.toJson();
  return (json['attestations']! as Map<String, Object?>)['ambient']! as String;
}
