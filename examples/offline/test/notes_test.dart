// /notes: rows the device owns. An edit is saved on the phone at once, offline or not, and a sync merges it with
// the server's row field by field. FakeRowServer plays the server; a second ProviderContainer plays another phone.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline/foreground_ticker.dart';

import 'support.dart';

OwnedRow _groceries() => OwnedRow(
  collection: 'notes',
  id: 'n1',
  fields: {'title': 'Groceries', 'body': 'Milk'},
  stamps: {
    'title': const Hlc(1, 0, 'server'),
    'body': const Hlc(1, 0, 'server'),
  },
);

/// Another phone of the same account, on the same server.
ProviderContainer _otherPhone(Harness shop) {
  final phone = ProviderContainer(
    overrides: crateStackTestOverrides(
      rowServer: shop.rows,
      collections: ['notes'],
      scope: 'ada',
    ),
  );
  addTearDown(phone.dispose);
  return phone;
}

void main() {
  testWidgets('the server\'s notes are pulled at start and listed', (
    tester,
  ) async {
    final shop = Harness()..rows.put(_groceries());
    await shop.open(tester, '/notes');

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Milk'), findsOneWidget);
    expect(shop.rows.pulls, greaterThan(0));
  });

  testWidgets(
    'an edit made offline is on the page at once and pushed when the network is back',
    (tester) async {
      final shop = Harness()..rows.put(_groceries());
      await shop.open(tester, '/notes');
      await shop.setNetwork(tester, online: false);

      await tester.tap(find.text('Groceries'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Body'),
        'Milk, eggs',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Saved on the phone, whatever the network: no wait, no error.
      expect(
        find.text('On this phone: Groceries / Milk, eggs'),
        findsOneWidget,
      );
      expect(find.text('Waiting to sync'), findsOneWidget);
      expect(shop.rows.row('notes', 'n1')!.fields['body'], 'Milk');

      await shop.setNetwork(tester, online: true);

      expect(shop.rows.row('notes', 'n1')!.fields['body'], 'Milk, eggs');
      expect(find.text('Waiting to sync'), findsNothing);
    },
  );

  testWidgets('two phones editing different fields both keep their edit', (
    tester,
  ) async {
    final shop = Harness()..rows.put(_groceries());
    await shop.open(tester, '/notes/n1');
    await shop.setNetwork(tester, online: false);

    // This phone changes the body, offline.
    await tester.enterText(
      find.widgetWithText(TextField, 'Body'),
      'Milk, eggs',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 1));

    // The other phone renames the note, a minute later, and its edit reaches the server first.
    final phone = _otherPhone(shop);
    await phone.read(ownedRows).edit('notes', 'n1', {'title': 'Shopping'});
    await phone.read(syncRunner).sync(SyncReason.manual);
    expect(shop.rows.row('notes', 'n1')!.fields['title'], 'Shopping');

    await shop.setNetwork(tester, online: true);

    // Neither was lost, here or on the server.
    expect(find.text('On this phone: Shopping / Milk, eggs'), findsOneWidget);
    final server = shop.rows.row('notes', 'n1')!.fields;
    expect(server['title'], 'Shopping');
    expect(server['body'], 'Milk, eggs');
  });

  testWidgets(
    'the same field edited on two phones goes to the greater stamp, on both',
    (tester) async {
      final shop = Harness()..rows.put(_groceries());
      await shop.open(tester, '/notes/n1');
      await shop.setNetwork(tester, online: false);

      await tester.enterText(
        find.widgetWithText(TextField, 'Body'),
        'Milk, eggs',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));

      // The other phone edits the same field later, whatever order the pushes arrive in.
      final phone = _otherPhone(shop);
      await phone.read(ownedRows).edit('notes', 'n1', {'body': 'Milk, bread'});
      await phone.read(syncRunner).sync(SyncReason.manual);

      await shop.setNetwork(tester, online: true);

      expect(
        find.text('On this phone: Groceries / Milk, bread'),
        findsOneWidget,
      );
      expect(shop.rows.row('notes', 'n1')!.fields['body'], 'Milk, bread');
    },
  );

  testWidgets(
    'a note the server refuses is rolled back, and the person is told',
    (tester) async {
      final shop = Harness()..rows.put(_groceries());
      shop.rows.rejectIds.add('n1');
      await shop.open(tester, '/notes/n1');

      await tester.enterText(
        find.widgetWithText(TextField, 'Body'),
        'Milk, eggs',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Back to the server's version, with the wire code only.
      expect(find.text('On this phone: Groceries / Milk'), findsOneWidget);
      expect(find.text('The server undid 1 edit (FORBIDDEN)'), findsOneWidget);
      expect(find.text('Waiting to sync'), findsNothing);
    },
  );

  testWidgets('the app\'s tick pushes an edit that nothing else would', (
    tester,
  ) async {
    final shop = Harness();
    final container = await shop.open(tester, '/notes');
    final pushed = shop.rows.pushes.length;

    // Written below the actions, so no best-effort sync follows it: only a trigger can send it.
    await container.read(ownedRows).edit('notes', 'n2', {
      'title': 'Ideas',
      'body': '',
    });
    await tester.pump();
    expect(shop.rows.pushes, hasLength(pushed));

    await tester.pump(const Duration(minutes: 5));
    tick(container);
    await tester.pumpAndSettle();

    expect(shop.rows.row('notes', 'n2')!.fields['title'], 'Ideas');
  });

  testWidgets('a new note is saved offline and opens for editing', (
    tester,
  ) async {
    final shop = Harness(startOffline: true);
    final container = await shop.open(tester, '/notes');

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Title'), findsOneWidget);
    final rows = await container.read(ownedRows).list('notes');
    expect(rows.single.fields['title'], 'New note');
    expect(rows.single.dirty, isNotEmpty);
  });

  testWidgets('the app\'s own timer fires the tick every five minutes', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [syncTicker.overrideWith(ForegroundTicker.new)],
    );
    final ticks = container.listen(syncTicker, (_, _) {});
    expect(ticks.read(), 0);

    await tester.pump(const Duration(minutes: 5));
    expect(ticks.read(), 1);

    // The timer ends with the provider: nothing is left pending.
    ticks.close();
    container.dispose();
  });
}
