// Signing out revokes the device on the server (signed with the user-present key, which prompts),
// then deletes both keys and the stored session, whatever the revocation did, and wipes what the
// phone saved of the account's reads.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets('sign-out revokes the device, then deletes the keys', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final device = FakeDevice();
    final store = MemoryTokenStore();
    final container = await enrol(tester, server, device, store: store);
    final prompts = device.prompts;
    await pumpRouter(tester, AppRoutes.router(), container: container);

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
    expect('$revoke', 'POST revokeDevice');
    expect(revoke.args, {'deviceId': 'device-1'});
    expect(revoke.refusedWith, isNull);
    expect(revoke.signedWith?.name, 'userPresent');
    expect(revoke.headers, isNot(contains('authorization')));
    expect(device.prompts, prompts + 1, reason: 'revoking asks the user');
    expect(device.ambient.deletes, 1);
    expect(device.presence!.deletes, 1);
    expect(store.value, isNull);
  });

  testWidgets('a refused prompt does not keep the keys', (tester) async {
    final server = FakeOrdersServer();
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
    final server = FakeOrdersServer();
    final container = await enrol(
      tester,
      server,
      FakeDevice(userPresent: false),
    );
    await pumpRouter(tester, AppRoutes.router(), container: container);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(server.revocations, 1);
    expect(server.served.last.signedWith?.name, 'ambient');
  });

  testWidgets(
    'what the phone saved of the account\'s orders goes with the session',
    (tester) async {
      final server = FakeOrdersServer();
      final container = await enrol(tester, server, FakeDevice());
      final router = AppRoutes.router(initialLocation: '/orders');
      await pumpRouter(tester, router, container: container);
      expect(find.text('2 x Espresso beans'), findsOneWidget);

      router.go('/');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      // The same person enrols again, and the server is out of reach: the copy of the first session
      // is not there to be shown.
      await tester.tap(find.text('Enrol this device'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), phone);
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), FakeOrdersServer.otp);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
      await tester.pumpAndSettle();
      expect(container.read(authSession), isA<SignedIn>());
      server.offline = true;
      router.go('/orders');
      await tester.pumpAndSettle();
      expect(
        find.text('Offline: not loaded on this phone yet'),
        findsOneWidget,
      );
    },
  );
}
