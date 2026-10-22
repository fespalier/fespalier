// Shared by the tests: the app booted against the in-process demo server, on fake device keys.
import 'package:device/app.g.dart';
import 'package:device/demo/demo_api.dart';
import 'package:device/device_setup.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The phone number the tests type, and the number the server keeps it as.
const String phone = '+237 6 55 00 00 00';
const String normalisedPhone = '+237655000000';

/// Closes the app, as the user does, so the next [pumpRouter] is a new start.
Future<void> closeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// A device with fake keys: the same keys on every run, and no platform. [prompts] counts what the
/// user-present key was asked to sign, and [refuseNextPrompt] plays a cancelled prompt.
class FakeDevice {
  /// A device. Without [userPresent] it is the web's: the ambient key only.
  FakeDevice({String seed = 'device example', bool userPresent = true})
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

/// The overrides `startup()` would return, with the device backend over [server], on [device]'s
/// keys, in memory. With a [store] that already holds a session, the app starts signed in (unless
/// the key it is bound to is gone).
Future<List<Override>> deviceOverrides(
  DemoApi server,
  FakeDevice device, {
  TokenStore? store,
}) async => restoreAuth(
  authSetup(
    server.transport,
    keys: device.keys,
    store: store ?? MemoryTokenStore(),
  ),
);

/// Enrols [device] by the screens, from `/enrol`: the phone number, then the code.
Future<ProviderContainer> enrol(
  WidgetTester tester,
  DemoApi server,
  FakeDevice device, {
  String initialLocation = '/enrol',
  TokenStore? store,
}) async {
  final container = await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: initialLocation),
    overrides: await deviceOverrides(server, device, store: store),
  );
  await tester.enterText(find.byType(TextField), phone);
  await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), DemoApi.demoCode);
  await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
  await tester.pumpAndSettle();
  return container;
}

/// Whether a stored session holds anything that looks like a token.
bool holdsAToken(String stored) =>
    RegExp('token|bearer|secret', caseSensitive: false).hasMatch(stored);
