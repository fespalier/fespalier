import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/app.g.dart';
import 'package:frb_cose_example/app.main.g.dart';
import 'package:frb_cose_example/app/core/page.dart';
import 'package:frb_cose_example/src/core.dart';
import 'package:frb_cose_example/src/core_view.dart';
import 'package:frb_cose_example/src/notes.dart';
import 'package:frb_cose_example/src/wiring.dart';

import 'support/fakes.dart';

/// Opens `/core`. The route stacks the notes page beneath it, and that page reads the list when it is built, so the
/// core is asked once before anything else: the test answers that read as an empty list, and the journal starts with
/// its row.
Future<FakeNotesCore> _boot(WidgetTester tester) async {
  final core = FakeNotesCore(kid: 'a1b2c3d4')
    ..next.add(const CoreAnswer(status: 200, bodyJson: '{"notes":[]}'));
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/core'),
    overrides: coreOverrides(
      core: core,
      identity: const DeviceIdentity(kid: 'a1b2c3d4', thumbprint: 'thumb'),
    ),
    app: AppMain.app,
  );
  return core;
}

void main() {
  testWidgets(
    'the core page shows the key, the registration and the read beneath it',
    (tester) async {
      final core = await _boot(tester);

      expect(find.text('Device key a1b2c3d4'), findsOneWidget);
      expect(
        find.text('Not registered yet: the first call registers the key.'),
        findsOneWidget,
      );
      expect(core.calls.single.op, Ops.listNotes);
      expect(find.text(Ops.listNotes), findsOneWidget);
      expect(find.text('answered (sent, status 200)'), findsOneWidget);
    },
  );

  testWidgets('with no calls at all, the page says so', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CorePage(
          view: CoreView(kid: 'k', registered: false, journal: []),
        ),
      ),
    );

    expect(find.text('No calls yet.'), findsOneWidget);
  });

  testWidgets('a call the core makes is in the journal as it happens', (
    tester,
  ) async {
    final core = await _boot(tester);

    core.registered = true;
    await core.call(
      op: Ops.addNote,
      argsJson: '{"text":"hi"}',
      idempotencyKey: 'k#0',
    );
    await tester.pumpAndSettle();

    expect(find.text('Registered with the server.'), findsOneWidget);
    expect(find.text(Ops.addNote), findsOneWidget);
    expect(find.text('answered (sent, status 200, key k#0)'), findsOneWidget);
  });

  testWidgets('a write shows its key, and a refused one its outcome', (
    tester,
  ) async {
    final core = await _boot(tester);

    core
      ..next.add(const CoreError(kind: CoreErrorKind.transport, message: ''))
      ..next.add(const CoreAnswer(status: 201, bodyJson: '{}'));
    await expectLater(
      core.call(op: Ops.addNote, argsJson: '{}', idempotencyKey: 'k#0'),
      throwsA(isA<CoreError>()),
    );
    await core.call(op: Ops.addNote, argsJson: '{}', idempotencyKey: 'k#1');
    await tester.pumpAndSettle();

    expect(find.text('unreachable (sent, key k#0)'), findsOneWidget);
    expect(find.text('answered (sent, status 201, key k#1)'), findsOneWidget);
  });
}
