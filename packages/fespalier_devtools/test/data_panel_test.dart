// The Data tab: each data.dart provider's state, builds, times and value, an Invalidate button,
// and the data.dart files that cannot be followed.
import 'package:devtools_app_shared/ui.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:fespalier_devtools/src/ui/chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';
import 'trace_fixtures.dart';

FakeFespalierClient app(List<DataRecord> data, {DateTime? now}) =>
    FakeFespalierClient(snapshot: tracedSnapshot(data: data));

void main() {
  testWidgets('says so before any provider was built', (tester) async {
    await pumpApp(tester, app(const []));
    await openTab(tester, 'Data');
    expect(find.text('No data.dart provider was built yet.'), findsOneWidget);
  });

  testWidgets('shows a provider with its file, route, state, builds and key', (
    tester,
  ) async {
    await pumpApp(tester, app([dataRecord(1, builds: 3, container: 2)]));
    await openTab(tester, 'Data');
    final row = find.byKey(const Key('data-1'));
    for (final text in [
      'orders/\$id/refund/data.dart',
      'RefundRoute',
      'data',
      'builds 3',
      'key 2',
      'container 2',
      'Refund: Refund(2)',
    ]) {
      expect(
        find.descendant(of: row, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(
      find.descendant(
        of: row,
        matching: find.text('created ${formatClock(dataRecord(1).created)}'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('updated ')),
      findsOneWidget,
    );
  });

  testWidgets('says how old the last change was at the last refresh', (
    tester,
  ) async {
    final record = dataRecord(1);
    await pumpApp(tester, app([record]));
    await openTab(tester, 'Data');
    // The controller counts to the moment it fetched: the record's time is years ago.
    expect(find.textContaining('before the last refresh'), findsOneWidget);
  });

  testWidgets('the state chips: loading, error, stream', (tester) async {
    await pumpApp(
      tester,
      app([
        dataRecord(1, state: DataState.loading, value: null),
        dataRecord(
          2,
          state: DataState.error,
          value: null,
          error: 'SocketException: no route',
        ),
        dataRecord(
          3,
          site: 'd71',
          key: null,
          state: DataState.stream,
          value: null,
        ),
      ]),
    );
    await openTab(tester, 'Data');
    expect(
      find.descendant(
        of: find.byKey(const Key('data-1')),
        matching: find.text('loading'),
      ),
      findsOneWidget,
    );
    final failed = find.byKey(const Key('data-2'));
    expect(
      find.descendant(
        of: failed,
        matching: find.text('SocketException: no route'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: failed,
        matching: find.widgetWithText(KindChip, 'error'),
      ),
      findsOneWidget,
    );
    final stream = find.byKey(const Key('data-3'));
    expect(
      find.descendant(of: stream, matching: find.text('stream')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: stream, matching: find.text('ticks/data.dart')),
      findsOneWidget,
    );
    // No key: nothing to say about it.
    expect(
      find.descendant(of: stream, matching: find.textContaining('key ')),
      findsNothing,
    );
  });

  testWidgets('a section\'s data.dart says it is a section', (tester) async {
    await pumpApp(
      tester,
      app([dataRecord(1, site: 'd56', key: const Shown('Null', 'null'))]),
    );
    await openTab(tester, 'Data');
    expect(find.text('reports/data.dart (section reports)'), findsOneWidget);
  });

  testWidgets('Invalidate asks the app to build that provider again', (
    tester,
  ) async {
    final client = app([dataRecord(1), dataRecord(2, site: 'd65')]);
    await pumpApp(tester, client);
    await openTab(tester, 'Data');
    await tester.tap(find.byKey(const Key('invalidate-2')));
    await settle(tester);
    expect(client.callsTo(DevToolsMethods.invalidate), [
      {'id': '2'},
    ]);
  });

  testWidgets('says so when the provider is gone', (tester) async {
    final client = FakeFespalierClient(
      snapshot: tracedSnapshot(data: [dataRecord(1)]),
      handlers: {
        DevToolsMethods.invalidate: (_) => {'protocol': 1, 'ok': false},
      },
    );
    await pumpApp(tester, client);
    await openTab(tester, 'Data');
    await tester.tap(find.byKey(const Key('invalidate-1')));
    await settle(tester);
    expect(find.textContaining('is not alive any more'), findsOneWidget);
  });

  testWidgets(
    'a disposed provider is hidden until asked for, and cannot be invalidated',
    (tester) async {
      await pumpApp(
        tester,
        app([
          dataRecord(1),
          dataRecord(2, site: 'd65', state: DataState.disposed),
        ]),
      );
      await openTab(tester, 'Data');
      expect(find.byKey(const Key('data-1')), findsOneWidget);
      expect(find.byKey(const Key('data-2')), findsNothing);
      expect(find.text('Show disposed (1)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('show-disposed')));
      await tester.pump();
      expect(find.byKey(const Key('data-2')), findsOneWidget);
      final button = tester.widget<DevToolsButton>(
        find.byKey(const Key('invalidate-2')),
      );
      expect(button.onPressed, isNull);
      // The live one can be.
      expect(
        tester
            .widget<DevToolsButton>(find.byKey(const Key('invalidate-1')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('says when everything shown was disposed', (tester) async {
    await pumpApp(tester, app([dataRecord(1, state: DataState.disposed)]));
    await openTab(tester, 'Data');
    expect(find.textContaining('turn on "Show disposed"'), findsOneWidget);
  });

  testWidgets(
    'lists the data.dart files of an app provider that nothing watched yet',
    (tester) async {
      await pumpApp(tester, app(const []));
      await openTab(tester, 'Data');
      final untraced = find.byKey(const Key('untraced'));
      await tester.scrollUntilVisible(
        untraced,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
        find.descendant(of: untraced, matching: find.text('Not watched yet')),
        findsOneWidget,
      );
      // The features example's `catalog/data.dart` selects a provider of its own.
      expect(
        find.descendant(
          of: untraced,
          matching: find.text('lib/app/catalog/data.dart'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: untraced,
          matching: find.textContaining('Riverpod'),
        ),
        findsOneWidget,
      );
      // And not one that is traced.
      expect(
        find.descendant(
          of: untraced,
          matching: find.text('lib/app/search/data.dart'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('says what it cannot show for an app that does not report data', (
    tester,
  ) async {
    await pumpApp(tester, FakeFespalierClient(features: firstFeatures));
    await openTab(tester, 'Data');
    expect(find.textContaining('does not report its data'), findsOneWidget);
  });

  testWidgets('a data event updates the row in place and adds a new one', (
    tester,
  ) async {
    final client = app([dataRecord(1, state: DataState.loading, value: null)]);
    await pumpApp(tester, client);
    await openTab(tester, 'Data');
    client.emit(
      DevToolsEvents.data,
      recordEvent(8, dataRecord(1, builds: 1).toJson()),
    );
    await settle(tester);
    expect(find.text('loading'), findsNothing);
    expect(find.text('Refund: Refund(2)'), findsOneWidget);
    client.emit(
      DevToolsEvents.data,
      recordEvent(9, dataRecord(2, site: 'd65').toJson()),
    );
    await settle(tester);
    expect(find.byKey(const Key('data-2')), findsOneWidget);
    expect(client.callsTo(DevToolsMethods.snapshot), hasLength(1));
  });

  testWidgets('schedules no frame once it has settled', (tester) async {
    await pumpApp(tester, app([dataRecord(1)]));
    await openTab(tester, 'Data');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  group('holders (since 0.8.1)', () {
    const appProvider = Shown('FutureProvider<Product>', 'featuredProvider');

    FakeFespalierClient holdersApp(
      List<DataRecord> data,
      HoldersRecord Function(int id) answer, {
      List<String> features = allFeatures,
    }) => FakeFespalierClient(
      snapshot: tracedSnapshot(data: data),
      features: features,
      handlers: {
        DevToolsMethods.holders: (params) =>
            answer(int.parse(params['id']!)).toJson(),
      },
    );

    testWidgets('the app\'s own provider is marked, shows its provider, and '
        'has no build count', (tester) async {
      final client = app([
        dataRecord(
          1,
          site: 'd14',
          key: null,
          via: DataVia.watch,
          provider: appProvider,
          builds: 0,
        ),
      ]);
      await pumpApp(tester, client);
      await openTab(tester, 'Data');
      final row = find.byKey(const Key('data-1'));
      expect(
        find.descendant(of: row, matching: find.text('app provider')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('featuredProvider')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('builds')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('listeners')),
        findsNothing,
      );
      expect(
        find.byTooltip("Invalidate this provider (the app's own)"),
        findsOneWidget,
      );
    });

    testWidgets('a provider fespalier built shows its listeners', (
      tester,
    ) async {
      await pumpApp(tester, app([dataRecord(1, listeners: 3)]));
      await openTab(tester, 'Data');
      final row = find.byKey(const Key('data-1'));
      expect(
        find.descendant(of: row, matching: find.text('listeners 3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('app provider')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.text('builds 1')),
        findsOneWidget,
      );
    });

    testWidgets('the Holders button lists each holder, and the others', (
      tester,
    ) async {
      final since = DateTime(2026, 10, 3, 12, 3, 4).millisecondsSinceEpoch;
      final client = holdersApp(
        [dataRecord(1, listeners: 5)],
        (id) => HoldersRecord(
          id: id,
          found: true,
          alive: true,
          listeners: 5,
          others: 1,
          holders: [
            HolderRecord(kind: HolderKind.view, since: since),
            HolderRecord(kind: HolderKind.section, since: since),
            const HolderRecord(
              kind: HolderKind.prefetch,
              since: 1,
              keepFor: 30000,
            ),
            const HolderRecord(kind: HolderKind.prefetch, since: 1),
            const HolderRecord(kind: HolderKind.link, since: 1, keepFor: 30000),
            const HolderRecord(kind: HolderKind.link, since: 1),
          ],
        ),
      );
      await pumpApp(tester, client);
      await openTab(tester, 'Data');
      expect(find.byKey(const Key('holders-list-1')), findsNothing);
      await tester.tap(find.byKey(const Key('holders-1')));
      await tester.pumpAndSettle();
      expect(client.callsTo(DevToolsMethods.holders), [
        {'id': '1'},
      ]);
      final list = find.byKey(const Key('holders-list-1'));
      for (final line in [
        'page view (since ${formatClock(since)})',
        'section view (since ${formatClock(since)})',
        'prefetch handle, kept 30 s',
        'prefetch handle, kept until closed',
        'RouteLink preload, kept 30 s',
        'RouteLink preload, kept until closed',
        '1 other listener: ref.watch or listen in your code, or another provider',
      ]) {
        expect(
          find.descendant(of: list, matching: find.text(line)),
          findsOneWidget,
          reason: line,
        );
      }
      // Pressed again, it closes.
      await tester.tap(find.byKey(const Key('holders-1')));
      await tester.pumpAndSettle();
      expect(list, findsNothing);
    });

    testWidgets('several other listeners, a disposed provider, and the app\'s '
        'own provider', (tester) async {
      final client = holdersApp(
        [
          dataRecord(1, listeners: 4),
          dataRecord(
            2,
            site: 'd14',
            key: null,
            via: DataVia.watch,
            provider: appProvider,
          ),
        ],
        (id) => id == 1
            ? const HoldersRecord(
                id: 1,
                found: true,
                alive: false,
                listeners: 0,
                others: 3,
              )
            : const HoldersRecord(id: 2, found: true, alive: true),
      );
      await pumpApp(tester, client);
      await openTab(tester, 'Data');
      await tester.tap(find.byKey(const Key('holders-1')));
      await tester.pumpAndSettle();
      var list = find.byKey(const Key('holders-list-1'));
      expect(
        find.descendant(
          of: list,
          matching: find.text(
            '3 other listeners: ref.watch or listen in your code, or another provider',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('disposed')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('holders-2')));
      await tester.pumpAndSettle();
      list = find.byKey(const Key('holders-list-2'));
      expect(
        find.descendant(
          of: list,
          matching: find.text(
            "Other listeners of an app provider are not visible here: see Riverpod's DevTools tab",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a provider that is no longer tracked says so', (tester) async {
      final client = holdersApp([
        dataRecord(1),
      ], (id) => HoldersRecord(id: id, found: false));
      await pumpApp(tester, client);
      await openTab(tester, 'Data');
      await tester.tap(find.byKey(const Key('holders-1')));
      await tester.pumpAndSettle();
      expect(find.text('This provider is no longer tracked.'), findsOneWidget);
    });

    testWidgets('an app without the holders feature has no button', (
      tester,
    ) async {
      final client = holdersApp(
        [dataRecord(1)],
        (id) => HoldersRecord(id: id, found: false),
        features: [
          for (final f in allFeatures)
            if (f != DevToolsFeatures.holders) f,
        ],
      );
      await pumpApp(tester, client);
      await openTab(tester, 'Data');
      expect(find.byKey(const Key('data-1')), findsOneWidget);
      expect(find.byKey(const Key('holders-1')), findsNothing);
    });

    testWidgets('Not watched yet leaves out a site that has a record', (
      tester,
    ) async {
      await pumpApp(
        tester,
        app([
          dataRecord(
            1,
            site: 'd14',
            key: null,
            via: DataVia.watch,
            provider: appProvider,
          ),
        ]),
      );
      await openTab(tester, 'Data');
      final untraced = find.byKey(const Key('untraced'));
      await tester.scrollUntilVisible(
        untraced,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
        find.descendant(
          of: untraced,
          matching: find.text('lib/app/catalog/data.dart'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: untraced,
          matching: find.text('lib/app/catalog/\$productId/data.dart'),
        ),
        findsOneWidget,
      );
    });
  });
}
