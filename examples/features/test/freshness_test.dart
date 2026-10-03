// teams/$teamId/route.dart has `const freshness = Freshness(staleTime: Duration(seconds: 30))`,
// the default of the section's data and of members/$member's. The fake clock of `testWidgets`
// ages it: nothing here waits for real time.
import 'package:features/app.g.dart';
import 'package:features/app/teams/\$teamId/data.dart' as team_data;
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => team_data.teamFetches = 0);

  testWidgets(
    'a page opened below the team after its staleTime loads the team again',
    (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/teams/acme/members/7'),
      );
      expect(find.text('member #7 of ACME'), findsOneWidget);
      expect(team_data.teamFetches, 1);

      // A page opened inside the section within the 30 seconds: the team is fresh.
      const TeamSettingsRoute(teamId: 'acme')
          .go(tester.element(find.text('Team ACME')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      const MembersRoute(teamId: 'acme')
          .go(tester.element(find.text('Team ACME')));
      await tester.pumpAndSettle();
      expect(team_data.teamFetches, 1);

      // After them, the next page that opens reads it, shows it, and loads it again.
      await tester.pump(const Duration(seconds: 31));
      const TeamSettingsRoute(teamId: 'acme')
          .go(tester.element(find.text('Team ACME')));
      await tester.pumpAndSettle();
      expect(find.text('Team ACME'), findsOneWidget);
      expect(team_data.teamFetches, 2);
    },
  );

  testWidgets('an action invalidates at once, whatever the staleTime', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/teams/acme/members'),
    );
    expect(team_data.teamFetches, 1);

    // Well inside the 30 seconds: a write is not a read, it makes the team stale for good.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Add carol'));
    await tester.pumpAndSettle();
    expect(team_data.teamFetches, 2);
    expect(find.text('Members: ann, bob, carol'), findsOneWidget);
  });
}
