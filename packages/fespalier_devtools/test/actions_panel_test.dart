// The Actions tab: the runs of the action.dart functions, newest first.
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:fespalier_devtools/src/ui/chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';
import 'trace_fixtures.dart';

FakeFespalierClient app(List<ActionRecord> actions) =>
    FakeFespalierClient(snapshot: tracedSnapshot(actions: actions));

void main() {
  testWidgets('says so before any action ran', (tester) async {
    await pumpApp(tester, app(const []));
    await openTab(tester, 'Actions');
    expect(find.text('No action has run yet.'), findsOneWidget);
  });

  testWidgets('shows a run: function, key, input, state, time and result', (
    tester,
  ) async {
    await pumpApp(tester, app([actionRecord(1)]));
    await openTab(tester, 'Actions');
    final row = find.byKey(const Key('action-1'));
    for (final text in [
      'orders/\$id/refund/action.dart#action',
      'done',
      'key 2',
      'input RefundInput: RefundInput(5)',
      '120 ms',
      'result bool: true',
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
        matching: find.text(formatClock(actionRecord(1).started)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('newest first, with a running action and a failed one', (
    tester,
  ) async {
    await pumpApp(
      tester,
      app([
        actionRecord(1),
        actionRecord(
          2,
          site: 'a72_0',
          key: const Shown('String', 't1'),
          input: const Shown('String', 'ann'),
          state: ActionState.running,
          ms: null,
          result: null,
        ),
        actionRecord(
          3,
          state: ActionState.error,
          result: null,
          error: 'Exception: refused',
        ),
      ]),
    );
    await openTab(tester, 'Actions');
    final tops = [
      for (final seq in [3, 2, 1])
        tester.getTopLeft(find.byKey(Key('action-$seq'))).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    final running = find.byKey(const Key('action-2'));
    expect(
      find.descendant(of: running, matching: find.text('running')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: running,
        matching: find.text('teams/\$teamId/action.dart#addMember'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: running, matching: find.textContaining(' ms')),
      findsNothing,
    );
    final failed = find.byKey(const Key('action-3'));
    expect(
      find.descendant(of: failed, matching: find.text('Exception: refused')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: failed,
        matching: find.widgetWithText(KindChip, 'error'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a run with no key shows none', (tester) async {
    await pumpApp(tester, app([actionRecord(1, key: null)]));
    await openTab(tester, 'Actions');
    expect(find.textContaining('key '), findsNothing);
  });

  testWidgets('a run whose site the tree lacks shows the site', (tester) async {
    await pumpApp(tester, app([actionRecord(1, site: 'a99_9')]));
    await openTab(tester, 'Actions');
    expect(find.text('a99_9'), findsOneWidget);
  });

  testWidgets(
    'says what it cannot show for an app that does not report actions',
    (tester) async {
      await pumpApp(tester, FakeFespalierClient(features: firstFeatures));
      await openTab(tester, 'Actions');
      expect(
        find.textContaining('does not report its actions'),
        findsOneWidget,
      );
    },
  );

  testWidgets('an action event moves a running run to done in place', (
    tester,
  ) async {
    final client = app([
      actionRecord(1, state: ActionState.running, ms: null, result: null),
    ]);
    await pumpApp(tester, client);
    await openTab(tester, 'Actions');
    expect(find.text('running'), findsOneWidget);
    client.emit(
      DevToolsEvents.action,
      recordEvent(8, actionRecord(1).toJson()),
    );
    await settle(tester);
    expect(find.text('running'), findsNothing);
    expect(find.text('done'), findsOneWidget);
    expect(find.byKey(const Key('action-1')), findsOneWidget);
    expect(client.callsTo(DevToolsMethods.snapshot), hasLength(1));
  });

  testWidgets('schedules no frame once it has settled', (tester) async {
    await pumpApp(tester, app([actionRecord(1)]));
    await openTab(tester, 'Actions');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
