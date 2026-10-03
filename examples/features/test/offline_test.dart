// The team of teams/$teamId/data.dart is saved for the next start (fespalier_storage's PrefsDataStorage, over
// shared_preferences' in-memory fake). A restart is a second open() of the same store: nothing here waits on real time.
import 'package:features/app.g.dart';
import 'package:features/app/teams/\$teamId/data.dart' as team_data;
import 'package:features/refunds.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_storage/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A roster that cannot be read: the team's data() throws, as it does with no network.
class _OfflineRoster extends Roster {
  @override
  List<String> of(String teamId) => throw Exception('offline');
}

/// Opens a team's page with [storage] (what startup() would give `dataCacheStorage`).
Future<ProviderContainer> open(
  WidgetTester tester,
  PrefsDataStorage? storage, {
  String location = '/teams/acme/members',
  bool settle = true,
  List<Override> overrides = const [],
}) =>
    pumpRouter(
      tester,
      AppRoutes.router(initialLocation: location),
      overrides: [dataCacheStorage.overrideWithValue(storage), ...overrides],
      settle: settle,
    );

void main() {
  setUp(() {
    team_data.teamFetches = 0;
    fakePrefsStore();
  });

  testWidgets('with nothing saved, the first frame is loading.dart', (
    tester,
  ) async {
    await open(tester, await PrefsDataStorage.open(), settle: false);
    expect(find.text('Loading team'), findsOneWidget);
    expect(find.text('Team ACME'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Team ACME'), findsOneWidget);
  });

  testWidgets('the saved team is on the first frame of the next start', (
    tester,
  ) async {
    await open(tester, (await PrefsDataStorage.open())!);
    expect(find.text('Team ACME'), findsOneWidget);
    expect(team_data.teamFetches, 1);

    // The restart: the page is gone, and the store is opened again.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await open(tester, (await PrefsDataStorage.open())!, settle: false);

    // The first frame: the saved team, not loading.dart.
    expect(find.text('Team ACME'), findsOneWidget);
    expect(find.text('Loading team'), findsNothing);

    // A cold start always loads again, and the fresh team replaces the saved one.
    await tester.pump();
    expect(team_data.teamFetches, 2);
    await tester.pumpAndSettle();
    expect(find.text('Team ACME'), findsOneWidget);
  });

  testWidgets(
      'a start that cannot load the team shows the saved one, and keeps it for the next',
      (
    tester,
  ) async {
    await open(tester, (await PrefsDataStorage.open())!);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));

    final offline = _OfflineRoster();
    await open(
      tester,
      (await PrefsDataStorage.open())!,
      overrides: [rosterProvider.overrideWithValue(offline)],
    );
    expect(find.text('Team ACME'), findsOneWidget);
    expect(find.textContaining('Team failed'), findsNothing);

    // And the next start, still offline, still has it: fespalier does not delete a saved value on an error.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await open(
      tester,
      (await PrefsDataStorage.open())!,
      overrides: [rosterProvider.overrideWithValue(offline)],
    );
    expect(find.text('Team ACME'), findsOneWidget);
  });

  testWidgets(
      'a storage that could not open (null) saves nothing, and the app still works',
      (
    tester,
  ) async {
    await open(tester, null);
    expect(find.text('Team ACME'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await open(tester, null, settle: false);
    expect(find.text('Loading team'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('clear() is what a sign-out does: the next start shows nothing', (
    tester,
  ) async {
    final storage = (await PrefsDataStorage.open())!;
    await open(tester, storage);
    await storage.clear();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await open(tester, (await PrefsDataStorage.open())!, settle: false);
    expect(find.text('Loading team'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
