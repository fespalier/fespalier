import 'dart:convert';

import 'package:cose_example/src/contracts.g.dart';
import 'package:cose_example/src/cose/cose.dart';
import 'package:cose_example/src/cose_transport.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the shape of the graph `startup()` builds, and the one thing that must stay lazy in it.
///
/// **What this is for.** The app once failed on every platform with
/// `CircularDependencyError: Circular dependency detected`, thrown while registering the device key,
/// before any request was made. The cycle was:
///
///     coseTransport --(beforeSigned)--> deviceRegistrar --(watch)--> crateStackTransport
///                   <--(override watches)----------------------------------------
///
/// Every symptom pointed elsewhere (a wrong key, cleartext HTTP, `10.0.2.2`, the emulator's
/// routing) and none of it was the cause: the failure happened before the HTTP client was reached,
/// so no packet ever left the device. The fix is that `deviceRegistrar` resolves its transport
/// lazily, inside the send callback, so building it does not touch `crateStackTransport`.
///
/// **What this does and does not catch.** It fails if the graph is broken in a way that surfaces
/// when the providers are built in a container. It does **not** reproduce the original cycle: that
/// was verified on a device, and reintroducing the cycle here still passes. Do not read a green run
/// as "the wiring is correct" — read it as "the providers still build". The device check is the one
/// that caught it, and it is in the README's run steps.
void main() {
  test('the real wiring builds', () async {
    final signer = FakeDpopSigner();
    final identity = await CoseSealer(signer).identity();

    final container = ProviderContainer(
      overrides: [
        coseConfig.overrideWithValue(
          CoseConfig.fromJwk(
            baseUrl: Uri.parse('http://127.0.0.1:1'),
            audience: coseAudience,
            // A well-formed JWK: the key is never used, since no request is sent.
            jwk: jsonEncode({
              'kty': 'EC',
              'crv': 'P-256',
              'x': 'E8LKhUtw1gs762xvmGhaHruBfljGLN4bg4HLvJM7Q20',
              'y': 'T8bXmosAVJTNYMcoN2nNsbSmkJzJWvbJODPuKxRD8a4',
            }),
          ),
        ),
        deviceSigner.overrideWithValue(signer),
        deviceIdentity.overrideWithValue(identity),
        // What `startup()` returns: the real seams, including `crateStackTransport` = the transport.
        ...coseOverrides(),
      ],
    );
    addTearDown(container.dispose);

    // Building the transport is what used to throw. `beforeSigned` is a closure: it must not run
    // here, so no request is made and nothing waits on the network.
    expect(
      () => container.read(crateStackTransport),
      returnsNormally,
      reason: 'the transport must build',
    );
    expect(
      () => container.read(deviceRegistrar),
      returnsNormally,
      reason: 'the registrar must build without watching the transport',
    );
  });
}
