// Shared by the tests: the app booted against the in-memory server, on fake device keys.
import 'package:cratestack_example/app.g.dart';
import 'package:cratestack_example/src/config.dart';
import 'package:cratestack_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart'
    show PortalTransport;
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart'
    show DeviceKeys;
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

/// The phone number the tests type.
const String phone = '+237 6 55 00 00 00';

/// A device with fake keys: the same keys on every run, and no platform. [prompts] counts what the
/// user-present key was asked to sign, and `presence.refuseNextPrompt()` plays a cancelled prompt.
class FakeDevice {
  /// A device. Without [userPresent] it is the web's: the ambient key only.
  FakeDevice({String seed = 'cratestack example', bool userPresent = true})
    : ambient = FakeKeypairSigner(
        keyId: 'ambient',
        role: KeyRole.ambient,
        seed: '$seed ambient',
      ),
      presence = userPresent
          ? FakeKeypairSigner(
              keyId: 'user_present',
              role: KeyRole.userPresent,
              seed: '$seed user present',
            )
          : null;

  /// The key that never prompts.
  final FakeKeypairSigner ambient;

  /// The key that prompts, when the device has one.
  final FakeKeypairSigner? presence;

  /// The keys, as `DeviceAuthBackend` takes them.
  DeviceKeys get keys => DeviceKeys(ambient: ambient, userPresent: presence);

  /// How many times the user was asked to confirm.
  int get prompts => presence?.prompts ?? 0;
}

/// The config of the tests: the fake server's origin and audience.
final OrdersConfig testConfig = OrdersConfig(
  server: FakeOrdersServer.origin,
  audience: FakeOrdersServer.audience,
);

/// The chain `startup()` builds, over the fake server instead of the network.
HttpTransport network(FakeOrdersServer server) =>
    PortalTransport(WriteGuardTransport(server.transport));

/// The overrides `startup()` would return, on [device]'s keys, in memory. With a [store] that already
/// holds a session, the app starts signed in (unless the key it is bound to is gone).
Future<List<Override>> appOverrides(
  FakeOrdersServer server,
  FakeDevice device, {
  TokenStore? store,
  Duration renewAhead = const Duration(hours: 12),
}) async => [
  ...await restoreAuth(
    authSetup(
      network(server),
      testConfig,
      keys: device.keys,
      store: store ?? MemoryTokenStore(),
      renewAhead: renewAhead,
    ),
  ),
  ...ordersOverrides(testConfig),
];

/// Enrols [device] by the screens, from `/enrol`: the phone number, then the code.
Future<ProviderContainer> enrol(
  WidgetTester tester,
  FakeOrdersServer server,
  FakeDevice device, {
  String initialLocation = '/enrol',
  TokenStore? store,
  Duration renewAhead = const Duration(hours: 12),
}) async {
  final container = await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: initialLocation),
    overrides: await appOverrides(
      server,
      device,
      store: store,
      renewAhead: renewAhead,
    ),
  );
  await tester.enterText(find.byType(TextField), phone);
  await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), FakeOrdersServer.otp);
  await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
  await tester.pumpAndSettle();
  return container;
}

/// The signed requests the server answered, in order.
extension ServedRequests on FakeOrdersServer {
  List<Served> get signedCalls => served.where((s) => s.signed).toList();
}

/// The text of every `Text` on screen, to read a page at a glance.
String screenText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join(' | ');
