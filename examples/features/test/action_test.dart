// action.dart: a refund form on orders/$id/refund (a route's action, with the pending and error
// state of the hook), and a section's action on teams/$teamId. No test waits for real time:
// the fake server holds a refund pending on a Completer.
import 'dart:async';

import 'package:features/app.g.dart';
import 'package:features/app/orders/\$id/refund/data.dart' as refund_data;
import 'package:features/app/orders/\$id/refund/page.dart';
import 'package:features/app/teams/\$teamId/data.dart' as team_data;
import 'package:features/app/teams/\$teamId/members/page.dart';
import 'package:features/refunds.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    refund_data.quoted.clear();
    team_data.teamFetches = 0;
  });

  Future<ProviderContainer> open(
    WidgetTester tester,
    String location,
    RefundServer server,
  ) =>
      pumpRouter(
        tester,
        AppRoutes.router(initialLocation: location),
        overrides: [refundServerProvider.overrideWithValue(server)],
        // The app's own policy, which retries what fails: a refund is never run twice.
        retry: ProviderContainer.defaultRetry,
      );

  Future<void> refund(WidgetTester tester, String amount) async {
    await tester.enterText(find.byType(TextField), amount);
    await tester.tap(find.text('Refund'));
    await tester.pump();
  }

  group('a route\'s action', () {
    testWidgets('pending while it runs, then the data it made stale is fresh', (
      tester,
    ) async {
      final gate = Completer<void>();
      final server = RefundServer(gate: gate.future);
      await open(tester, '/orders/5/refund', server);
      expect(find.text('Up to 50 EUR back'), findsOneWidget);
      expect(find.text('Refunding...'), findsNothing);

      await refund(tester, '20');
      expect(find.text('Refunding...'), findsOneWidget);
      // A second tap while it is pending does nothing: the button is disabled.
      await tester.tap(find.text('Refund'));
      await tester.pump();
      expect(server.attempts, 1);
      // The quote is still the old one until the write is done.
      expect(find.text('Up to 50 EUR back'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Refunding...'), findsNothing);
      expect(find.text('Refunded 20 EUR'), findsOneWidget);
      // The route's own data.dart ran again: the page shows what the server says now.
      expect(find.text('Up to 30 EUR back'), findsOneWidget);
      expect(refund_data.quoted, [5, 5]);
      expect(server.attempts, 1);
    });

    testWidgets(
        'a failure is shown by the form: the page stays, nothing is retried', (
      tester,
    ) async {
      final server = RefundServer();
      await open(tester, '/orders/5/refund', server);

      await refund(tester, '99');
      await tester.pumpAndSettle();
      expect(find.text('Declined: at most 50 EUR'), findsOneWidget);
      // Not error.dart: the page, and the quote it had, are still here.
      expect(find.text('Refund order 5'), findsOneWidget);
      expect(find.text('Up to 50 EUR back'), findsOneWidget);
      // Nothing was invalidated, nothing was retried, however long the app waits.
      await tester.pump(const Duration(minutes: 10));
      expect(refund_data.quoted, [5]);
      expect(server.attempts, 1);

      // Trying again is the user's call, and a success clears the error.
      await refund(tester, '10');
      await tester.pumpAndSettle();
      expect(find.text('Declined: at most 50 EUR'), findsNothing);
      expect(find.text('Refunded 10 EUR'), findsOneWidget);
      expect(find.text('Up to 40 EUR back'), findsOneWidget);
      expect(server.attempts, 2);
    });

    testWidgets('submit is typed, runs once and throws what the action threw', (
      tester,
    ) async {
      final server = RefundServer();
      await open(tester, '/orders/5/refund', server);
      final ref = tester.element(find.byType(RefundPage)) as WidgetRef;

      final Future<Refund> run = RefundRoute.submit(
        ref,
        id: 5,
        input: const RefundInput(amount: 10),
      );
      final done = await run;
      expect(done.amount, 10);
      await tester.pumpAndSettle();
      expect(find.text('Up to 40 EUR back'), findsOneWidget);

      await expectLater(
        RefundRoute.submit(ref, id: 5, input: const RefundInput(amount: 99)),
        throwsA(isA<RefundDeclined>()),
      );
      await tester.pumpAndSettle();
      // The form (which watches the same provider) shows it too.
      expect(find.text('Declined: at most 40 EUR'), findsOneWidget);
    });

    test('works without a widget: the provider is a plain Notifier family',
        () async {
      final server = RefundServer();
      final container = ProviderContainer(
        overrides: [refundServerProvider.overrideWithValue(server)],
      );
      addTearDown(container.dispose);
      final action = RefundRoute.action(1);
      final states = <AsyncValue<Refund?>>[];
      container.listen(action, (_, next) => states.add(next));

      final refund = await container
          .read(action.notifier)
          .call(const RefundInput(amount: 4));
      expect(refund.amount, 4);
      expect(states.map((s) => (s.isLoading, s.value?.amount)), [
        (true, null),
        (false, 4),
      ]);
      expect(server.left(1), 6);
      // Another order is another provider: its state is its own.
      expect(container.read(RefundRoute.action(2)).value, isNull);
    });
  });

  group('a section\'s action', () {
    testWidgets('writes, and the section reloads for the layout and the page', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/teams/acme/members'),
      );
      expect(find.text('Members: ann, bob'), findsOneWidget);
      expect(team_data.teamFetches, 1);

      await tester.tap(find.text('Add carol'));
      await tester.pumpAndSettle();
      // The section's data.dart ran again: the page and the layout read the same provider.
      expect(find.text('Members: ann, bob, carol'), findsOneWidget);
      expect(find.text('Team ACME'), findsOneWidget);
      expect(team_data.teamFetches, 2);
    });

    testWidgets(
        'has typed members like a route: a named action, a hook and a provider',
        (
      tester,
    ) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/teams/acme/members'),
      );
      final ref = tester.element(find.byType(MembersPage)) as WidgetRef;
      final Future<void> run = TeamsTeamIdSection.addMember(
        ref,
        teamId: 'acme',
        input: 'dan',
      );
      await run;
      await tester.pumpAndSettle();
      expect(find.text('Members: ann, bob, dan'), findsOneWidget);
      expect(
        ref.read(TeamsTeamIdSection.addMemberAction('acme')).hasValue,
        isTrue,
      );
    });
  });
}
