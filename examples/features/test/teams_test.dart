// A section's data.dart (teams/$teamId/) and nested not_found.dart files,
// with the widget-test helpers from package:fespalier/testing.dart.
import 'package:features/app.g.dart';
import 'package:features/app/teams/\$teamId/data.dart' as team_data;
import 'package:features/app/teams/\$teamId/members/page.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> open(WidgetTester tester, String location, {bool settle = true}) =>
    pumpRouter(
      tester,
      AppRoutes.router(initialLocation: location),
      settle: settle,
    );

void main() {
  setUp(() => team_data.teamFetches = 0);

  group('section data', () {
    testWidgets(
      'the whole section waits for it, then layout and page share it',
      (tester) async {
        await open(tester, '/teams/acme/members', settle: false);
        expect(find.text('Loading team'), findsOneWidget);
        expect(find.textContaining('Members'), findsNothing);

        await tester.pumpAndSettle();
        expect(find.text('Loading team'), findsNothing);
        expect(find.text('Team ACME'), findsOneWidget);
        expect(find.text('Members: ann, bob'), findsOneWidget);
        expect(team_data.teamFetches, 1);
      },
    );

    testWidgets('a parameter called data gets the nearest one', (tester) async {
      await open(tester, '/teams/acme/settings');
      expect(find.text('Team ACME'), findsOneWidget);
      expect(find.text('Settings of ACME'), findsOneWidget);
    });

    testWidgets('moving inside the section does not load it again', (
      tester,
    ) async {
      await open(tester, '/teams/acme/members');
      const TeamSettingsRoute(teamId: 'acme')
          .go(tester.element(find.text('Team ACME')));
      await tester.pumpAndSettle();
      expect(find.text('Settings of ACME'), findsOneWidget);
      expect(currentLocation(tester), '/teams/acme/settings');
      expect(team_data.teamFetches, 1);
    });

    testWidgets(
      'a page with its own data.dart also takes the section by type',
      (tester) async {
        await open(tester, '/teams/acme/members/7');
        expect(find.text('member #7 of ACME'), findsOneWidget);
        expect(find.text('Team ACME'), findsOneWidget);
      },
    );

    testWidgets('an error shows error.dart for the whole section, and retry', (
      tester,
    ) async {
      await open(tester, '/teams/ghost/members');
      expect(
        find.text('Team failed: Exception: no team ghost'),
        findsOneWidget,
      );
      expect(find.textContaining('Team GHOST'), findsNothing);
      expect(find.textContaining('Members'), findsNothing);
      expect(team_data.teamFetches, 1);

      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(
        find.text('Team failed: Exception: no team ghost'),
        findsOneWidget,
      );
      expect(team_data.teamFetches, 2);
    });
  });

  group('not_found.dart in a folder', () {
    testWidgets('the nearest folder covers unknown paths under it', (
      tester,
    ) async {
      await open(tester, '/teams/acme/nothing');
      expect(find.text('No team page at /teams/acme/nothing'), findsOneWidget);

      await open(tester, '/teams/acme/members/7/deeper');
      expect(
        find.text('No member at /teams/acme/members/7/deeper'),
        findsOneWidget,
      );
    });

    testWidgets('an unparsable segment shows its route\'s nearest one', (
      tester,
    ) async {
      await open(tester, '/teams/acme/members/x');
      expect(find.text('No member at /teams/acme/members/x'), findsOneWidget);
    });

    testWidgets('elsewhere the root one applies (here, the default)', (
      tester,
    ) async {
      await open(tester, '/no/such/path');
      expect(find.text('Nothing at /no/such/path'), findsOneWidget);
    });
  });

  group('optimistic()', () {
    testWidgets(
      'the new member is on the page from the next frame, with no frame between '
      'the write and the reload that lacks her',
      (tester) async {
        await open(tester, '/teams/acme/members');
        expect(find.text('Members: ann, bob'), findsOneWidget);
        final ref = tester.element(find.byType(MembersPage)) as WidgetRef;

        final run = TeamsTeamIdSection.addMember(
          ref,
          teamId: 'acme',
          input: 'carol',
        );
        final seen = <String>[];
        String members() =>
            tester.widget<Text>(find.textContaining('Members: ')).data!;
        // The section's data takes 10 ms to load: pump through it in steps.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 3));
          seen.add(members());
        }
        await run;
        expect(seen, everyElement('Members: ann, bob, carol'));
        // Loaded again: the server's list replaced the patch, and still has her.
        expect(team_data.teamFetches, 2);
        expect(find.text('Members: ann, bob, carol'), findsOneWidget);
        expect(find.text('Team ACME'), findsOneWidget);
      },
    );
  });
}
