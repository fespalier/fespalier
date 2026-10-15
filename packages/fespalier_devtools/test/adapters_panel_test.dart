// The Adapters tab (since 0.16.0): a card for each package that shows values, with a field and a
// Set button for the keys it lets a developer set, and what it says when there is nothing to show.
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:fespalier_devtools/src/ui/chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

FakeFespalierClient app({
  Map<String, Handler> handlers = const {},
  List<String> features = allFeatures,
}) => FakeFespalierClient(
  snapshot: fixture('snapshot_adapters'),
  features: features,
  handlers: handlers,
);

AdapterRecord flags({String flag = 'true', int at = 1696230004000}) =>
    AdapterRecord(
      seq: 13,
      adapter: 'fespalier_flags',
      title: 'Feature flags',
      at: at,
      values: [
        AdapterValueRecord(
          key: 'new_checkout',
          value: Shown('bool', flag),
          editable: true,
        ),
        const AdapterValueRecord(
          key: 'limit',
          value: Shown('int', '3'),
          editable: true,
        ),
        const AdapterValueRecord(
          key: 'source',
          value: Shown('String', 'remote'),
        ),
      ],
    );

/// The text a key's value is shown as (not the field of an editable one).
String? valueText(WidgetTester tester, String adapter, String key) =>
    tester.widget<SelectableText>(find.byKey(Key('text-$adapter-$key'))).data;

Map<String, Object?> event(int number, AdapterRecord record) => {
  'protocol': devToolsProtocol,
  DevToolsEventPayload.event: number,
  DevToolsEventPayload.record: record.toJson(),
};

