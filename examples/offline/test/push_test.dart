// A push from the server (since 0.25.0): the app reads the server's `@@subscribe` stream with
// crateStackEvents, and autoSync syncs when it says a note changed, without waiting for a resume, a
// reconnect or the tick. Over the real demo server, and over the package's fakes (FakeEventServer
// plays the subscription, FakeRowServer the notes).
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline/app.g.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/server_changes.dart';
import 'package:offline/session.dart';
import 'package:offline/wiring.dart';

import 'support.dart';

void main() {
  testWidgets('a change on the server reaches the open note at once, by push', (
    tester,
  ) async {
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/notes/n1'),
      overrides: [
        localStore.overrideWithValue(InMemoryLocalStore()),
        appResumeSignal.overrideWith(RefetchSignal.new),
        ...appWiring(),
        noteRowSync(),
        serverPush(),
        // startup() has the app's own timer here; this test never fires it.
        syncTicker.overrideWith(ManualSyncTicker.new),
      ],
    );
    await tester.pumpAndSettle();
    expect(container.read(demoServer).subscriberCount, 1);
    expect(find.text('On this phone: Groceries / Milk, eggs'), findsOneWidget);

    // The other phone renames the note on the server; the server tells its subscribers.
    await tester.tap(find.text('Rename on the other phone'));
    await tester.pumpAndSettle();

    expect(
      find.text('On this phone: Groceries (renamed elsewhere) / Milk, eggs'),
      findsOneWidget,
    );
  });

  testWidgets(
    'an event pulls the rows; a lag reopens the subscription and syncs again',
    (tester) async {
      final shop = Harness()
        ..rows.put(
          OwnedRow(
            collection: 'notes',
            id: 'n1',
            fields: {'title': 'Groceries', 'body': 'Milk'},
            stamps: {
              'title': const Hlc(1, 0, 'server'),
              'body': const Hlc(1, 0, 'server'),
            },
          ),
        );
      final events = FakeEventServer();
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/notes'),
        overrides: [
          ...shop.overrides,
          serverPush(),
          subscriptionTransport.overrideWithValue(events),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Groceries'), findsOneWidget);
      final pulls = shop.rows.pulls;
      expect(
        events.current.request.uri.path,
        '/rpc/subscribe/model.Note.subscribe',
      );

      // Another phone's edit reaches the server, which says so. Its data is not what the page shows:
      // the sync pulls the row.
      shop.rows.put(
        OwnedRow(
          collection: 'notes',
          id: 'n1',
          fields: {'title': 'Shopping'},
          stamps: {'title': const Hlc(2, 0, 'other-phone')},
        ),
      );
      events.current.modelEvent(
        'Note',
        'Updated',
        data: {'title': 'not shown'},
      );
      await tester.pumpAndSettle();
      expect(find.text('Shopping'), findsOneWidget);
      expect(find.text('not shown'), findsNothing);
      expect(shop.rows.pulls, pulls + 1);

      // The server drops a subscriber that read too slowly. It opens again, and since it cannot resume,
      // the app syncs once more: it may have missed a change.
      events.current.lagged(sequence: 2);
      await tester.pumpAndSettle();
      expect(events.connections, hasLength(2));
      expect(shop.rows.pulls, pulls + 2);
    },
  );

  testWidgets(
    'the subscription follows the account: a new one opens as someone else',
    (tester) async {
      final shop = Harness();
      final events = FakeEventServer();
      final container = await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/notes'),
        overrides: [
          ...shop.overrides,
          serverPush(),
          subscriptionTransport.overrideWithValue(events),
        ],
      );
      await tester.pumpAndSettle();
      expect(events.requests, hasLength(1));

      // Another account signs in on this phone: the first one's connection is closed, and the new
      // session opens its own. (It would be the one that opens a subscription the server refused.)
      container.read(accountId.notifier).signIn('grace');
      await tester.pumpAndSettle();
      expect(events.requests, hasLength(2));
      expect(events.abortCount, 1);
      expect(
        events.current.request.uri.path,
        '/rpc/subscribe/model.Note.subscribe',
      );
    },
  );
}
