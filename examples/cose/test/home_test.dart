import 'package:cose_example/app.g.dart';
import 'package:cose_example/app.main.g.dart';
import 'package:cose_example/src/cose/cose.dart';
import 'package:cose_example/src/notes.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart' show ReadCache;
import 'package:fespalier_cratestack/testing.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The page over a fake transport: what the signing and the sealing do is the transport's, tested
/// in transport_test.dart and, against the real server, in e2e_test.dart.
class _Server {
  _Server() {
    fake
      ..on(
        Ops.listNotes,
        (_) => {
          'notes': [...notes],
        },
      )
      ..on(Ops.addNote, (input) {
        final note = {'id': notes.length + 1, 'text': (input! as Map)['text']};
        notes.add(note);
        return note;
      });
  }

  final fake = FakeCrateStackTransport();
  final notes = <Map<String, Object?>>[];
  final store = InMemoryLocalStore();
}

Future<List<Override>> _overrides(_Server server) async {
  final identity = await CoseSealer(FakeDpopSigner()).identity();
  return [
    ...crateStackTestOverrides(
      transport: server.fake,
      store: server.store,
      scope: thumbprintHex(identity),
    ),
    deviceIdentity.overrideWithValue(identity),
  ];
}

Iterable<RecordedCall> _writes(_Server server) => server.fake.calls.where(
  (c) => FakeCrateStackTransport.nameOf(c.call) == Ops.addNote,
);

/// What an earlier run of the app saved: the server's last list, in the device's read cache.
Future<void> _keepCopy(_Server server, String text) async {
  final identity = await CoseSealer(FakeDpopSigner()).identity();
  await ReadCache.local(server.store).write(
    thumbprintHex(identity),
    'notes',
    notesCodec.version,
    notesCodec.toJson([Note(id: 1, text: text)]),
    DateTime.utc(2026, 10, 8, 10, 42),
  );
}

Future<void> _boot(WidgetTester tester, _Server server) async {
  await pumpRouter(
    tester,
    AppRoutes.router(),
    overrides: await _overrides(server),
    app: AppMain.app,
  );
}

void main() {
  testWidgets('lists the notes the server sealed, and says so', (tester) async {
    final server = _Server()..notes.add({'id': 1, 'text': 'first'});
    await _boot(tester, server);

    expect(find.text('first'), findsOneWidget);
    expect(find.textContaining('Answered by the server'), findsOneWidget);
    expect(find.textContaining('Device key '), findsOneWidget);
    expect(
      server.fake.calls.single.call.toString(),
      'RpcCall(${Ops.listNotes})',
    );
  });

  testWidgets(
    'adds a note: one signed write under an idempotency key, then the list',
    (tester) async {
      final server = _Server();
      await _boot(tester, server);
      expect(find.text('No notes yet.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  buy milk ');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('buy milk'), findsOneWidget);
      expect(find.text('Saved as note #1'), findsOneWidget);
      final write = server.fake.calls.singleWhere(
        (c) => FakeCrateStackTransport.nameOf(c.call) == Ops.addNote,
      );
      expect(write.idempotencyKey, matches(RegExp(r'^[0-9a-f]{32}#0$')));
      expect(server.fake.runs(Ops.addNote), 1);
    },
  );

  testWidgets('an empty note is refused on the device and sends nothing', (
    tester,
  ) async {
    final server = _Server();
    await _boot(tester, server);

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Write something'), findsOneWidget);
    expect(server.fake.runs(Ops.addNote), 0);
  });

  testWidgets(
    'offline, a note is kept under its key and sent when the server answers',
    (tester) async {
      final server = _Server();
      await _boot(tester, server);

      server.fake.offline = true;
      await tester.enterText(find.byType(TextField), 'later');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No answer yet. Kept under key'),
        findsOneWidget,
      );
      expect(find.text('Send waiting (1)'), findsOneWidget);
      expect(server.notes, isEmpty);
      final first = _writes(server).last.idempotencyKey;

      server.fake.offline = false;
      await tester.tap(find.text('Send waiting (1)'));
      await tester.pumpAndSettle();

      // The same key, and now the list shows it (the accepted intent bumped the `notes` tag).
      expect(_writes(server).map((c) => c.idempotencyKey), [first, first]);
      expect(find.text('later'), findsOneWidget);
      expect(find.textContaining('Send waiting'), findsNothing);
    },
  );

  testWidgets('a 401 keeps the note pending under the same key', (
    tester,
  ) async {
    final server = _Server();
    await _boot(tester, server);

    server.fake.refuse(
      Ops.addNote,
      401,
      'UNAUTHENTICATED',
      'request could not be authenticated',
      times: 2,
    );
    await tester.enterText(find.byType(TextField), 'sealed');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Send waiting (1)'), findsOneWidget);

    await tester.tap(find.text('Send waiting (1)'));
    await tester.pumpAndSettle();
    final keys = _writes(server).map((c) => c.idempotencyKey).toSet();
    expect(keys, hasLength(1), reason: 'a 401 is not a decision: no next key');
  });

  testWidgets('a refusal is shown, and nothing is kept', (tester) async {
    final server = _Server();
    await _boot(tester, server);

    server.fake.refuse(Ops.addNote, 422, 'VALIDATION_ERROR', 'too long');
    await tester.enterText(find.byType(TextField), 'x');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('The server refused it'), findsOneWidget);
    expect(find.textContaining('Send waiting'), findsNothing);
  });

  testWidgets(
    'with no answer from the server the page shows the copy the device kept',
    (tester) async {
      final server = _Server();
      await _keepCopy(server, 'kept');
      server.fake.offline = true;
      await _boot(tester, server);

      expect(find.text('kept'), findsOneWidget);
      expect(
        find.textContaining('The server did not answer: the copy of'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a 401 on the read is the answer: error.dart, not the copy', (
    tester,
  ) async {
    final server = _Server();
    await _keepCopy(server, 'kept');
    server.fake.refuse(Ops.listNotes, 401, 'UNAUTHENTICATED', 'no');
    await _boot(tester, server);

    expect(find.textContaining("Couldn't load the notes"), findsOneWidget);
    expect(find.text('kept'), findsNothing);
  });
}
