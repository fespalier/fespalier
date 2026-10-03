// The Guards tab: what each guard and redirect answered, newest first, and a filter on the result.
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:fespalier_devtools/src/ui/chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';
import 'trace_fixtures.dart';

FakeFespalierClient app(List<GuardRecord> guards) =>
    FakeFespalierClient(snapshot: tracedSnapshot(guards: guards));

void main() {
  testWidgets('says so before any guard answered', (tester) async {
    await pumpApp(tester, app(const []));
    await openTab(tester, 'Guards');
    expect(find.text('No guard has answered yet.'), findsOneWidget);
  });

  testWidgets('lists the decisions newest first, with their results', (
    tester,
  ) async {
    await pumpApp(
      tester,
      app([
        guardRecord(1),
        guardRecord(
          2,
          uri: '/inbox',
          site: 'g6@8',
          result: GuardOutcome.redirect,
          location: '/login?from=%2Finbox',
        ),
        guardRecord(3, uri: '/old-search', site: 'r33'),
      ]),
    );
    await openTab(tester, 'Guards');
    final rows = [
      for (final seq in [3, 2, 1])
        tester.getTopLeft(find.byKey(Key('guard-$seq'))).dy,
    ];
    expect(rows, orderedEquals([...rows]..sort()), reason: 'newest first');
    final redirect = find.byKey(const Key('guard-2'));
    for (final text in [
      GuardOutcome.redirect,
      '/inbox',
      '/login?from=%2Finbox',
      '(members)/guard.dart',
      'InboxRoute',
    ]) {
      expect(
        find.descendant(of: redirect, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    // A redirect.dart is a site too: its file and route come from the tree.
    final plain = find.byKey(const Key('guard-3'));
    expect(
      find.descendant(
        of: plain,
        matching: find.text('old-search/redirect.dart'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: plain, matching: find.text('OldSearchRoute')),
      findsOneWidget,
    );
  });

  testWidgets('shows an async guard, pending and settled, and an error', (
    tester,
  ) async {
    await pumpApp(
      tester,
      app([
        guardRecord(1, result: GuardOutcome.pending, isAsync: true),
        guardRecord(2, isAsync: true, ms: 85),
        guardRecord(
          3,
          result: GuardOutcome.error,
          isAsync: true,
          ms: 12,
          error: 'Bad state: no session',
        ),
      ]),
    );
    await openTab(tester, 'Guards');
    final pending = find.byKey(const Key('guard-1'));
    expect(
      find.descendant(of: pending, matching: find.text('pending')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pending, matching: find.text('async')),
      findsOneWidget,
    );
    // Not answered yet: no time to show.
    expect(
      find.descendant(of: pending, matching: find.textContaining(' ms')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('guard-2')),
        matching: find.text('85 ms'),
      ),
      findsOneWidget,
    );
    final failed = find.byKey(const Key('guard-3'));
    expect(
      find.descendant(of: failed, matching: find.text('Bad state: no session')),
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

  testWidgets('says a guard was skipped because a segment did not parse', (
    tester,
  ) async {
    await pumpApp(
      tester,
      app([
        guardRecord(1, uri: '/orders/x/refund', result: GuardOutcome.skipped),
      ]),
    );
    await openTab(tester, 'Guards');
    expect(find.text('skipped'), findsWidgets);
    expect(find.text('segments did not parse'), findsOneWidget);
  });

  testWidgets('a filter chip hides a kind of result, and brings it back', (
    tester,
  ) async {
    await pumpApp(
      tester,
      app([
        guardRecord(1),
        guardRecord(2, result: GuardOutcome.redirect, location: '/login'),
        guardRecord(3),
      ]),
    );
    await openTab(tester, 'Guards');
    expect(find.byKey(const Key('guard-1')), findsOneWidget);
    // The chips count what there is.
    expect(find.text('pass 2'), findsOneWidget);
    expect(find.text('redirect 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('guard-filter-pass')));
    await tester.pump();
    expect(find.byKey(const Key('guard-1')), findsNothing);
    expect(find.byKey(const Key('guard-3')), findsNothing);
    expect(find.byKey(const Key('guard-2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('guard-filter-redirect')));
    await tester.pump();
    expect(find.text('Every result is filtered out.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('guard-filter-pass')));
    await tester.tap(find.byKey(const Key('guard-filter-redirect')));
    await tester.pump();
    expect(find.byKey(const Key('guard-1')), findsOneWidget);
    expect(find.byKey(const Key('guard-2')), findsOneWidget);
  });

  testWidgets('a guard whose site the tree lacks shows the site', (
    tester,
  ) async {
    await pumpApp(tester, app([guardRecord(1, site: 'g99@99')]));
    await openTab(tester, 'Guards');
    expect(find.text('g99@99'), findsOneWidget);
  });

  testWidgets(
    'says what it cannot show for an app that does not report guards',
    (tester) async {
      await pumpApp(tester, FakeFespalierClient(features: firstFeatures));
      await openTab(tester, 'Guards');
      expect(find.byKey(const Key('not-reported')), findsOneWidget);
      expect(find.textContaining('does not report its guards'), findsOneWidget);
    },
  );

  testWidgets(
    'a new decision from an event appears, in place for a settled one',
    (tester) async {
      final client = app([
        guardRecord(1, result: GuardOutcome.pending, isAsync: true),
      ]);
      await pumpApp(tester, client);
      await openTab(tester, 'Guards');
      expect(find.text('pending'), findsOneWidget);
      client.emit(
        DevToolsEvents.guard,
        recordEvent(
          8,
          guardRecord(
            1,
            result: GuardOutcome.pass,
            isAsync: true,
            ms: 40,
          ).toJson(),
        ),
      );
      await settle(tester);
      expect(find.text('pending'), findsNothing);
      expect(find.text('40 ms'), findsOneWidget);
      client.emit(
        DevToolsEvents.guard,
        recordEvent(
          9,
          guardRecord(
            2,
            result: GuardOutcome.redirect,
            location: '/login',
          ).toJson(),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('guard-2')), findsOneWidget);
      // Merged without asking the app again.
      expect(client.callsTo(DevToolsMethods.snapshot), hasLength(1));
    },
  );

  testWidgets('schedules no frame once it has settled', (tester) async {
    await pumpApp(tester, app([guardRecord(1)]));
    await openTab(tester, 'Guards');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
