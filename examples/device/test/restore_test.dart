// Restoring reads the stored attestation, with no network, and asks the backend whether the device
// key is still the one it is bound to: a key that was swapped or wiped is a SignedOut(keyLost).
import 'package:device/app.g.dart';
import 'package:device/demo/demo_api.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('the next start is signed in, with no request', (tester) async {
    final server = DemoApi();
    final device = FakeDevice();
    final store = MemoryTokenStore();
    await enrol(tester, server, device, store: store);
    server.served.clear();
    await closeApp(tester);

    // A new start: the same keys, the same store.
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/account'),
      overrides: await deviceOverrides(server, device, store: store),
    );
    expect(container.read(authSession), isA<SignedIn>());
    expect(currentLocation(tester), '/account');
    // The restore asked the store and the keys, and nobody else; the page loaded its own data.
    expect(server.served.map((r) => '$r'), ['GET /me']);
  });

  testWidgets('a swapped key is SignedOut(keyLost), and the app says so', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice();
    final store = MemoryTokenStore();
    await enrol(tester, server, device, store: store);
    server.served.clear();
    await closeApp(tester);

    // The keystore was wiped behind the app's back: the next use makes another key.
    await device.ambient.loseKey();
    final router = AppRoutes.router(initialLocation: '/account');
    final container = await pumpRouter(
      tester,
      router,
      overrides: await deviceOverrides(server, device, store: store),
    );
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.keyLost),
    );
    expect(
      server.served,
      isEmpty,
      reason: 'nothing was signed with another key',
    );
    expect(currentLocation(tester), '/enrol?from=%2Faccount');
    expect(store.value, isNull, reason: 'the stored session was forgotten');

    router.go('/');
    await tester.pumpAndSettle();
    expect(
      find.text("This device's key changed. Enrol again."),
      findsOneWidget,
    );
  });

  testWidgets('a different device key in the same store is keyLost too', (
    tester,
  ) async {
    final server = DemoApi();
    final store = MemoryTokenStore();
    await enrol(tester, server, FakeDevice(seed: 'one'), store: store);
    await closeApp(tester);

    final container = await pumpRouter(
      tester,
      AppRoutes.router(),
      overrides: await deviceOverrides(
        server,
        FakeDevice(seed: 'two'),
        store: store,
      ),
    );
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.keyLost),
    );
  });
}