void main() {
  testWidgets('says so before any adapter showed anything', (tester) async {
    await pumpApp(tester, FakeFespalierClient());
    await openTab(tester, 'Adapters');
    expect(find.byKey(const Key('no-adapters')), findsOneWidget);
    expect(
      find.text(
        'No adapter has shown anything yet. An adapter can list its state here '
        'with DevToolsAdapters.show (since 0.16.0); none of the packages in this '
        'repository does yet.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows a card per adapter: title, package, values and types', (
    tester,
  ) async {
    await pumpApp(tester, app());
    await openTab(tester, 'Adapters');
    final card = find.byKey(const Key('adapter-fespalier_flags'));
    for (final text in [
      'Feature flags',
      'fespalier_flags',
      'new_checkout',
      'bool',
      'limit',
      'int',
      'source',
      'remote',
      'overrides',
      'Map<String, bool>',
    ]) {
      expect(
        find.descendant(of: card, matching: find.text(text)),
        findsWidgets,
        reason: text,
      );
    }
    // The values are selectable text, apart from the fields of the editable ones.
    expect(valueText(tester, 'fespalier_flags', 'new_checkout'), 'true');
    expect(valueText(tester, 'fespalier_flags', 'limit'), '3');
    expect(valueText(tester, 'fespalier_flags', 'source'), 'remote');
    expect(
      valueText(tester, 'fespalier_flags', 'overrides'),
      '{new_checkout: true, legacy_search: false, beta_banner: true, experimental_cart: false}',
    );
    // When it was shown, and how long before the last refresh (the tab runs no timer).
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining(
          'updated ${formatClock(1696230004000)} (',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a card without a title is called by the package', (
    tester,
  ) async {
    await pumpApp(tester, app());
    await openTab(tester, 'Adapters');
    final card = find.byKey(const Key('adapter-fespalier_launch'));
    expect(
      find.descendant(of: card, matching: find.text('fespalier_launch')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('notification /orders/5')),
      findsOneWidget,
    );
  });

  testWidgets('says when the adapter gave more values than the app keeps', (
    tester,
  ) async {
    await pumpApp(tester, app());
    await openTab(tester, 'Adapters');
    expect(find.byKey(const Key('truncated-fespalier_launch')), findsOneWidget);
    expect(find.byKey(const Key('truncated-fespalier_flags')), findsNothing);
  });

  testWidgets('only an editable key has a field and a Set button', (
    tester,
  ) async {
    await pumpApp(tester, app());
    await openTab(tester, 'Adapters');
    for (final key in ['new_checkout', 'limit']) {
      expect(find.byKey(Key('edit-fespalier_flags-$key')), findsOneWidget);
      expect(find.byKey(Key('set-fespalier_flags-$key')), findsOneWidget);
    }
    for (final key in ['source', 'overrides']) {
      expect(find.byKey(Key('edit-fespalier_flags-$key')), findsNothing);
      expect(find.byKey(Key('set-fespalier_flags-$key')), findsNothing);
    }
    // The field starts with the value's text; a null starts empty.
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('edit-fespalier_flags-limit')),
          )
          .controller!
          .text,
      '3',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('edit-fespalier_launch-simulate')),
          )
          .controller!
          .text,
      '',
    );
  });

  testWidgets('Set sends the adapter, the key and the typed text', (
    tester,
  ) async {
    final client = app();
    await pumpApp(tester, client);
    await openTab(tester, 'Adapters');
    await tester.enterText(
      find.byKey(const Key('edit-fespalier_flags-new_checkout')),
      'false',
    );
    await tester.tap(find.byKey(const Key('set-fespalier_flags-new_checkout')));
    await settle(tester);
    expect(client.callsTo(DevToolsMethods.adapterEdit), [
      {'adapter': 'fespalier_flags', 'key': 'new_checkout', 'value': 'false'},
    ]);
    expect(find.byType(SnackBar), findsNothing);
    // Typing nothing sends the empty text, which is a value too.
    await tester.enterText(
      find.byKey(const Key('edit-fespalier_launch-simulate')),
      '/orders/9',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(client.callsTo(DevToolsMethods.adapterEdit).last, {
      'adapter': 'fespalier_launch',
      'key': 'simulate',
      'value': '/orders/9',
    });
  });

  testWidgets('says why the app refused', (tester) async {
    await pumpApp(
      tester,
      app(
        handlers: {
          DevToolsMethods.adapterEdit: (_) => const {
            'protocol': devToolsProtocol,
            'ok': false,
            'reason': '`limit` of fespalier_flags is not editable',
          },
        },
      ),
    );
    await openTab(tester, 'Adapters');
    await tester.tap(find.byKey(const Key('set-fespalier_flags-limit')));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('`limit` of fespalier_flags is not editable'),
      findsOneWidget,
    );
  });

  testWidgets('says what failed when the call itself failed', (tester) async {
    await pumpApp(
      tester,
      app(
        handlers: {
          DevToolsMethods.adapterEdit: (_) =>
              throw StateError('the VM went away'),
        },
      ),
    );
    await openTab(tester, 'Adapters');
    await tester.tap(find.byKey(const Key('set-fespalier_flags-limit')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Bad state: the VM went away'), findsOneWidget);
  });

  testWidgets(
    'an adapter event shows the new values in place, without a call',
    (tester) async {
      final client = app();
      await pumpApp(tester, client);
      await openTab(tester, 'Adapters');
      client.calls.clear();
      client.emit(DevToolsEvents.adapter, event(13, flags(flag: 'false')));
      await settle(tester);
      expect(client.calls, isEmpty);
      expect(valueText(tester, 'fespalier_flags', 'new_checkout'), 'false');
      // The field follows the value, because the developer was not typing.
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('edit-fespalier_flags-new_checkout')),
            )
            .controller!
            .text,
        'false',
      );
    },
  );

  testWidgets('what the developer is typing is kept when the value moves', (
    tester,
  ) async {
    final client = app();
    await pumpApp(tester, client);
    await openTab(tester, 'Adapters');
    final field = find.byKey(const Key('edit-fespalier_flags-new_checkout'));
    await tester.enterText(field, 'maybe');
    client.emit(DevToolsEvents.adapter, event(13, flags(flag: 'false')));
    await settle(tester);
    expect(tester.widget<TextField>(field).controller!.text, 'maybe');
  });

  testWidgets('a removed adapter leaves the tab, and the last one says so', (
    tester,
  ) async {
    final client = app();
    await pumpApp(tester, client);
    await openTab(tester, 'Adapters');
    client.emit(
      DevToolsEvents.adapter,
      event(
        13,
        const AdapterRecord(
          seq: 13,
          adapter: 'fespalier_flags',
          at: 1,
          removed: true,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const Key('adapter-fespalier_flags')), findsNothing);
    expect(find.byKey(const Key('adapter-fespalier_launch')), findsOneWidget);
    client.emit(
      DevToolsEvents.adapter,
      event(
        14,
        const AdapterRecord(
          seq: 14,
          adapter: 'fespalier_launch',
          at: 1,
          removed: true,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const Key('no-adapters')), findsOneWidget);
  });

  testWidgets('a new adapter is put in by name', (tester) async {
    final client = app();
    await pumpApp(tester, client);
    await openTab(tester, 'Adapters');
    client.emit(
      DevToolsEvents.adapter,
      event(
        13,
        const AdapterRecord(
          seq: 13,
          adapter: 'fespalier_connectivity',
          at: 1696230009000,
          values: [
            AdapterValueRecord(key: 'online', value: Shown('bool', 'true')),
          ],
        ),
      ),
    );
    await settle(tester);
    final tops = [
      for (final name in [
        'fespalier_connectivity',
        'fespalier_flags',
        'fespalier_launch',
      ])
        tester.getTopLeft(find.byKey(Key('adapter-$name'))).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets(
    'says what it cannot show for an app that does not report adapters',
    (tester) async {
      await pumpApp(
        tester,
        FakeFespalierClient(features: featuresBeforeAdapters),
      );
      await openTab(tester, 'Adapters');
      expect(
        find.textContaining('does not report its adapters'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('no-adapters')), findsNothing);
    },
  );

  testWidgets('schedules no frame once it has settled', (tester) async {
    await pumpApp(tester, app());
    await openTab(tester, 'Adapters');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
