import 'dart:typed_data';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/app.g.dart';
import 'package:frb_cose_example/app.main.g.dart';
import 'package:frb_cose_example/src/core.dart';
import 'package:frb_cose_example/src/device_key.dart';
import 'package:frb_cose_example/src/notes.dart';
import 'package:frb_cose_example/src/wiring.dart';

import 'support/fakes.dart';

/// What `startup()` gives the app: the wiring of a build with a core, and the web's, where the core is left out.
void main() {
  test(
    'the wiring with a core: the transport is over it, the account is the thumbprint',
    () async {
      final core = FakeNotesCore(kid: 'a1b2c3d4');
      final container = ProviderContainer(
        overrides: coreOverrides(
          core: core,
          identity: const DeviceIdentity(kid: 'a1b2c3d4', thumbprint: 'thumb'),
          keyKind: DeviceKeyKind.hardware,
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(notesCore).available, isTrue);
      expect(container.read(deviceKeyKind), DeviceKeyKind.hardware);
      expect(container.read(crateStackScope), 'thumb');
      expect(container.read(deviceIdentity).kid, 'a1b2c3d4');

      core.next.add(const CoreAnswer(status: 200, bodyJson: '{"notes":[]}'));
      final result = await container
          .read(crateStackTransport)
          .send(const RpcCall(Ops.listNotes, <String, Object?>{}));
      expect(notesFromWire(result), isEmpty);
      expect(core.calls.single.op, Ops.listNotes);
    },
  );

  test(
    'the read copy and the queued writes are in memory: the wiring leaves localStore alone (README, Not built)',
    () {
      final container = ProviderContainer(
        overrides: coreOverrides(
          core: FakeNotesCore(),
          identity: const DeviceIdentity(kid: 'k', thumbprint: 'thumb'),
          keyKind: DeviceKeyKind.software,
        ),
      );
      addTearDown(container.dispose);

      // An app restart drops what an InMemoryLocalStore holds. Wiring a durable store (HiveLocalStore) is the change that
      // makes this test fail, and the README's "Not built" bullet, notes.dart and docs/examples.md say the same.
      expect(container.read(localStore), isA<InMemoryLocalStore>());
    },
  );

  group('the device key says how it is held, and a fallback is never silent', () {
    test('a keystore key that is hardware-backed is hardware', () async {
      final keystore = FakeKeypairSigner(hardware: true);

      final opened = await openDeviceSigner(keystore: () => keystore);

      expect(opened.kind, DeviceKeyKind.hardware);
      expect(opened.signer, same(keystore));
    });

    test('a keystore key that is not hardware-backed is software', () async {
      final keystore = FakeKeypairSigner();

      final opened = await openDeviceSigner(keystore: () => keystore);

      expect(opened.kind, DeviceKeyKind.software);
      expect(opened.signer, same(keystore));
    });

    test(
      'a keystore that throws falls back to a software key in memory, and says so',
      () async {
        final opened = await openDeviceSigner(keystore: _BrokenKeystore.new);

        expect(opened.kind, DeviceKeyKind.inMemory);
        expect(opened.signer, isA<SoftwareKeypairSigner>());
        expect(await opened.signer.isHardwareBacked(), isFalse);
        expect((await opened.signer.publicJwk())['crv'], 'P-256');
      },
    );

    test(
      'requireHardware takes the keystore\'s failure instead of falling back',
      () async {
        await expectLater(
          openDeviceSigner(
            requireHardware: true,
            keystore: _BrokenKeystore.new,
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('requireHardware keeps a hardware key', () async {
      final opened = await openDeviceSigner(
        requireHardware: true,
        keystore: () => FakeKeypairSigner(hardware: true),
      );

      expect(opened.kind, DeviceKeyKind.hardware);
    });
  });

  test(
    'the web wiring: no core and no account, and a call is offline without reaching anything',
    () async {
      final container = ProviderContainer(overrides: unavailableOverrides());
      addTearDown(container.dispose);

      expect(container.read(notesCore).available, isFalse);
      expect(container.read(notesCore).journal(), isEmpty);
      expect(container.read(crateStackScope), isNull);
      await expectLater(
        container
            .read(crateStackTransport)
            .send(const RpcCall(Ops.listNotes, <String, Object?>{})),
        throwsA(isA<CrateStackOffline>()),
      );
    },
  );

  group('on the web, the pages say the core is not in the build', () {
    testWidgets('the notes page: no call, Add disabled', (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(),
        overrides: unavailableOverrides(),
        app: AppMain.app,
      );

      expect(
        find.text(
          'The Rust core is not in this build: no call is made, and nothing is saved.',
        ),
        findsOneWidget,
      );
      expect(find.text('No notes yet.'), findsOneWidget);
      expect(find.text('Device key: none in a web build'), findsOneWidget);
      final add = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Add'),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('the core page: not built for the web', (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/core'),
        overrides: unavailableOverrides(),
        app: AppMain.app,
      );

      expect(find.textContaining('Not built for the web'), findsOneWidget);
      expect(find.text('No calls yet.'), findsNothing);
    });
  });
}

/// A keystore that cannot open: its key cannot be made, as on a macOS build without a signing certificate.
final class _BrokenKeystore implements KeypairSigner {
  @override
  KeyRole get role => KeyRole.ambient;

  @override
  Future<Map<String, String>> publicJwk() =>
      Future.error(StateError('the keychain refused the key'));

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) =>
      Future.error(StateError('no key'));

  @override
  Future<bool> isHardwareBacked() => Future.error(StateError('no key'));

  @override
  Future<bool> exists() async => false;

  @override
  Future<void> deleteKey() async {}
}
