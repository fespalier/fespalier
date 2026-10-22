// Signing out revokes the device on the server (signed with the user-present key, which prompts),
// and then deletes both keys and the stored session, whatever the revocation did.
import 'package:device/app.g.dart';
import 'package:device/demo/demo_api.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('sign-out revokes the device, then deletes the keys', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice();
    final store = MemoryTokenStore();
    final container = await enrol(tester, server, device, store: store);
    final prompts = device.prompts;
    final router = AppRoutes.router();
    await pumpRouter(tester, router, container: container);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.user),
    );
    expect(find.text('Not enrolled'), findsOneWidget);
    expect(server.revocations, 1);
    expect(server.isRevoked('device-1'), isTrue);
    final revoke = server.served.last;
    expect('$revoke', 'DELETE /devices/device-1');
    expect(revoke.refusedWith, isNull);
    expect(revoke.signedWith?.name, 'userPresent');
    expect(revoke.headers, isNot(contains('authorization')));
    expect(device.prompts, prompts + 1, reason: 'revoking asks the user');
    expect(device.ambient.deletes, 1);
    expect(device.presence!.deletes, 1);
    expect(store.value, isNull);
  });

  testWidgets('a refused prompt does not keep the keys', (tester) async {
    final server = DemoApi();
    final device = FakeDevice();
    final store = MemoryTokenStore();
    final container = await enrol(tester, server, device, store: store);
    await pumpRouter(tester, AppRoutes.router(), container: container);

    device.presence!.refuseNextPrompt();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    // Best effort: the server was not told, and the local keys are gone all the same.
    expect(server.revocations, 0);
    expect(device.ambient.deletes, 1);
    expect(device.presence!.deletes, 1);
    expect(store.value, isNull);
    expect(container.read(authSession), isA<SignedOut>());
  });

  testWidgets('without a user-present key, the ambient key revokes', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice(userPresent: false);
    final container = await enrol(tester, server, device);
    await pumpRouter(tester, AppRoutes.router(), container: container);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(server.revocations, 1);
    expect(server.served.last.signedWith?.name, 'ambient');
  });
}
