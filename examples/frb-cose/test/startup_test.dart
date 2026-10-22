import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/app.g.dart';
import 'package:frb_cose_example/app.main.g.dart';
import 'package:frb_cose_example/src/core.dart';
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
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(notesCore).available, isTrue);
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
        ),
      );
      addTearDown(container.dispose);

      // An app restart drops what an InMemoryLocalStore holds. Wiring a durable store (HiveLocalStore) is the change that
      // makes this test fail, and the README's "Not built" bullet, notes.dart and docs/examples.md say the same.
      expect(container.read(localStore), isA<InMemoryLocalStore>());
    },
  );

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
